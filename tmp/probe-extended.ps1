# tmp/probe-extended.ps1 - one-off proof of the EXTENDED-session order path.
# Buy 1 share, rest a sell two ticks above the market, cancel it, then flatten.
# Every order is journalled with probe = $true so it never counts as a strategy trade.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('quote', 'buy', 'sell', 'cancel', 'flatten', 'status')]
    [string]$Step,
    [string]$Symbol = 'US.F',
    [string]$OrderId = ''
)

$ErrorActionPreference = 'Stop'
. 'C:\Users\REDACTED_USER\OneDrive\Desktop\VCP-Agent\engine\lib\Common.ps1'

$c = Get-Config
$acc = $c.account.account_id
$mkt = $c.account.market
$runDir = New-RunDir 'probe-extended'

function Get-Quote {
    $snap = Invoke-Moomoo -Arguments @('snapshot', $Symbol) -RunDir $runDir
    $s = @(Get-Prop $snap 'snapshot_list' @()) | Where-Object { $_ } | Select-Object -First 1
    if (-not $s) { throw "no snapshot for $Symbol" }
    [pscustomobject]@{
        symbol = [string](Get-Prop $s 'code' $Symbol)
        last   = To-Num (Get-Prop $s 'last_price' 0)
        bid    = To-Num (Get-Prop $s 'bid_price' 0)
        ask    = To-Num (Get-Prop $s 'ask_price' 0)
        after  = To-Num (Get-Prop $s 'after_price' 0)
    }
}

function Show-State {
    $p = Invoke-Moomoo -Arguments @('sim', 'position', '--account', $acc, '--market', $mkt) -RunDir $runDir
    $o = Invoke-Moomoo -Arguments @('sim', 'order', 'list', '--account', $acc, '--market', $mkt) -RunDir $runDir
    $positions = @(Get-Prop $p 'positions' @()) | Where-Object { $_ }
    "positions: " + $(if ($positions) {
            ($positions | ForEach-Object { "{0} qty={1} cost={2}" -f (Get-Prop $_ 'code' ''), (Get-Prop $_ 'qty' 0), (Get-Prop $_ 'cost_price' 0) }) -join '; '
        }
        else { 'none' })
    foreach ($ord in @(Get-Prop $o 'orders' @())) {
        if (-not $ord) { continue }
        if ((To-Num (Get-Prop $ord 'status' 0)) -lt 1 -or (To-Num (Get-Prop $ord 'status' 0)) -gt 4) { continue }
        "open order: {0} {1} {2} qty={3} cum={4} price={5} status={6}" -f (Get-Prop $ord 'order_id' ''), (Get-Prop $ord 'symbol' ''), (Get-Prop $ord 'side' ''), (Get-Prop $ord 'qty' 0), (Get-Prop $ord 'cum_qty' 0), (Get-Prop $ord 'price' ''), (Get-Prop $ord 'status' 0)
    }
}

function Send-Order {
    param([string]$Side, [string]$Price, [string]$Text)
    $a = @('sim', 'order', $Side, $Symbol, '1', '--account', $acc, '--market', $mkt,
        '--type', 'limit', '--price', $Price, '--session', 'EXTENDED', '--text', $Text)
    "sending: moomoo " + ($a -join ' ')
    $resp = Invoke-Moomoo -Arguments $a -RunDir $runDir
    Save-Raw $resp $runDir ("probe-" + $Side + "-" + ($Symbol -replace '\.', '_'))
    $id = Get-Prop $resp 'order_id' $null
    Add-Jsonl -Object ([pscustomobject]@{
            ts = (Get-Date -Format 's'); symbol = $Symbol; side = $Side; qty = 1
            price = [double]$Price; orderType = 'limit/EXTENDED'; reason = $Text
            orderId = $id; submitted = $true; probe = $true
        }) -Path (Get-Path 'journal\orders.jsonl')
    "response: " + ($resp | ConvertTo-Json -Compress)
}

switch ($Step) {
    'quote' {
        $q = Get-Quote
        "quote {0}: last={1} bid={2} ask={3} after={4}" -f $q.symbol, $q.last, $q.bid, $q.ask, $q.after
    }
    'buy' {
        $q = Get-Quote
        $px = if ($q.ask -gt 0) { $q.ask } else { [math]::Round($q.last * 1.02, 2) }
        Send-Order -Side 'buy' -Price ($px.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)) -Text 'probe: extended session entry'
    }
    'sell' {
        $q = Get-Quote
        $px = [math]::Round($q.last + 0.02, 2)
        "probe sell two ticks above last ({0} + 0.02)" -f $q.last
        Send-Order -Side 'sell' -Price ($px.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)) -Text 'probe: extended session resting sell'
    }
    'cancel' {
        if (-not $OrderId) { throw 'cancel needs -OrderId' }
        "cancelling $OrderId"
        $resp = Invoke-Moomoo -Arguments @('sim', 'order', 'cancel', $OrderId, '--account', $acc, '--market', $mkt) -RunDir $runDir
        Save-Raw $resp $runDir 'probe-cancel'
        "response: " + ($resp | ConvertTo-Json -Compress)
    }
    'flatten' {
        $q = Get-Quote
        $px = if ($q.bid -gt 0) { $q.bid } else { [math]::Round($q.last * 0.98, 2) }
        Send-Order -Side 'sell' -Price ($px.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)) -Text 'probe: extended session exit'
    }
    'status' { Show-State }
}
