# tmp/heavy-probe.ps1 - diagnostic only (no rule change): for the six backtest candidates,
# count heavy days at 10/20/30/40 sessions before the base start and before the pivot, and
# locate the most recent heavy day before the breakout.
. "$PSScriptRoot/../engine/lib/Common.ps1"
. "$PSScriptRoot/../engine/lib/Data.ps1"
. "$PSScriptRoot/../engine/lib/Indicators.ps1"

$c = Get-Config
$jl = (Get-Rulebook).jlaw
$mult = To-Num $jl.heavy_volume_mult

$rows = @(
    [pscustomobject]@{ s = 'US.AMD'; d = '20260416' },
    [pscustomobject]@{ s = 'US.ADI'; d = '20260417' },
    [pscustomobject]@{ s = 'US.GS'; d = '20260714' },
    [pscustomobject]@{ s = 'US.ISNPY'; d = '20260813' },
    [pscustomobject]@{ s = 'US.UBS'; d = '20260831' },
    [pscustomobject]@{ s = 'US.VRTX'; d = '20260902' }
)

Write-Host ("{0,-9} {1,-9} {2,4} {3,4} {4,9} {5,9} {6,4} {7,4} {8,4} {9,4} {10,4} {11,4} {12,4} {13,4} {14,9}" -f `
        'symbol', 'breakout', 'bars', 'dBase', 'dPivot', 'baseToPiv', 'b10', 'b20', 'b30', 'b40', 'p10', 'p20', 'p30', 'p40', 'lastHeavy')

foreach ($r in $rows) {
    $bars = Load-Klines $r.s
    if (-not $bars) { Write-Host "$($r.s) no bars"; continue }
    $norm = { param($x) ([string]$x) -replace '[^0-9]', '' }
    $i = -1
    for ($k = $bars.Count - 1; $k -ge 0; $k--) { if ((& $norm $bars[$k].date) -eq $r.d) { $i = $k; break } }
    if ($i -lt 30) { Write-Host "$($r.s) date not found"; continue }

    $slice = [object[]]@($bars[0..$i])
    $st = Get-Stage2 -Bars $slice -Config $c
    $vcp = Get-Vcp -Bars $slice -Config $c -Vol50 $st.vol50
    if (-not $vcp) { Write-Host "$($r.s) no vcp on $($r.d)"; continue }

    $b = [int]$vcp.baseStartIdx
    $p = [int]$vcp.pivotIdx
    $b10 = Get-HeavyVolumeDays -Bars $slice -EndIdx $b -Vol50 $st.vol50 -Mult $mult -Look 10
    $b20 = Get-HeavyVolumeDays -Bars $slice -EndIdx $b -Vol50 $st.vol50 -Mult $mult -Look 20
    $b30 = Get-HeavyVolumeDays -Bars $slice -EndIdx $b -Vol50 $st.vol50 -Mult $mult -Look 30
    $b40 = Get-HeavyVolumeDays -Bars $slice -EndIdx $b -Vol50 $st.vol50 -Mult $mult -Look 40
    $p10 = Get-HeavyVolumeDays -Bars $slice -EndIdx $p -Vol50 $st.vol50 -Mult $mult -Look 10
    $p20 = Get-HeavyVolumeDays -Bars $slice -EndIdx $p -Vol50 $st.vol50 -Mult $mult -Look 20
    $p30 = Get-HeavyVolumeDays -Bars $slice -EndIdx $p -Vol50 $st.vol50 -Mult $mult -Look 30
    $p40 = Get-HeavyVolumeDays -Bars $slice -EndIdx $p -Vol50 $st.vol50 -Mult $mult -Look 40

    $lastHeavy = 0
    for ($k = $i - 1; $k -ge 0; $k--) {
        if ([double]$slice[$k].volume -ge ($mult * $st.vol50)) { $lastHeavy = $i - $k; break }
    }

    Write-Host ("{0,-9} {1,-9} {2,4} {3,4} {4,9} {5,9} {6,4} {7,4} {8,4} {9,4} {10,4} {11,4} {12,4} {13,4} {14,9}" -f `
            $r.s, $r.d, $i, ($i - $b), ($i - $p), ($b - $p), $b10, $b20, $b30, $b40, $p10, $p20, $p30, $p40, $lastHeavy)
}
