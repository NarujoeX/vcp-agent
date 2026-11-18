# tmp/test-jlaw.ps1 - unit tests for the J Law layer (no API calls).
. "$PSScriptRoot/../engine/lib/Common.ps1"
. "$PSScriptRoot/../engine/lib/Data.ps1"
. "$PSScriptRoot/../engine/lib/Indicators.ps1"
. "$PSScriptRoot/../engine/lib/Exits.ps1"

$c = Get-Config
$jl = (Get-Rulebook).jlaw
$script:failures = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
    Write-Host ("{0}  {1,-38} {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail)
    if (-not $ok) { $script:failures++ }
}

# ---- stop clamp ----------------------------------------------------------
$s1 = Get-ZoneStop -Entry 100 -ZoneLow 100 -BelowPct 0.04 -MinPct 0.06 -MaxPct 0.10
Check 'zone 0% under entry -> 6% floor' ($s1 -eq 94.0) ("stop=" + $s1)
$s2 = Get-ZoneStop -Entry 100 -ZoneLow 96 -BelowPct 0.04 -MinPct 0.06 -MaxPct 0.10
Check 'zone 4% under entry -> 7.8%' ([math]::Abs($s2 - 92.16) -lt 0.01) ("stop=" + $s2)
$s3 = Get-ZoneStop -Entry 100 -ZoneLow 80 -BelowPct 0.04 -MinPct 0.06 -MaxPct 0.10
Check 'zone deep -> 10% ceiling' ($s3 -eq 90.0) ("stop=" + $s3)

# ---- trim ----------------------------------------------------------------
$t1 = Get-TrimOrder -Entry 100 -Last 105 -Atr 2 -Qty 30 -Config $c
Check 'not extended at 2.5 ATR -> no trim' ($null -eq $t1) 'null'
$t2 = Get-TrimOrder -Entry 100 -Last 106 -Atr 2 -Qty 30 -Config $c
Check 'extended at 3 ATR -> trim a third' (($null -ne $t2) -and ($t2.qty -eq 9)) ("qty=" + $(if ($t2) { $t2.qty } else { 'null' }))
$t3 = Get-TrimOrder -Entry 100 -Last 120 -Atr 2 -Qty 2 -Config $c
Check 'two shares trim one, never zero' (($null -ne $t3) -and ($t3.qty -eq 1)) ("qty=" + $(if ($t3) { $t3.qty } else { 'null' }))
$t4 = Get-TrimOrder -Entry 100 -Last 140 -Atr 2 -Qty 1 -Config $c
Check 'single share cannot be trimmed' ($null -eq $t4) 'null'
$t5 = Get-TrimOrder -Entry 100 -Last 140 -Atr 0 -Qty 30 -Config $c
Check 'no ATR -> no trim' ($null -eq $t5) 'null'

# ---- regime --------------------------------------------------------------
function New-Bars([double[]]$Closes) {
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Closes.Count; $i++) {
        $out.Add([pscustomobject]@{ date = 20260101 + $i; open = $Closes[$i]; high = $Closes[$i] * 1.01; low = $Closes[$i] * 0.99; close = $Closes[$i]; volume = 1e6 })
    }
    , $out.ToArray()
}
$up = New-Object System.Collections.Generic.List[double]
for ($i = 0; $i -lt 80; $i++) { $up.Add(100 + $i) }
$r1 = Get-MarketRegime -Bars (New-Bars $up.ToArray())
Check 'rising index is not bearish' (($r1.ok) -and (-not $r1.bearish)) ("close=$($r1.close) sma=$($r1.sma)")

$down = New-Object System.Collections.Generic.List[double]
for ($i = 0; $i -lt 55; $i++) { $down.Add(100 + $i) }
for ($i = 1; $i -le 25; $i++) { $down.Add(155 - (2.2 * $i)) }
$r2 = Get-MarketRegime -Bars (New-Bars $down.ToArray())
Check 'close under falling 50DMA is bearish' (($r2.ok) -and $r2.bearish -and $r2.falling) ("close=$($r2.close) sma=$($r2.sma)")
$r3 = Get-MarketRegime -Bars $null
Check 'missing benchmark fails closed' ((-not $r3.ok) -and (-not $r3.bearish)) 'ok=false'

# ---- heavy-volume window -------------------------------------------------
function New-VolBars([int]$Count, [hashtable]$Heavy) {
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Count; $i++) {
        $v = 100.0
        if ($Heavy.ContainsKey($i)) { $v = [double]$Heavy[$i] }
        $out.Add([pscustomobject]@{ date = 20260101 + $i; open = 10; high = 10.2; low = 9.8; close = 10; volume = $v })
    }
    , $out.ToArray()
}
# Window for EndIdx=16, Look=10 is bars 7..16 (inclusive), bar 6 is outside.
$h1 = Get-HeavyVolumeDays -Bars (New-VolBars 26 @{ 6 = 200.0; 7 = 200.0; 16 = 200.0 }) -EndIdx 16 -Vol50 100 -Mult 1.5 -Look 10
Check 'window is the 10 sessions ending at anchor' ($h1 -eq 2) ("heavy=" + $h1)
$h2 = Get-HeavyVolumeDays -Bars (New-VolBars 26 @{ 16 = 200.0 }) -EndIdx 16 -Vol50 100 -Mult 1.5 -Look 10
Check "end bar volume counts" ($h2 -eq 1) ("heavy=" + $h2)
$h3 = Get-HeavyVolumeDays -Bars (New-VolBars 26 @{ 6 = 200.0 }) -EndIdx 16 -Vol50 100 -Mult 1.5 -Look 10
Check 'bar older than the window excluded' ($h3 -eq 0) ("heavy=" + $h3)
$h4 = Get-HeavyVolumeDays -Bars (New-VolBars 26 @{ 0 = 200.0 }) -EndIdx 5 -Vol50 100 -Mult 1.5 -Look 10
Check 'short history fails closed' ($h4 -eq 0) ("heavy=" + $h4)
$h5 = Get-HeavyVolumeDays -Bars (New-VolBars 26 @{ 15 = 150.0 }) -EndIdx 16 -Vol50 100 -Mult 1.5 -Look 10
$h6 = Get-HeavyVolumeDays -Bars (New-VolBars 26 @{ 15 = 149.0 }) -EndIdx 16 -Vol50 100 -Mult 1.5 -Look 10
Check '1.5x threshold is inclusive' (($h5 -eq 1) -and ($h6 -eq 0)) ("at150=" + $h5 + " at149=" + $h6)

# ---- real cached bars ----------------------------------------------------
$bars = Load-Klines 'US.VRTX'
if ($bars -and $bars.Count -gt 260) {
    $st = Get-Stage2 -Bars $bars -Config $c
    $vcp = Get-Vcp -Bars $bars -Config $c -Vol50 $st.vol50
    $heavy = Get-HeavyVolumeDays -Bars $bars -EndIdx ([int]$vcp.baseStartIdx) -Vol50 $st.vol50 -Mult $jl.heavy_volume_mult -Look $jl.heavy_volume_look
    $edges = Get-EdgeZone -Bars $bars -Pivot ([double]$vcp.pivot) -BandPct $jl.edge_zone_pct -High52 $st.high52 -SwingThresholdPct $c.strategy.swing_threshold_pct
    $dv = Get-DollarVolume -Bars $bars -Period 20
    $rs63 = 0.0
    $spy = Load-Klines 'US.SPY'
    if ($spy) {
        $n = $bars.Count; $m = $spy.Count
        $rs63 = (($bars[$n - 1].close - $bars[$n - 64].close) / $bars[$n - 64].close) - (($spy[$m - 1].close - $spy[$m - 64].close) / $spy[$m - 64].close)
    }
    $pass = ($edges.count -ge $jl.min_edges) -and ($heavy -ge $jl.heavy_volume_min_days) -and ($dv -ge $jl.min_dollar_volume) -and ($rs63 -gt 0)
    Check 'VRTX meets multiple-edge layer' $pass ("edges={0} [{1}] heavy={2} dv={3:N0}M rs63={4:P1} base={5} pivot={6}" -f $edges.count, ($edges.edges -join '/'), $heavy, ($dv / 1e6), $rs63, $vcp.baseStartIdx, $vcp.pivotIdx)
    $stop = Get-ZoneStop -Entry ([double]$vcp.pivot) -ZoneLow ([double]$edges.zoneLow) -BelowPct $jl.stop_below_edge_pct -MinPct $c.risk.stop_min_pct -MaxPct $c.risk.stop_max_pct
    $dist = 1 - ($stop / $vcp.pivot)
    Check 'VRTX zone stop inside 6-10%' (($dist -ge 0.0599) -and ($dist -le 0.1001) -and ($stop -lt $vcp.pivot)) ("pivot={0} zoneLow={1} stop={2} dist={3:P2}" -f $vcp.pivot, $edges.zoneLow, $stop, $dist)
}
else { Check 'VRTX bars cached' $false 'no cached bars' }

Write-Host ''
Write-Host ("jlaw tests: {0} failure(s)" -f $script:failures)
exit $(if ($script:failures -gt 0) { 1 } else { 0 })
