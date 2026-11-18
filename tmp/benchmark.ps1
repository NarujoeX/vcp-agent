# tmp/benchmark.ps1 - SPY buy-and-hold over the backtest window, and merge into results.
. "$PSScriptRoot/../engine/lib/Common.ps1"
. "$PSScriptRoot/../engine/lib/Data.ps1"

$btPath = Get-Path 'state\backtest-latest.json'
$bt = Read-JsonFile $btPath
if (-not $bt) { throw 'run Backtest.ps1 first' }

$spy = Load-Klines 'US.SPY'
$dates = @($spy | ForEach-Object { [string]$_.date })
$start = [string]$bt.window.start
$end = [string]$bt.window.end
$i0 = [array]::IndexOf($dates, $start)
$i1 = [array]::IndexOf($dates, $end)
if ($i0 -lt 0 -or $i1 -lt 0) { throw "window $start..$end not found in SPY bars" }
$p0 = [double]$spy[$i0].close
$p1 = [double]$spy[$i1].close
$ret = ($p1 - $p0) / $p0

$bt | Add-Member -NotePropertyName benchmark -NotePropertyValue ([pscustomobject]@{
        symbol = 'US.SPY'; startClose = $p0; endClose = $p1; totalReturn = [math]::Round($ret, 4)
    }) -Force
Write-JsonFile -Object $bt -Path $btPath
Write-Output ("SPY {0:N2} -> {1:N2}  return {2:P2}" -f $p0, $p1, $ret)
