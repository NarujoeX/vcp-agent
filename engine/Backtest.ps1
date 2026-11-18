# Backtest.ps1 - walk-forward VCP backtest on the cached universe.
# Same rules as live: Stage 2 -> VCP -> breakout on 1.5x volume -> J Law multiple-edge
# filter (liquidity, heavy volume into the base, edges, RS vs SPY) -> SPY regime gate ->
# limit at pivot, stop 4% under the confluence zone clipped to 6-10%, breakeven at +5%,
# 2xATR trail, trim a third at 3 ATR, 10-day time stop, 3.5% starters,
# max 3 new/day, max 8 open, cash only. Costs: 5bp slippage + 2bp half-spread.
#
#   powershell -File engine\Backtest.ps1 [-Top 200] [-Days 0]
[CmdletBinding()]
param(
    [int]$Top = 200,
    [int]$Days = 0,
    [double]$StartEquity = 100000,
    # Research-only switch for the R13 question. 'current' is the production rule; the
    # other two loosen it and must never reach live trading without a version bump.
    [ValidateSet('current', 'tolerance2', 'above200')]
    [string]$RegimeMode = 'current',
    # Research-only: 'fallback' replays the rule-15 plain-VCP path for the whole window
    # (heavy volume, edges and RS skipped; the R15 liquidity floor still applies, as in the live gate).
    [ValidateSet('jlaw', 'fallback')]
    [string]$EntryMode = 'jlaw',
    # Pin the window end (yyyymmdd). Daily cache refreshes append bars and drift the
    # default window; a pinned date keeps repeated runs on the same sessions.
    [string]$EndDate = ''
)

. "$PSScriptRoot/lib/Common.ps1"
. "$PSScriptRoot/lib/Data.ps1"
. "$PSScriptRoot/lib/Indicators.ps1"
. "$PSScriptRoot/lib/Gate.ps1"

$c = Get-Config
$s = $c.strategy
$jl = (Get-Rulebook).jlaw
$runDir = New-RunDir ('backtest-' + $RegimeMode + $(if ($EntryMode -ne 'jlaw') { '-' + $EntryMode } else { '' }))
$universe = Load-Universe
$cost = $s.slippage_pct + $s.half_spread_pct

# Benchmark: regime (R13) and relative strength, mapped by date so it aligns with the bars.
$spyBars = Load-Klines 'US.SPY'
$spyMap = @{}
$spy63Map = @{}
if ($spyBars -and $spyBars.Count -gt 70) {
    $sc = [double[]]@($spyBars | ForEach-Object { [double]$_.close })
    $spySma = Get-SmaSeries -Values $sc -Period $jl.regime_sma
    $spySma200 = Get-SmaSeries -Values $sc -Period 200
    for ($k = 0; $k -lt $spyBars.Count; $k++) {
        if ($k -lt $jl.regime_sma -or [double]::IsNaN($spySma[$k])) { continue }
        $pk = $k - $jl.regime_slope_look
        if ($pk -lt 0 -or [double]::IsNaN($spySma[$pk])) { continue }
        $falling = $spySma[$k] -lt $spySma[$pk]
        $bear = switch ($RegimeMode) {
            'current' { ($sc[$k] -lt $spySma[$k]) -and $falling }
            'tolerance2' { ($sc[$k] -lt ($spySma[$k] * 0.98)) -and $falling }
            # Loosened: only a break of the 200-day average blocks, slope ignored.
            'above200' { [double]::IsNaN($spySma200[$k]) -or ($sc[$k] -lt $spySma200[$k]) }
        }
        $spyMap[[string]$spyBars[$k].date] = $bear
        if ($k -ge $jl.rs_lookback_days) { $spy63Map[[string]$spyBars[$k].date] = ($sc[$k] / $sc[$k - $jl.rs_lookback_days]) - 1 }
    }
}
if ($spyMap.Count -eq 0) { Write-Log 'WARN no SPY regime history; every day fails R13 closed' $runDir 'WARN' }

$members = @($universe.members | Sort-Object marketCap -Descending | Select-Object -First $Top)
$loaded = New-Object System.Collections.Generic.List[object]
foreach ($m in $members) {
    $b = Load-Klines $m.symbol
    if (-not $b -or $b.Count -lt 280) { continue }
    $loaded.Add([pscustomobject]@{ symbol = $m.symbol; name = $m.name; bars = $b })
}
# A pinned end date trims every cached series first, so names fetched hours apart
# (and therefore carrying different latest bars) still align on the same history.
# The kline window slides, so a file saved a day earlier starts one bar earlier:
# keep a fixed tail as well, or the cut yields 368 vs 369 bars and nothing aligns.
# The tail is sized to the shorter of the two (368 = 209 warm-up + 159 sessions),
# because only the earlier-saved files carry the extra bar.
if ($EndDate) {
    $cut = [int]$EndDate
    $keep = 209 + 159   # 200-day warm-up plus the 159-session window
    foreach ($l in $loaded) {
        $t = @($l.bars | Where-Object { [int]$_.date -le $cut })
        if ($t.Count -gt $keep) { $t = @($t[($t.Count - $keep)..($t.Count - 1)]) }
        $l.bars = $t
    }
}
# The loop is index-based across symbols, so keep only names whose history is
# aligned with the longest series (same length, same last date).
$maxBars = 0
foreach ($l in $loaded) { if ($l.bars.Count -gt $maxBars) { $maxBars = $l.bars.Count } }
$lastDate = $null
foreach ($l in $loaded) { if ($l.bars.Count -eq $maxBars) { $lastDate = $l.bars[$maxBars - 1].date; break } }
$series = New-Object System.Collections.Generic.List[object]
$skipped = 0
foreach ($l in $loaded) {
    if ($l.bars.Count -ne $maxBars -or $l.bars[$maxBars - 1].date -ne $lastDate) { $skipped++; continue }
    $series.Add([pscustomobject]@{
            symbol = $l.symbol; name = $l.name; bars = $l.bars
            swings = @(Find-Swings -Bars $l.bars -ThresholdPct $s.swing_threshold_pct)
        })
}
Write-Log "backtest series=$($series.Count) symbols (skipped $skipped unaligned)" $runDir
if ($series.Count -eq 0) { throw 'No bars cached. Run 1-Refresh-Universe.ps1 first.' }

$nDays = $series[0].bars.Count
if ($EndDate) {
    if ([string]$series[0].bars[$nDays - 1].date -ne [string][int]$EndDate) { throw "bar history ends $($series[0].bars[$nDays - 1].date), not $EndDate" }
    $endIdx = $nDays
    $startIdx = [math]::Max(1, $endIdx - 159)
    if ($Days -gt 0) { $startIdx = [math]::Max(1, $endIdx - $Days) }
}
else {
    $startIdx = 210
    $endIdx = $nDays - 1
    if ($Days -gt 0) { $startIdx = [math]::Max(210, $endIdx - $Days) }
}
Write-Log "window bars $startIdx..$endIdx ($($endIdx - $startIdx) sessions)" $runDir

$equity = $StartEquity
$cash = $StartEquity
$positions = New-Object System.Collections.Generic.List[object]
$tradeLog = New-Object System.Collections.Generic.List[object]
$curve = New-Object System.Collections.Generic.List[object]
$diag = @{ stage2 = 0; vcp = 0; breakout = 0; volOk = 0; dvFail = 0; heavyFail = 0; edgesFail = 0; rsFail = 0; jlaw = 0; fills = 0; regimeBlocked = 0; regimeAllowed = 0; trims = 0 }
$minDv = To-Num $jl.min_dollar_volume
if ($minDv -le 0) { $minDv = 100000000 }

for ($i = $startIdx; $i -lt $endIdx; $i++) {
    $day = $series[0].bars[$i].date
    $newToday = 0
    $bearish = $true
    if ($spyMap.ContainsKey([string]$day)) { $bearish = [bool]$spyMap[[string]$day] }

    # ---------- exits ----------
    $closing = New-Object System.Collections.Generic.List[object]
    foreach ($p in $positions) {
        $bars = $p.bars
        $bar = $bars[$i]
        $atr = Get-Atr -Bars @($bars[0..$i]) -Period 14
        if (-not $atr) { $atr = $p.atr }

        $exitPrice = $null
        $reason = $null
        if ($bar.low -le $p.stop) {
            $exitPrice = [math]::Min($p.stop, $bar.open)
            $reason = if ($bar.open -lt $p.stop) { 'stop gap' } else { 'stop' }
        }
        else {
            if ($bar.close -ge $p.entry * (1 + $s.breakeven_trigger_pct)) {
                $p.breakeven = $true
                $p.stop = [math]::Max($p.stop, $p.entry)
            }
            $p.high = [math]::Max($p.high, $bar.close)
            if ($p.breakeven) { $p.stop = [math]::Max($p.stop, $p.high - ($s.trail_atr_mult * $atr)) }
            # J Law: trim a third once extended by 3 ATR, once per position.
            if (-not $p.trimmed -and $atr -gt 0 -and $p.qty -ge 2 -and $bar.close -ge ($p.entry + ($jl.trim_atr_mult * $atr))) {
                $tq = [int][math]::Floor($p.qty * $jl.trim_fraction)
                if ($tq -lt 1) { $tq = 1 }
                if ($tq -ge $p.qty) { $tq = $p.qty - 1 }
                if ($tq -ge 1) {
                    $tfill = $bar.close * (1 - $cost)
                    $cash += $tq * $tfill
                    $p.qty -= $tq
                    $p.trimmed = $true
                    $diag.trims++
                    $tradeLog.Add([pscustomobject]@{
                            symbol = $p.symbol; entry = [math]::Round($p.entry, 4); exit = [math]::Round($tfill, 4)
                            qty = $tq; pl = [math]::Round(($tfill - $p.entry) * $tq, 2); retPct = [math]::Round(($tfill - $p.entry) / $p.entry, 4)
                            days = ($i - $p.openedIdx); reason = 'trim'; entryIdx = $p.openedIdx; closeIdx = $i
                            mode = $p.mode; entryDate = $p.entryDate; exitDate = $day
                        })
                }
            }
            if (($i - $p.openedIdx) -ge $s.max_hold_days) { $exitPrice = $bar.close; $reason = 'time stop' }
        }

        if ($exitPrice) {
            $fill = $exitPrice * (1 - $cost)
            $cash += $p.qty * $fill
            $pl = ($fill - $p.entry) * $p.qty
            $tradeLog.Add([pscustomobject]@{
                    symbol = $p.symbol; entry = [math]::Round($p.entry, 4); exit = [math]::Round($fill, 4)
                    qty = $p.qty; pl = [math]::Round($pl, 2); retPct = [math]::Round(($fill - $p.entry) / $p.entry, 4)
                    days = ($i - $p.openedIdx); reason = $reason; entryIdx = $p.openedIdx; closeIdx = $i
                    mode = $p.mode; entryDate = $p.entryDate; exitDate = $day
                })
            $closing.Add($p)
        }
    }
    foreach ($p in $closing) { $positions.Remove($p) | Out-Null }

    # ---------- entries ----------
    if (-not $bearish) { $diag.regimeAllowed++ }
    if ($bearish) { $diag.regimeBlocked++ }
    elseif ($positions.Count -lt $c.risk.max_open_positions) {
        $opps = New-Object System.Collections.Generic.List[object]
        foreach ($sym in $series) {
            $bars = $sym.bars
            $slice = [object[]]@($bars[0..$i])
            $st = Get-Stage2 -Bars $slice -Config $c
            if (-not $st.pass) { continue }
            $diag.stage2++
            $vcp = Get-Vcp -Bars $slice -Config $c -Vol50 $st.vol50
            if (-not $vcp) { continue }
            $diag.vcp++
            if ($vcp.state -eq 'breakout') { $diag.breakout++ } else { continue }
            if (-not $vcp.volumeOk) { continue }
            $diag.volOk++

            # J Law layer: liquidity, heavy volume into the base, multiple edges, RS vs SPY.
            # Each stage counts only the candidates that got this far, so the sub-funnel
            # shows which condition is actually binding.
            $dv = Get-DollarVolume -Bars $slice -Period 20
            $heavy = Get-HeavyVolumeDays -Bars $slice -EndIdx ([int]$vcp.baseStartIdx) -Vol50 $st.vol50 -Mult $jl.heavy_volume_mult -Look $jl.heavy_volume_look
            $edges = Get-EdgeZone -Bars $slice -Pivot ([double]$vcp.pivot) -BandPct $jl.edge_zone_pct -High52 $st.high52 -SwingThresholdPct $s.swing_threshold_pct
            $rsOk = ($i -ge $jl.rs_lookback_days) -and $spy63Map.ContainsKey([string]$day)
            $rs63 = [double]::NaN
            if ($rsOk) { $rs63 = (($slice[$i].close / $slice[$i - $jl.rs_lookback_days].close) - 1) - [double]$spy63Map[[string]$day] }
            Write-Log ("  jlaw candidate {0} {1}: dv={2:N0}M heavy={3}/{4} edges={5} rs63={6} base={7} pivot={8}" -f `
                    $sym.symbol, $day, ($dv / 1e6), $heavy, $jl.heavy_volume_look, $(if ($edges) { $edges.count } else { 0 }), $rs63, $vcp.baseStartIdx, $vcp.pivotIdx) $runDir
            if ($dv -lt $minDv) { $diag.dvFail++; continue }
            $jlawMode = 'multiple-edge'
            $jlawOk = ($heavy -ge $jl.heavy_volume_min_days) -and $edges -and ($edges.count -ge $jl.min_edges) -and $rsOk -and ($rs63 -gt 0)
            if (-not $jlawOk) {
                if ($EntryMode -eq 'fallback') { $jlawMode = 'fallback-vcp' }
                else {
                    if ($heavy -lt $jl.heavy_volume_min_days) { $diag.heavyFail++ }
                    elseif (-not $edges -or $edges.count -lt $jl.min_edges) { $diag.edgesFail++ }
                    else { $diag.rsFail++ }
                    continue
                }
            }
            $diag.jlaw++

            if ($positions | Where-Object { $_.symbol -eq $sym.symbol }) { continue }
            # Live propose falls back to the pivot when the scan found no edge zone.
            $zl = if ($edges -and [double]$edges.zoneLow -gt 0) { [double]$edges.zoneLow } else { [double]$vcp.pivot }
            $opps.Add([pscustomobject]@{ sym = $sym.symbol; vcp = $vcp; atr = $st.atr; sf = $sym; zoneLow = $zl; mode = $jlawMode })
        }

        foreach ($o in @($opps | Sort-Object { $_.vcp.score } -Descending)) {
            if ($newToday -ge $c.risk.max_new_per_cycle) { break }
            if ($positions.Count -ge $c.risk.max_open_positions) { break }
            $bar = $o.sf.bars[$i]
            $pivot = $o.vcp.pivot
            # Limit at the pivot: fills only if the session trades through it.
            if ($bar.high -lt $pivot) { continue }
            $rawFill = if ($bar.open -ge $pivot) { $bar.open } else { $pivot }
            $fill = $rawFill * (1 + $cost)
            $qty = Get-StarterQty -Equity $equity -Price $fill -Config $c
            if ($qty -lt 1) { continue }
            $notional = $qty * $fill
            if ($notional -gt $cash) { continue }
            if (($notional / $equity) -gt $c.risk.max_stock_pct) { continue }

            $cash -= $notional
            $newToday++
            $diag.fills++
            $stopPrice = Get-ZoneStop -Entry $fill -ZoneLow ([double]$o.zoneLow) -BelowPct $jl.stop_below_edge_pct -MinPct $c.risk.stop_min_pct -MaxPct $c.risk.stop_max_pct
            $positions.Add([pscustomobject]@{
                    symbol = $o.sym; qty = $qty; entry = $fill; stop = $stopPrice; mode = $o.mode; entryDate = $day
                    high = $fill; breakeven = $false; trimmed = $false; openedIdx = $i; bars = $o.sf.bars; atr = $o.atr
                })
        }
    }

    $mv = 0.0
    foreach ($p in $positions) { $mv += $p.qty * $p.bars[$i].close }
    $equity = $cash + $mv
    $curve.Add([pscustomobject]@{ date = $day; equity = [math]::Round($equity, 2); cash = [math]::Round($cash, 2); open = $positions.Count })
}

# ---------- metrics ----------
Write-Log ("signal funnel: stage2={0} vcp={1} breakout={2} volumeOk={3} jlaw={4} fills={5} regimeBlockedDays={6} regimeAllowedDays={7} trims={8}" -f `
        $diag.stage2, $diag.vcp, $diag.breakout, $diag.volOk, $diag.jlaw, $diag.fills, $diag.regimeBlocked, $diag.regimeAllowed, $diag.trims) $runDir
Write-Log ("jlaw sub-funnel (first failing stage): dv<{0:N0}M={1} heavy<{2}={3} edges<{4}={5} rs63<=0={6} pass={7}" -f `
        ($minDv / 1e6), $diag.dvFail, $jl.heavy_volume_min_days, $diag.heavyFail, $jl.min_edges, $diag.edgesFail, $diag.rsFail, $diag.jlaw) $runDir
$trades = $tradeLog.ToArray()
$splitIdx = $startIdx + [int](0.7 * ($endIdx - $startIdx))
$isTrades = @($trades | Where-Object { $_.entryIdx -lt $splitIdx })
$oosTrades = @($trades | Where-Object { $_.entryIdx -ge $splitIdx })

function Get-Stats {
    param($Trades, $Curve, [double]$StartEq)
    $Trades = @($Trades)
    $Curve = @($Curve)
    $n = $Trades.Count
    $wins = @($Trades | Where-Object { $_.pl -gt 0 })
    $losses = @($Trades | Where-Object { $_.pl -le 0 })
    $grossWin = if ($wins.Count) { ($wins | Measure-Object -Property pl -Sum).Sum } else { 0 }
    $grossLoss = if ($losses.Count) { ($losses | Measure-Object -Property pl -Sum).Sum } else { 0 }
    $avgWin = if ($wins.Count) { $grossWin / $wins.Count } else { 0 }
    $avgLoss = if ($losses.Count) { [math]::Abs($grossLoss / $losses.Count) } else { 0 }
    $winRate = if ($n) { $wins.Count / $n } else { 0 }
    $expectancy = if ($n) { ($Trades | Measure-Object -Property pl -Average).Average } else { 0 }
    $pf = if ($grossLoss -ne 0) { [math]::Abs($grossWin / $grossLoss) } else { $null }

    $peak = $StartEq; $maxDd = 0.0
    $rets = New-Object System.Collections.Generic.List[double]
    $prev = $StartEq
    foreach ($pt in $Curve) {
        if ($pt.equity -gt $peak) { $peak = $pt.equity }
        $dd = ($peak - $pt.equity) / $peak
        if ($dd -gt $maxDd) { $maxDd = $dd }
        if ($prev -gt 0) { $rets.Add(($pt.equity - $prev) / $prev) }
        $prev = $pt.equity
    }
    $mean = if ($rets.Count) { ($rets | Measure-Object -Average).Average } else { 0 }
    $sd = 0.0
    if ($rets.Count -gt 1) {
        $var = 0.0
        foreach ($r in $rets) { $var += [math]::Pow($r - $mean, 2) }
        $sd = [math]::Sqrt($var / ($rets.Count - 1))
    }
    $downside = @($rets | Where-Object { $_ -lt 0 })
    $dvar = 0.0
    foreach ($r in $downside) { $dvar += $r * $r }
    $dstd = if ($downside.Count -gt 1) { [math]::Sqrt($dvar / $downside.Count) } else { 0 }
    $last = if ($Curve.Count) { $Curve[$Curve.Count - 1].equity } else { $StartEq }

    [pscustomobject]@{
        trades       = $n
        winRate      = [math]::Round($winRate, 4)
        avgWin       = [math]::Round($avgWin, 2)
        avgLoss      = [math]::Round($avgLoss, 2)
        expectancy   = [math]::Round($expectancy, 2)
        profitFactor = $(if ($null -ne $pf) { [math]::Round($pf, 3) } else { $null })
        totalReturn  = [math]::Round(($last - $StartEq) / $StartEq, 4)
        maxDrawdown  = [math]::Round($maxDd, 4)
        sharpe       = $(if ($sd -gt 0) { [math]::Round(($mean / $sd) * [math]::Sqrt(252), 3) } else { $null })
        sortino      = $(if ($dstd -gt 0) { [math]::Round(($mean / $dstd) * [math]::Sqrt(252), 3) } else { $null })
        endEquity    = [math]::Round($last, 2)
        avgHoldDays  = $(if ($n) { [math]::Round((($Trades | Measure-Object -Property days -Average).Average), 2) } else { 0 })
    }
}

$splitIdxCurve = [int](0.7 * ($curve.Count - 1))
$isCurve = @($curve[0..$splitIdxCurve])
$oosCurve = @($curve[$splitIdxCurve..($curve.Count - 1)])

# Buy-and-hold benchmark over the same window, matched by date.
$bench = $null
if ($spyBars -and $spyBars.Count -gt 0) {
    $winStart = [string]$series[0].bars[$startIdx].date
    $winEnd = [string]$series[0].bars[$endIdx - 1].date
    $b0 = $null; $b1 = $null
    foreach ($b in $spyBars) {
        $d = [string]$b.date
        if ($null -eq $b0 -and $d -ge $winStart) { $b0 = [double]$b.close }
        if ($d -le $winEnd) { $b1 = [double]$b.close }
    }
    if ($b0 -gt 0 -and $b1 -gt 0) {
        $bench = [pscustomobject]@{
            symbol = 'US.SPY'; startClose = $b0; endClose = $b1; totalReturn = [math]::Round(($b1 - $b0) / $b0, 4)
        }
    }
    else { Write-Log 'WARN SPY benchmark could not be matched to the window' $runDir 'WARN' }
}

$results = [pscustomobject]@{
    generated = (Get-Date -Format 's')
    strategyVersion = ('v' + (Get-Rulebook).version)
    universe = $series.Count
    window = [pscustomobject]@{ start = $series[0].bars[$startIdx].date; end = $series[0].bars[$endIdx - 1].date; sessions = ($endIdx - $startIdx) }
    costs = [pscustomobject]@{ slippage = $s.slippage_pct; halfSpread = $s.half_spread_pct }
    jlaw = [pscustomobject]@{
        enabled = [bool]$jl.enabled; minDollarVolume = $minDv; heavyVolumeMinDays = $jl.heavy_volume_min_days
        minEdges = $jl.min_edges; rsLookbackDays = $jl.rs_lookback_days; stopBelowEdgePct = $jl.stop_below_edge_pct
        trimAtrMult = $jl.trim_atr_mult; regimeSma = $jl.regime_sma
    }
    funnel = [pscustomobject]@{ stage2 = $diag.stage2; vcp = $diag.vcp; breakout = $diag.breakout; volumeOk = $diag.volOk; jlaw = $diag.jlaw; fills = $diag.fills; regimeBlockedDays = $diag.regimeBlocked; trims = $diag.trims
        jlawSub = [pscustomobject]@{ dollarVolumeFail = $diag.dvFail; heavyVolumeFail = $diag.heavyFail; edgesFail = $diag.edgesFail; rsFail = $diag.rsFail } }
    benchmark = $bench
    regime = [pscustomobject]@{ mode = $RegimeMode; blockedDays = $diag.regimeBlocked; allowedDays = $diag.regimeAllowed; smaPeriod = $jl.regime_sma }
    entryMode = $EntryMode
    all = Get-Stats -Trades $trades -Curve $curve.ToArray() -StartEq $StartEquity
    inSample = Get-Stats -Trades $isTrades -Curve $isCurve -StartEq $StartEquity
    outOfSample = Get-Stats -Trades $oosTrades -Curve $oosCurve -StartEq $(if ($isCurve.Count) { $isCurve[$isCurve.Count - 1].equity } else { $StartEquity })
    trades = $trades
    curve = $curve.ToArray()
}

Write-JsonFile -Object $results -Path (Join-Path $runDir 'results.json')
# Only the production rule on the default (unpinned) window updates the shared latest
# file. The R13 research variants and pinned replays must not overwrite the baseline
# the dashboard and the deck read.
if ($RegimeMode -eq 'current' -and $EntryMode -eq 'jlaw' -and -not $EndDate) { Write-JsonFile -Object $results -Path (Get-Path 'state\backtest-latest.json') }

Write-Log ("ALL: trades={0} win={1:P1} exp={2:N2} PF={3} ret={4:P2} maxDD={5:P2} sharpe={6}" -f `
        $results.all.trades, $results.all.winRate, $results.all.expectancy, $results.all.profitFactor, $results.all.totalReturn, $results.all.maxDrawdown, $results.all.sharpe) $runDir
if ($bench) { Write-Log ("BENCH: SPY buy & hold {0:P2} ({1:N2} -> {2:N2})" -f $bench.totalReturn, $bench.startClose, $bench.endClose) $runDir }
Write-Log ("IS:  trades={0} ret={1:P2} maxDD={2:P2} sharpe={3}" -f $results.inSample.trades, $results.inSample.totalReturn, $results.inSample.maxDrawdown, $results.inSample.sharpe) $runDir
Write-Log ("OOS: trades={0} ret={1:P2} maxDD={2:P2} sharpe={3}" -f $results.outOfSample.trades, $results.outOfSample.totalReturn, $results.outOfSample.maxDrawdown, $results.outOfSample.sharpe) $runDir
Write-Output ("BACKTEST mode={6}/{7} trades={0} win={1:P1} exp={2:N2} ret={3:P2} maxDD={4:P2} sharpe={5}" -f `
        $results.all.trades, $results.all.winRate, $results.all.expectancy, $results.all.totalReturn, $results.all.maxDrawdown, $results.all.sharpe, $RegimeMode, $EntryMode)
Write-Output ("OOS trades={0} ret={1:P2} maxDD={2:P2} sharpe={3} RUNDIR={4}" -f `
        $results.outOfSample.trades, $results.outOfSample.totalReturn, $results.outOfSample.maxDrawdown, $results.outOfSample.sharpe, $runDir)
