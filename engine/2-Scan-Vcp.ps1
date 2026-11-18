# 2-Scan-Vcp.ps1
# Runs the Stage 2 screen + VCP detection over the cached universe.
# Pure local maths: no API calls. Writes runs\<ts>-scan\candidates.json.
#
#   powershell -File engine\2-Scan-Vcp.ps1 [-MinScore 0]
[CmdletBinding()]
param(
    [double]$MinScore = 0
)

. "$PSScriptRoot/lib/Common.ps1"
. "$PSScriptRoot/lib/Data.ps1"
. "$PSScriptRoot/lib/Indicators.ps1"

$c = Get-Config
$rules = Get-Rulebook
$jl = $rules.jlaw
$runDir = New-RunDir 'scan'
$universe = Load-Universe
if (-not $universe) { throw 'No universe cached. Run 1-Refresh-Universe.ps1 first.' }

# SPY benchmark for relative strength. The universe refresh never touches SPY (an ETF is
# not in the stock screen), so the cache is refetched here once a day; without this R13
# would keep reading an old bar. A failed refresh marks the regime unknown: fail closed.
$spyBars = Load-Klines 'US.SPY'
$spyStale = (-not $spyBars) -or ($spyBars.Count -lt 130) -or ((Get-KlineAge 'US.SPY').TotalHours -gt 12)
$spyRefreshFailed = $false
if ($spyStale) {
    try {
        $k = Invoke-Moomoo -Arguments @('kline', 'US.SPY', '-n', '370', '--ktype', '2') -RunDir $runDir
        Save-Klines -Symbol 'US.SPY' -KlineList $k.kline_list -Name 'SPDR S&P 500 ETF' | Out-Null
        $spyBars = Load-Klines 'US.SPY'
    }
    catch {
        $spyRefreshFailed = $true
        Write-Log "SPY benchmark unavailable: $($_.Exception.Message)" $runDir 'WARN'
    }
}

function Get-ReturnPct {
    param($Bars, [int]$Days)
    $n = $Bars.Count
    if ($n -lt $Days + 1) { return 0.0 }
    $a = [double]$Bars[$n - 1 - $Days].close
    $b = [double]$Bars[$n - 1].close
    if ($a -le 0) { return 0.0 }
    ($b - $a) / $a
}

$spy126 = if ($spyBars) { Get-ReturnPct $spyBars 126 } else { 0.0 }
$spy63 = if ($spyBars) { Get-ReturnPct $spyBars 63 } else { 0.0 }

# Index regime is a hard gate for entries (R13): written here so the gate needs no API call.
$regime = Get-MarketRegime -Bars $spyBars -SmaPeriod $jl.regime_sma -SlopeLook $jl.regime_slope_look -Symbol $jl.benchmark
if ($spyRefreshFailed) { $regime.ok = $false; $regime.reason = 'benchmark refresh failed: regime stale' }
Write-JsonFile -Object $regime -Path (Get-Path 'state\market.json')

$stage2 = New-Object System.Collections.Generic.List[object]
$checked = 0; $noBars = 0; $tooShort = 0

foreach ($m in @($universe.members)) {
    $bars = Load-Klines $m.symbol
    if (-not $bars) { $noBars++; continue }
    if ($bars.Count -lt $c.strategy.min_bars) { $tooShort++; continue }
    $checked++

    $st = Get-Stage2 -Bars $bars -Config $c
    if (-not $st.pass) { continue }

    $vol50 = if ($st.vol50) { $st.vol50 } else { 0 }
    $vcp = Get-Vcp -Bars $bars -Config $c -Vol50 $vol50

    $rsRaw = (Get-ReturnPct $bars 126) - $spy126
    $rs63 = (Get-ReturnPct $bars $jl.rs_lookback_days) - $spy63
    $dv = Get-DollarVolume -Bars $bars -Period 20

    $heavy = 0
    $edges = $null
    $jlawPass = $false
    if ($vcp) {
        $heavy = Get-HeavyVolumeDays -Bars $bars -EndIdx ([int]$vcp.baseStartIdx) -Vol50 $vol50 -Mult $jl.heavy_volume_mult -Look $jl.heavy_volume_look
        $edges = Get-EdgeZone -Bars $bars -Pivot ([double]$vcp.pivot) -BandPct $jl.edge_zone_pct -High52 $st.high52 -SwingThresholdPct $c.strategy.swing_threshold_pct
        $jlawPass = ($edges.count -ge $jl.min_edges) -and ($heavy -ge $jl.heavy_volume_min_days) -and ($dv -ge $jl.min_dollar_volume) -and ($rs63 -gt 0)
    }
    $cat = Get-Catalyst -Symbol $m.symbol -ValidDays $jl.catalyst_valid_days

    $stage2.Add([pscustomobject]@{
        symbol    = $m.symbol
        name      = $m.name
        marketCap = $m.marketCap
        close     = $st.close
        rsi       = [math]::Round($st.rsi, 1)
        sma200    = [math]::Round($st.sma200, 2)
        atr       = [math]::Round($st.atr, 3)
        high52    = [math]::Round($st.high52, 2)
        vol50     = [math]::Round($vol50, 0)
        rs126     = [math]::Round($rsRaw, 4)
        dollarVolume = [math]::Round($dv, 0)
        rs63      = [math]::Round($rs63, 4)
        heavyVolDays = $heavy
        edges     = $(if ($edges) { $edges.count } else { 0 })
        edgeList  = $(if ($edges) { @($edges.edges) } else { @() })
        edgeZoneLow = $(if ($edges) { $edges.zoneLow } else { 0 })
        jlawPass  = $jlawPass
        catalyst  = $(if ($cat) { [string](Get-Prop $cat 'type' 'catalyst') } else { $null })
        vcp       = $vcp
    })
}

$stage2Count = $stage2.Count

# Relative-strength percentile across the whole Stage 2 set, so momentum is measured
# against the market rather than against the handful of names that happen to have a base.
$rankOf = @{}
$sortedAll = @($stage2 | Sort-Object rs126)
for ($j = 0; $j -lt $sortedAll.Count; $j++) { $rankOf[$sortedAll[$j].symbol] = $j }
foreach ($s in $stage2) {
    $rank = $rankOf[$s.symbol]
    $pct = if ($sortedAll.Count -gt 1) { $rank / ($sortedAll.Count - 1) } else { 0.5 }
    $s | Add-Member -NotePropertyName rsScore -NotePropertyValue ([math]::Round($pct, 3)) -Force
}

$withVcp = New-Object System.Collections.Generic.List[object]
foreach ($s in $stage2) { if ($s.vcp) { $withVcp.Add($s) } }
$stage2 = $withVcp

foreach ($s in $stage2) {
    $bonus = if ($s.catalyst) { $jl.catalyst_bonus } else { 0.0 }
    $conv = [math]::Min(1.0, (0.70 * $s.vcp.score) + (0.20 * $s.rsScore) + 0.05 + $bonus)
    $s | Add-Member -NotePropertyName conviction -NotePropertyValue ([math]::Round($conv, 3)) -Force
    # Entry geometry: limit at the pivot; stop 4% under the confluence zone, clipped
    # into R8's 6-10% band.
    $zoneLow = To-Num (Get-Prop $s 'edgeZoneLow' 0)
    if ($zoneLow -le 0) { $zoneLow = $s.vcp.pivot }
    $stopPrice = Get-ZoneStop -Entry ([double]$s.vcp.pivot) -ZoneLow $zoneLow -BelowPct $jl.stop_below_edge_pct `
        -MinPct $c.risk.stop_min_pct -MaxPct $c.risk.stop_max_pct
    $s | Add-Member -NotePropertyName entryLimit -NotePropertyValue $s.vcp.pivot -Force
    $s | Add-Member -NotePropertyName stopPct -NotePropertyValue ([math]::Round(1 - ($stopPrice / $s.vcp.pivot), 4)) -Force
    $s | Add-Member -NotePropertyName stopPrice -NotePropertyValue ([math]::Round($stopPrice, 2)) -Force
}

$candidates = @($stage2 | Where-Object { $_.conviction -ge $MinScore } | Sort-Object -Property @{ Expression = 'conviction'; Descending = $true })
$breakouts = @($candidates | Where-Object { $_.vcp.state -eq 'breakout' })
$setups = @($candidates | Where-Object { $_.vcp.state -eq 'setup' })

$doc = [pscustomobject]@{
    generated   = (Get-Date -Format 's')
    strategyVersion = ('v' + $rules.version)
    universe    = $universe.count
    checked     = $checked
    missingBars = $noBars
    tooShort    = $tooShort
    stage2Count = $stage2Count
    vcpCount    = $stage2.Count
    breakoutCount = $breakouts.Count
    setupCount  = $setups.Count
    jlawBreakouts = @($breakouts | Where-Object { $_.jlawPass }).Count
    jlawSetups  = @($setups | Where-Object { $_.jlawPass }).Count
    spy126      = [math]::Round($spy126, 4)
    spy63       = [math]::Round($spy63, 4)
    market      = $regime
    candidates  = $candidates
}
Write-JsonFile -Object $doc -Path (Join-Path $runDir 'candidates.json')
Write-JsonFile -Object $doc -Path (Get-Path 'state\candidates-latest.json')
Save-Raw $doc $runDir 'candidates'

Write-Log ("Scan: universe={0} checked={1} stage2={2} vcp={3} breakouts={4} setups={5} jlawBreakouts={6}" -f $universe.count, $checked, $stage2Count, $stage2.Count, $breakouts.Count, $setups.Count, $doc.jlawBreakouts) $runDir
Write-Log ("Regime: {0} close={1} sma{2}={3} falling={4} bearish={5}" -f $regime.symbol, (Get-Prop $regime 'close' 0), $jl.regime_sma, (Get-Prop $regime 'sma' 0), (Get-Prop $regime 'falling' $false), (Get-Prop $regime 'bearish' $false)) $runDir
foreach ($b in @($breakouts | Select-Object -First 8)) {
    Write-Log ("  BREAKOUT {0} pivot={1} close={2} conv={3} depths=[{4}] volRatio={5} edges={6} [{7}] heavy={8} dv={9:N0}M jlaw={10}" -f `
            $b.symbol, $b.vcp.pivot, $b.vcp.close, $b.conviction, ($b.vcp.depths -join ','), $b.vcp.lastVolRatio,
        $b.edges, (@($b.edgeList) -join '/'), $b.heavyVolDays, ($b.dollarVolume / 1e6), $b.jlawPass) $runDir
}
foreach ($b in @($setups | Select-Object -First 8)) {
    Write-Log ("  SETUP    {0} pivot={1} close={2} conv={3} depths=[{4}] volRatio={5} edges={6} heavy={7} jlaw={8}" -f `
            $b.symbol, $b.vcp.pivot, $b.vcp.close, $b.conviction, ($b.vcp.depths -join ','), $b.vcp.lastVolRatio,
        $b.edges, $b.heavyVolDays, $b.jlawPass) $runDir
}
Write-Output ("STAGE2={0} VCP={1} BREAKOUTS={2} SETUPS={3} JLAW_BREAKOUTS={4} BEARISH={5} RUNDIR={6}" -f $stage2Count, $stage2.Count, $breakouts.Count, $setups.Count, $doc.jlawBreakouts, $regime.bearish, $runDir)
