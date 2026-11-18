# tmp/probe.ps1 - count Stage2 / VCP / breakout at a few dates to see why the backtest is empty
. "$PSScriptRoot/../engine/lib/Common.ps1"
. "$PSScriptRoot/../engine/lib/Data.ps1"
. "$PSScriptRoot/../engine/lib/Indicators.ps1"

$c = Get-Config
$u = Load-Universe
$ms = @($u.members | Sort-Object marketCap -Descending | Select-Object -First 200)
$data = @{}
foreach ($m in $ms) {
    $b = Load-Klines $m.symbol
    if (-not $b -or $b.Count -lt 280) { continue }
    $data[$m.symbol] = $b
}
$len = ($data.Values | Measure-Object -Property Count -Maximum).Maximum
Write-Host "symbols=$($data.Count) len=$len"

foreach ($i in 262, 280, 300, 320, 340, 360, 368) {
    $n2 = 0; $nv = 0; $nb = 0; $nvol = 0
    foreach ($sym in $data.Keys) {
        $bars = $data[$sym]
        if ($bars.Count -le $i) { continue }
        $slice = [object[]]@($bars[0..$i])
        $st = Get-Stage2 -Bars $slice -Config $c
        if (-not $st.pass) { continue }
        $n2++
        $v = Get-Vcp -Bars $slice -Config $c -Vol50 $st.vol50
        if (-not $v) { continue }
        $nv++
        if ($v.state -eq 'breakout') { $nb++; if ($v.volumeOk) { $nvol++ } }
    }
    Write-Host ("i={0} date={1} stage2={2} vcp={3} breakout={4} breakoutVol={5}" -f $i, $data['US.AAPL'][$i].date, $n2, $nv, $nb, $nvol)
}
