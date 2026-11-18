. "$PSScriptRoot\..\engine\lib\Common.ps1"
. "$PSScriptRoot\..\engine\lib\Data.ps1"
. "$PSScriptRoot\..\engine\lib\Indicators.ps1"
$c = Get-Config
foreach ($sym in @('US.AAPL', 'US.LLY')) {
    $b = Load-Klines $sym
    $st = Get-Stage2 -Bars $b -Config $c
    Write-Host "=== $sym n=$($b.Count) vol50=$([math]::Round($st.vol50)) ==="
    $piv = @(Find-Swings -Bars $b -ThresholdPct 0.03)
    Write-Host "pivots=$($piv.Count)"
    $last = @($piv | Select-Object -Last 8)
    foreach ($p in $last) { Write-Host ("  {0} idx={1} price={2:N2} date={3}" -f $p.type, $p.i, $p.price, $b[$p.i].date) }
    $v = Get-Vcp -Bars $b -Config $c -Vol50 $st.vol50
    if ($v) { Write-Host ("VCP: state=$($v.state) pivot=$($v.pivot) n=$($v.contractions) depths=$($v.depths -join ',') vols=$($v.avgVols -join ',') lastVolRatio=$($v.lastVolRatio) score=$($v.score)") }
    else { Write-Host "VCP: NULL" }
}
