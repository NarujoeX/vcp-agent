# 1-Refresh-Universe.ps1
# Builds the tradable universe: top N US names by market cap (S&P 500 proxy),
# then caches daily bars for each so later stages never touch the API.
#
#   powershell -File engine\1-Refresh-Universe.ps1 [-TopN 500] [-MaxSymbols 40] [-Force]
[CmdletBinding()]
param(
    [int]$TopN = 0,
    [int]$MaxSymbols = 0,
    [switch]$Force
)

. "$PSScriptRoot/lib/Common.ps1"
. "$PSScriptRoot/lib/Data.ps1"

$c = Get-Config
$topN = if ($TopN -gt 0) { $TopN } else { $c.strategy.universe_top_n }
$runDir = New-RunDir 'universe'
Write-Log "Universe refresh: top $topN by market cap" $runDir

# --- 1. screen -----------------------------------------------------------
$screenQueries = '[{"simple_field_query":{"simple_field":1,"screen_value_list":[2]}}]'
$retrieve = '[{"basic_property":{"name":1101}},{"simple_property":{"name":2301}}]'
$sort = '{"direction":2,"simple_property":{"name":2301}}'

$members = New-Object System.Collections.Generic.List[object]
$nextKey = ''
$page = 0
while ($members.Count -lt $topN) {
    $page++
    $limit = [math]::Min(300, $topN - $members.Count)
    $cliArgs = @('stock-screen', '--screen-queries', $screenQueries, '--retrieve-queries', $retrieve,
        '--sort', $sort, '--limit', "$limit")
    if ($nextKey) { $cliArgs += @('--next-key', $nextKey) }
    $resp = Invoke-Moomoo -Arguments $cliArgs -RunDir $runDir
    Save-Raw $resp $runDir "screen-p$page"

    $items = @(Get-Prop (Get-Prop $resp 'data') 'items' @())
    if (-not $items.Count) { break }
    foreach ($it in $items) {
        $mkt = 0.0
        foreach ($r in @($it.results)) {
            $spr = Get-Prop $r 'simple_property_result'
            if ($spr) { $mkt = (To-Num (Get-Prop $spr 'value')) / 1000.0 }
        }
        $members.Add([pscustomobject]@{ symbol = $it.code; name = $it.name; marketCap = $mkt })
    }
    $pg = Get-Prop (Get-Prop $resp 'data') 'pagination'
    if (-not (Get-Prop $pg 'has_more' $false)) { break }
    $nextKey = [string](Get-Prop $pg 'next_key' '')
    if (-not $nextKey -or $nextKey -eq '-1') { break }
    if ($page -ge 10) { break }
}

Write-Log "Screen returned $($members.Count) names" $runDir
if ($MaxSymbols -gt 0) {
    $members = @($members | Select-Object -First $MaxSymbols)
    Write-Log "MaxSymbols cap applied: $($members.Count)" $runDir
}

# --- 2. bars -------------------------------------------------------------
$saved = 0; $skipped = 0; $failed = New-Object System.Collections.Generic.List[object]
$i = 0
$pending = New-Object System.Collections.Generic.List[object]
foreach ($m in $members) {
    $age = Get-KlineAge $m.symbol
    if (-not $Force -and $age.TotalHours -lt 12) { $skipped++; continue }
    $pending.Add($m)
}

# Two passes: the API rate-limits aggressively, so stragglers get a second attempt.
for ($pass = 1; $pass -le 2 -and $pending.Count -gt 0; $pass++) {
    if ($pass -gt 1) { Write-Log "Pass 2 for $($pending.Count) stragglers" $runDir; Start-Sleep -Seconds 20 }
    $retry = New-Object System.Collections.Generic.List[object]
    foreach ($m in $pending) {
        $i++
        if ($pass -eq 1 -and ($i % 25 -eq 0)) { Write-Log "  $i bars cached" $runDir }
        try {
            $k = Invoke-Moomoo -Arguments @('kline', $m.symbol, '-n', '370', '--ktype', '2') -RunDir $runDir -ThrottleMs 700
            if (-not $k.kline_list -or @($k.kline_list).Count -lt 60) {
                if ($pass -eq 2) { $failed.Add([pscustomobject]@{ symbol = $m.symbol; reason = 'short history' }) }
                continue
            }
            Save-Klines -Symbol $m.symbol -KlineList $k.kline_list -Name $m.name | Out-Null
            $saved++
        }
        catch {
            if ($pass -lt 2) { $retry.Add($m) }
            else { $failed.Add([pscustomobject]@{ symbol = $m.symbol; reason = "$($_.Exception.Message)" }) }
            Write-Log "  kline failed for $($m.symbol): $($_.Exception.Message)" $runDir 'WARN'
        }
    }
    $pending = $retry
}

$universe = [pscustomobject]@{
    generated = (Get-Date -Format 's')
    source    = 'moomoo stock-screen: US, top N by market cap (S&P 500 proxy)'
    count     = $members.Count
    members   = [object[]]$members
    failed    = [object[]]$failed
}
Save-Universe $universe
Save-Raw $universe $runDir 'universe'

Write-Log "Universe done: $($members.Count) members, $saved cached, $skipped fresh, $($failed.Count) failed" $runDir
Write-Output ("UNIVERSE={0} CACHED={1} SKIPPED={2} FAILED={3} RUNDIR={4}" -f $members.Count, $saved, $skipped, $failed.Count, $runDir)
