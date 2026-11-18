# tmp/probe2.ps1 - distribution of breakout-day volume vs 50-day average
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

$ratios = New-Object System.Collections.Generic.List[double]
$n = 0
for ($i = 262; $i -lt 369; $i += 6) {
    foreach ($sym in $data.Keys) {
        $bars = $data[$sym]
        if ($bars.Count -le $i) { continue }
        $slice = [object[]]@($bars[0..$i])
        $st = Get-Stage2 -Bars $slice -Config $c
        if (-not $st.pass) { continue }
        $v = Get-Vcp -Bars $slice -Config $c -Vol50 $st.vol50
        if (-not $v -or $v.state -ne 'breakout') { continue }
        $n++
        if ($st.vol50 -gt 0) { $ratios.Add($v.lastVol / $st.vol50) }
    }
}
Write-Host "breakout observations: $n"
if ($ratios.Count) {
    $s = @($ratios | Sort-Object)
    $q = { param($p) $s[[int][math]::Floor(($s.Count - 1) * $p)] }
    Write-Host ("vol/vol50  min={0:N2} p25={1:N2} median={2:N2} p75={3:N2} p90={4:N2} max={5:N2}" -f `
        $s[0], (& $q 0.25), (& $q 0.5), (& $q 0.75), (& $q 0.9), $s[$s.Count - 1])
    Write-Host ("share >=1.3x: {0:P0}   >=1.5x: {1:P0}" -f `
        (@($ratios | Where-Object { $_ -ge 1.3 }).Count / $ratios.Count), `
        (@($ratios | Where-Object { $_ -ge 1.5 }).Count / $ratios.Count))
}
