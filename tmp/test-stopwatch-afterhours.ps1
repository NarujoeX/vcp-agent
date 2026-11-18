$ErrorActionPreference = 'Stop'
$root = 'C:\Users\REDACTED_USER\OneDrive\Desktop\VCP-Agent'
. "$root\engine\lib\Common.ps1"
. "$root\engine\lib\Exits.ps1"

$script:fail = 0
function Check($name, $got, $want) {
    if ("$got" -eq "$want") { "PASS  $name" }
    else { "FAIL  $name  got=[$got] want=[$want]"; $script:fail++ }
}

Check 'regular is protected' (Test-ProtectionWindow @{ session = 'regular' }) 'True'
Check 'afterhours is protected' (Test-ProtectionWindow @{ session = 'afterhours' }) 'True'
Check 'premarket is not protected' (Test-ProtectionWindow @{ session = 'premarket' }) 'False'
Check 'closed is not protected' (Test-ProtectionWindow @{ session = 'closed' }) 'False'

$rth = Get-SellOrderArgs -Symbol 'US.AAPL' -Qty 6 -Reference 0 -Text 'exit: test' -Account 'challenge-account' -Market 'US'
Check 'rth sell is a market order' ($rth -join ' ') 'sim order sell US.AAPL 6 --account challenge-account --market US --type market --text exit: test'

$ext = Get-SellOrderArgs -Symbol 'US.AAPL' -Qty 6 -Reference 350.3115 -Text 'exit: test' -Account 'challenge-account' -Market 'US' -Extended
Check 'extended sell is a crossing limit' ($ext -join ' ') 'sim order sell US.AAPL 6 --account challenge-account --market US --type limit --price 350.31 --session EXTENDED --text exit: test'

Check 'crossing price uses the bid' (Get-CrossingPrice -Bid 100 -Last 101) '99.5'
Check 'crossing price falls back to last -2%' (Get-CrossingPrice -Bid 0 -Last 100) '98'

function Ord($side, $status, $qty, $cum, $sym) {
    [pscustomobject]@{ side = $side; status = $status; qty = "$qty"; cum_qty = "$cum"; symbol = $sym }
}
$orders = @(
    Ord 2 1 10 0 'VRTX'      # working sell
    Ord 2 1 10 10 'AMD'      # fully filled
    Ord 2 5 10 0 'GS'        # cancelled
    Ord 1 1 10 0 'ADI'       # working buy - never blocks an exit
    Ord 2 3 10 4 'US.HLT'    # partly filled, prefixed symbol
    Ord 2 1 10 10 'UBS'
)
$working = Get-WorkingSellSymbols $orders
Check 'working sell detected, prefixed' (($working.Keys | Sort-Object) -join ',') 'US.HLT,US.VRTX'
Check 'filled sell is not working' ($working.ContainsKey('US.AMD')) 'False'
Check 'cancelled sell is not working' ($working.ContainsKey('US.GS')) 'False'
Check 'working buy never blocks' ($working.ContainsKey('US.ADI')) 'False'

# Live shape check: the cancelled smoke-test order must not read as a working sell.
$live = Invoke-Moomoo -Arguments @('sim', 'order', 'list', '--account', 'challenge-account', '--market', 'US')
$liveWorking = Get-WorkingSellSymbols (Get-Prop $live 'orders' @())
Check 'live order list has no working sells' $liveWorking.Count 0

"FAILURES=$($script:fail)"
