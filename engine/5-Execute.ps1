# 5-Execute.ps1  (Guard)
# Submits ONLY proposals that already passed the R1-R15 gate. Never invents trades.
# Dry-run by default: without -Execute it prints the exact command and writes nothing.
#
#   powershell -File engine\5-Execute.ps1              # dry run
#   powershell -File engine\5-Execute.ps1 -Execute     # submit
#   powershell -File engine\5-Execute.ps1 -Execute -MaxOrders 2
[CmdletBinding()]
param(
    [switch]$Execute,
    [int]$MaxOrders = 3
)

. "$PSScriptRoot/lib/Common.ps1"
. "$PSScriptRoot/lib/Data.ps1"
. "$PSScriptRoot/lib/Exits.ps1"

$c = Get-Config
$ver = (Get-Rulebook).version
$runDir = New-RunDir 'execute'
$acc = $c.account.account_id
$mkt = $c.account.market

$doc = Read-JsonFile (Get-Path 'state\proposals-latest.json')
if (-not $doc) { throw 'No proposals. Run 4-Propose.ps1 first.' }

$approved = @($doc.verdicts | Where-Object { $_.approved })
if ($approved.Count -eq 0) {
    Write-Log 'no approved proposals to execute' $runDir
    Write-Output 'ORDERED=0'
    exit 0
}
if (-not $Execute) { Write-Log 'DRY RUN: nothing will be submitted (pass -Execute)' $runDir }

# Existing pending orders, to avoid duplicate buys on the same name.
$openResp = Invoke-Moomoo -Arguments @('sim', 'order', 'list', '--account', $acc, '--market', $mkt) -RunDir $runDir
$pending = @{}
foreach ($o in @(Get-Prop $openResp 'orders' @())) {
    if ($null -eq $o) { continue }
    if ([int](Get-Prop $o 'status' 0) -eq 2) { $pending[('US.' + [string](Get-Prop $o 'symbol' ''))] = $o }
}

# Ladder state: limit price steps up $0.10 per cycle, capped at pivot*1.05.
$ladderPath = Get-Path 'state\ladder.json'
$ladder = Read-JsonFile $ladderPath
if (-not $ladder) { $ladder = [pscustomobject]@{} }

$ordered = 0
foreach ($v in $approved) {
    if ($ordered -ge $MaxOrders) { break }
    $sym = $v.symbol
    $meta = Get-Prop $v 'meta' $null
    $pivot = To-Num (Get-Prop $meta 'pivot' $v.price)
    $cap = [math]::Round($pivot * (1 + $c.strategy.max_extension_pct), 2)

    $limit = [math]::Round((To-Num $v.price), 2)
    if ($ladder.PSObject.Properties[$sym]) {
        $limit = [math]::Min($cap, [math]::Round((To-Num $ladder.$sym.lastLimit) + 0.10, 2))
    }
    $limit = [math]::Min($limit, $cap)

    if ($pending.ContainsKey($sym)) {
        $old = $pending[$sym]
        $oldPrice = To-Num (Get-Prop $old 'price' 0)
        if ($oldPrice -ge $cap) { Write-Log "$sym pending at cap $cap; skipping" $runDir; continue }
        Write-Log ("$sym pending at {0:N2}; ladder step to {1:N2}" -f $oldPrice, $limit) $runDir
        if ($Execute) {
            try {
                Invoke-Moomoo -Arguments @('sim', 'order', 'cancel', [string](Get-Prop $old 'order_id' ''), '--account', $acc, '--market', $mkt) -RunDir $runDir | Out-Null
            }
            catch { Write-Log "cancel failed for ${sym}: $($_.Exception.Message)" $runDir 'WARN'; continue }
        }
    }

    $qty = [int]$v.qty
    $args = @('sim', 'order', 'buy', $sym, "$qty", '--account', $acc, '--market', $mkt, '--type', 'limit', '--price', ('{0:F2}' -f $limit), '--text', ('v{0} VCP conv={1} stop={2}' -f $ver, $v.conviction, $v.stopPrice))
    if (-not $Execute) {
        Write-Log ("DRYRUN: moomoo " + ($args -join ' ')) $runDir
        Write-Output ("DRYRUN {0} {1} @ {2:F2}" -f $sym, $qty, $limit)
        continue
    }
    try {
        $resp = Invoke-Moomoo -Arguments $args -RunDir $runDir
        Save-Raw $resp $runDir ("buy-" + ($sym -replace '\.', '_'))
        $orderId = Get-Prop $resp 'order_id' $null
        $ordered++
        Add-Stop -Symbol $sym -Entry $limit -Stop (To-Num $v.stopPrice) -Atr (To-Num (Get-Prop $meta 'atr' 0)) -OpenedDate ((Get-EtNow).ToString('yyyy-MM-dd')) -Pivot $pivot | Out-Null
        $props = @{}
        foreach ($p in $ladder.PSObject.Properties) { $props[$p.Name] = $p.Value }
        $props[$sym] = [pscustomobject]@{ lastLimit = $limit; at = (Get-Date -Format 's') }
        $ladder = [pscustomobject]$props
        Write-JsonFile -Object $ladder -Path $ladderPath
        Add-Jsonl -Object ([pscustomobject]@{
                ts = (Get-Date -Format 's'); symbol = $sym; side = 'buy'; qty = $qty; price = $limit
                stop = $v.stopPrice; conviction = $v.conviction; orderId = $orderId; decisionId = $v.decisionId; submitted = $true
            }) -Path (Get-Path 'journal\orders.jsonl')
        Write-Log ("BUY {0} {1} @ {2:F2} stop={3:F2} orderId={4}" -f $sym, $qty, $limit, $v.stopPrice, $orderId) $runDir
    }
    catch {
        Write-Log ("BUY FAILED {0}: {1}" -f $sym, $_.Exception.Message) $runDir 'ERROR'
        Add-Jsonl -Object ([pscustomobject]@{ ts = (Get-Date -Format 's'); symbol = $sym; side = 'buy'; qty = $qty; price = $limit; error = "$($_.Exception.Message)"; submitted = $false }) -Path (Get-Path 'journal\orders.jsonl')
    }
}

Write-Output ("ORDERED={0} DRYRUN={1} RUNDIR={2}" -f $ordered, (-not $Execute), $runDir)
