# 3-Reconcile.ps1
# Pulls the broker's view of the challenge account into state\portfolio.json.
# Everything downstream reads this file, never the API directly.
#
#   powershell -File engine\3-Reconcile.ps1
[CmdletBinding()]
param()

. "$PSScriptRoot/lib/Common.ps1"
. "$PSScriptRoot/lib/Data.ps1"

$c = Get-Config
$runDir = New-RunDir 'reconcile'
$acc = $c.account.account_id
$mkt = $c.account.market

$funds = Invoke-Moomoo -Arguments @('sim', 'account', 'funds', '--account', $acc) -RunDir $runDir
Save-Raw $funds $runDir 'funds'

$posResp = Invoke-Moomoo -Arguments @('sim', 'position', '--account', $acc, '--market', $mkt) -RunDir $runDir
Save-Raw $posResp $runDir 'positions'

$ordResp = Invoke-Moomoo -Arguments @('sim', 'order', 'list', '--account', $acc, '--market', $mkt) -RunDir $runDir
Save-Raw $ordResp $runDir 'orders'

function First-Prop {
    param($Object, [string[]]$Names, $Default = $null)
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($p -and $null -ne $p.Value) { return $p.Value }
    }
    $Default
}

$balance = To-Num (First-Prop $funds @('balance') 0)
$hold = To-Num (First-Prop $funds @('hold') 0)
$equity = To-Num (First-Prop $funds @('total_asset') 0)
$longMv = To-Num (First-Prop $funds @('long_mv') 0)

$positions = New-Object System.Collections.Generic.List[object]
$rawPositions = First-Prop $posResp @('positions', 'position_list', 'data')
foreach ($p in @($rawPositions)) {
    if ($null -eq $p) { continue }
    $sym = [string](First-Prop $p @('code', 'symbol', 'stock_code') '')
    if (-not $sym) { continue }
    if ($sym -notmatch '^US\.') { $sym = "US.$sym" }
    $qty = To-Num (First-Prop $p @('qty', 'quantity', 'stock_qty') 0)
    if ($qty -le 0) { continue }
    $cost = To-Num (First-Prop $p @('cost_price', 'avg_cost', 'average_cost') 0)
    $last = To-Num (First-Prop $p @('price', 'last_price', 'nominal_price') 0)
    $mv = To-Num (First-Prop $p @('market_val', 'market_value') ($qty * $last))
    $pl = To-Num (First-Prop $p @('pl_val', 'unrealized_pl', 'pl_ratio') 0)
    $positions.Add([pscustomobject]@{
            symbol       = $sym
            qty          = $qty
            avgCost      = [math]::Round($cost, 4)
            lastPrice    = [math]::Round($last, 4)
            marketValue  = [math]::Round($mv, 2)
            unrealizedPl = [math]::Round($pl, 2)
        })
}

$openOrders = New-Object System.Collections.Generic.List[object]
foreach ($o in @(First-Prop $ordResp @('orders') @())) {
    if ($null -eq $o) { continue }
    $status = To-Num (First-Prop $o @('status') 0)
    $qty = To-Num (First-Prop $o @('qty') 0)
    $cum = To-Num (First-Prop $o @('cum_qty') 0)
    # The list endpoint returns history too (cancelled = status 5). Treat an order
    # as live only while it can still fill: status 1-4 and not fully executed.
    $isLive = ($status -ge 1 -and $status -le 4) -and ($cum -lt $qty)
    if (-not $isLive) { continue }
    $openOrders.Add([pscustomobject]@{
            orderId  = [string](First-Prop $o @('order_id') '')
            symbol   = ('US.' + [string](First-Prop $o @('symbol', 'code') ''))
            side     = $(if ((First-Prop $o @('side') 0) -eq 1) { 'buy' } else { 'sell' })
            qty      = $qty
            filled   = $cum
            price    = To-Num (First-Prop $o @('price') 0)
            type     = $(if ((First-Prop $o @('order_type') 0) -eq 1) { 'limit' } else { 'market' })
            status   = $status
        })
}

# Orders placed by this engine today, from the journal (source of truth for limits).
$today = Get-Date -Format 'yyyy-MM-dd'
$executedToday = 0
$newToday = 0
foreach ($row in (Read-Jsonl (Get-Path 'journal\orders.jsonl'))) {
    if (([string](Get-Prop $row 'ts' '')).StartsWith($today) -and (Get-Prop $row 'submitted' $false)) { $executedToday++ }
}
foreach ($row in (Read-Jsonl (Get-Path 'journal\decisions.jsonl'))) {
    if (([string](Get-Prop $row 'ts' '')).StartsWith($today) -and (Get-Prop $row 'approved' $false)) { $newToday++ }
}

$state = [pscustomobject]@{
    asOf         = (Get-Date -Format 's')
    accountId    = $acc
    cash         = [math]::Round($balance, 2)
    reserved     = 0
    hold         = [math]::Round($hold, 2)
    equity       = [math]::Round($equity, 2)
    longMarketValue = [math]::Round($longMv, 2)
    investedCost = [math]::Round((($positions | ForEach-Object { $_.qty * $_.avgCost } | Measure-Object -Sum).Sum), 2)
    positions    = $positions.ToArray()
    openOrders   = $openOrders.ToArray()
    today        = [pscustomobject]@{
        date           = $today
        executedOrders = $executedToday
        approvedBuys   = $newToday
    }
    session      = (Get-SessionState)
}
Save-PortfolioState $state
Save-Raw $state $runDir 'state'

Write-Log ("Reconcile: cash={0:N2} hold={1:N2} equity={2:N2} positions={3} openOrders={4} ordersToday={5}" -f $state.cash, $state.hold, $state.equity, $positions.Count, $openOrders.Count, $executedToday) $runDir
Write-Output ("CASH={0:N2} EQUITY={1:N2} POSITIONS={2} ORDERS_TODAY={3}" -f $state.cash, $state.equity, $positions.Count, $executedToday)
