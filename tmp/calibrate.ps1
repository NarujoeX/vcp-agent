# tmp/calibrate.ps1 - parameter sweep over the cached universe (no API calls).
. "$PSScriptRoot/../engine/lib/Common.ps1"
. "$PSScriptRoot/../engine/lib/Data.ps1"
. "$PSScriptRoot/../engine/lib/Indicators.ps1"

$base = Get-Config
$u = Load-Universe
$rows = New-Object System.Collections.Generic.List[object]

$symbols = @($u.members)
$cache = @{}
foreach ($m in $symbols) {
    $b = Load-Klines $m.symbol
    if (-not $b -or $b.Count -lt 260) { continue }
    $st = Get-Stage2 -Bars $b -Config $base
    if (-not $st.pass) { continue }
    $cache[$m.symbol] = @{ bars = $b; st = $st }
}
Write-Host ("stage2 loaded: " + $cache.Count)

foreach ($thr in 0.03, 0.04, 0.05) {
    foreach ($dry in 1.0, 1.25) {
        $cfg = Get-Config
        $cfg.strategy.swing_threshold_pct = $thr
        $cfg.strategy.volume_dryup_ratio = $dry
        $pass = 0; $bo = 0; $conv = New-Object System.Collections.Generic.List[double]
        $top = New-Object System.Collections.Generic.List[object]
        foreach ($sym in $cache.Keys) {
            $e = $cache[$sym]
            $v = Get-Vcp -Bars $e.bars -Config $cfg -Vol50 $e.st.vol50
            if (-not $v) { continue }
            $pass++
            if ($v.state -eq 'breakout') { $bo++ }
            $conv.Add($v.score)
            $top.Add([pscustomobject]@{ sym = $sym; state = $v.state; score = $v.score; depths = ($v.depths -join '/') })
        }
        $avg = if ($conv.Count) { [math]::Round((($conv | Measure-Object -Average).Average), 3) } else { 0 }
        Write-Host ("thr={0:P0} dryup<{1}  vcp={2} breakouts={3} avgScore={4}" -f $thr, $dry, $pass, $bo, $avg)
        foreach ($t in @($top | Sort-Object score -Descending | Select-Object -First 5)) {
            Write-Host ("     {0,-9} {1,-8} score={2} depths={3}" -f $t.sym, $t.state, $t.score, $t.depths)
        }
    }
}
