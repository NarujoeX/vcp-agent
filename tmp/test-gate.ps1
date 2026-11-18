# tmp/test-gate.ps1 - unit tests for the R1-R15 gate. Writes nothing to the journal.
. "$PSScriptRoot/../engine/lib/Common.ps1"
. "$PSScriptRoot/../engine/lib/Gate.ps1"

$c = Get-Config
$uni = @('US.TESTX', 'US.NVDA', 'US.AAPL')
$state = [pscustomobject]@{
    cash      = 100000.0
    reserved  = 0.0
    equity    = 100000.0
    positions = @()
    today     = [pscustomobject]@{ executedOrders = 0 }
}
$now = [datetimeoffset]::Parse('2026-11-18T11:00:00-05:00')

$bull = [pscustomobject]@{ ok = $true; symbol = 'US.SPY'; close = 600.0; sma = 580.0; smaPeriod = 50; falling = $false; bearish = $false }
$bear = [pscustomobject]@{ ok = $true; symbol = 'US.SPY'; close = 560.0; sma = 580.0; smaPeriod = 50; falling = $true; bearish = $true }
$unknown = [pscustomobject]@{ ok = $false; symbol = 'US.SPY'; bearish = $false; reason = 'insufficient benchmark history' }

$script:failures = 0

function T([string]$name, $proposal, [string]$expectRule, [double]$conv = 0.7, [datetimeoffset]$et = $now, [int]$newThisCycle = 0, $market = $bull) {
    $p = [pscustomobject]@{
        decisionId = 'test-' + $name; symbol = 'US.TESTX'; side = 'buy'; qty = 10; price = 100
        pivot = 100; stopPrice = 93; conviction = $conv; marketCap = 5e10; dollarVolume = 5e9; thesis = 'test'
    }
    foreach ($k in $proposal.Keys) { $p.$k = $proposal[$k] }
    $v = Test-Proposal -Proposal $p -State $state -Config $c -EtNow $et -NewThisCycle $newThisCycle -UniverseSymbols $uni -Market $market -AllowBuy
    $rules = @($v.violations | ForEach-Object { $_.rule })
    $ok = if ($expectRule -eq '') { $v.approved } else { $rules -contains $expectRule }
    $tag = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("{0}  {1,-34} expected {2,-5} got [{3}]" -f $tag, $name, $(if ($expectRule) { $expectRule } else { 'approve' }), ($rules -join ','))
    if (-not $ok) { $script:failures++ }
}

T 'clean buy' @{} ''
T 'starter too large' @{ qty = 100 } 'R4'
T 'price below US$1' @{ price = 0.5; qty = 100 } 'LIMIT'
T 'stop only 3% away' @{ stopPrice = 97 } 'R8'
T 'stop above pivot' @{ stopPrice = 101 } 'R8'
T 'conviction 0.30' @{} 'R9' 0.3
T 'NVDA in earnings blackout' @{ symbol = 'US.NVDA' } 'R12'
T 'SPY below falling 50DMA' @{} 'R13' 0.7 $now 0 $bear
T 'regime unknown' @{} 'R13' 0.7 $now 0 $unknown
T 'buy at 09:40 ET' @{} 'R14' 0.7 ([datetimeoffset]::Parse('2026-11-18T09:40:00-05:00'))
T 'buy at 09:46 ET' @{} '' 0.7 ([datetimeoffset]::Parse('2026-11-18T09:46:00-05:00'))
T 'thin dollar volume' @{ dollarVolume = 4e7 } 'R15'
T 'dollar volume unknown' @{ dollarVolume = 0 } 'R15'
T 'after flatten deadline' @{} 'R11' 0.7 ([datetimeoffset]::Parse('2026-11-26T11:00:00-05:00'))
T 'half-day 27 Nov' @{} 'R11' 0.7 ([datetimeoffset]::Parse('2026-11-27T11:00:00-05:00'))
T 'option symbol' @{ symbol = 'US.AAPL240119C00150000' } 'R2'
T 'outside universe' @{ symbol = 'US.ZZZZ' } 'R2'
T 'low market cap' @{ marketCap = 1e8 } 'LIMIT'
T 'short sell' @{ side = 'sell'; qty = 5 } 'R1'
T 'fourth new position this cycle' @{} 'R5' 0.7 $now 3

# add-to-loser needs a held position with negative P/L
$state2 = [pscustomobject]@{
    cash = 96000.0; reserved = 0.0; equity = 99600.0; today = [pscustomobject]@{ executedOrders = 0 }
    positions = @([pscustomobject]@{ symbol = 'US.TESTX'; qty = 40; avgCost = 100; marketValue = 3600; unrealizedPl = -400 })
}
$p = [pscustomobject]@{ decisionId = 'add-loser'; symbol = 'US.TESTX'; side = 'buy'; qty = 5; price = 90; pivot = 100; stopPrice = 84; conviction = 0.8; marketCap = 5e10; dollarVolume = 5e9 }
$v = Test-Proposal -Proposal $p -State $state2 -Config $c -EtNow $now -UniverseSymbols $uni -Market $bull -AllowBuy
$rules = @($v.violations | ForEach-Object { $_.rule })
if ($rules -contains 'R10') { Write-Host 'PASS  add to a losing position          expected R10   got [R10]' }
else { Write-Host ('FAIL  add to a losing position          got [' + ($rules -join ',') + ']'); $script:failures++ }

Write-Host ''
Write-Host ("gate tests: {0} failure(s)" -f $script:failures)
exit $(if ($script:failures -gt 0) { 1 } else { 0 })
