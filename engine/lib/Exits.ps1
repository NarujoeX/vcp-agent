# Exits.ps1 - protective stops, trailing and time exits.
#
# Moomoo's simulated trading API supports only market and limit orders (no stop
# order type), so a stop cannot rest on the book. It is enforced by a 60-second
# watch loop that sells the first time price trades at or below the stop: a market
# order in the regular session, a limit under the bid with the EXTENDED session in
# after-hours, where market orders are not accepted. README "Known deviations"
# records this and the measured latency.

function Get-Stops {
    $s = Read-JsonFile (Get-Path 'state\stops.json')
    if (-not $s) { return [pscustomobject]@{} }
    $s
}

function Save-Stops {
    param($Stops)
    Write-JsonFile -Object $Stops -Path (Get-Path 'state\stops.json')
}

function Add-Stop {
    param([string]$Symbol, [double]$Entry, [double]$Stop, [double]$Atr, [string]$OpenedDate, [double]$Pivot)
    $stops = Get-Stops
    $rec = [pscustomobject]@{
        symbol      = $Symbol
        entry       = [math]::Round($Entry, 4)
        pivot       = [math]::Round($Pivot, 4)
        initialStop = [math]::Round($Stop, 4)
        stop        = [math]::Round($Stop, 4)
        atr         = [math]::Round($Atr, 4)
        highestClose = [math]::Round($Entry, 4)
        openedDate  = $OpenedDate
        breakeven   = $false
        lastUpdate  = (Get-Date -Format 's')
    }
    $props = @{}
    foreach ($p in $stops.PSObject.Properties) { $props[$p.Name] = $p.Value }
    $props[$Symbol] = $rec
    Save-Stops ([pscustomobject]$props)
    $rec
}

# Trailing logic, run on every cycle for every open position.
# Returns updated stop for one position (does not write).
function Get-TrailedStop {
    param($StopRec, [double]$Last, $Config)
    $s = $Config.strategy
    $stop = To-Num $StopRec.stop
    $entry = To-Num $StopRec.entry
    $atr = To-Num $StopRec.atr
    $high = [math]::Max((To-Num $StopRec.highestClose), $Last)
    $breakeven = [bool](Get-Prop $StopRec 'breakeven' $false)

    if (-not $breakeven -and $Last -ge $entry * (1 + $s.breakeven_trigger_pct)) {
        $breakeven = $true
        $stop = [math]::Max($stop, $entry)
    }
    if ($breakeven -and $atr -gt 0) {
        $trail = $high - ($s.trail_atr_mult * $atr)
        $stop = [math]::Max($stop, $trail)
    }
    [pscustomobject]@{
        stop         = [math]::Round($stop, 4)
        highestClose = [math]::Round($high, 4)
        breakeven    = $breakeven
    }
}

function Get-HoldDays {
    param([string]$OpenedDate, [int]$CurrentDateInt)
    if (-not $OpenedDate) { return 0 }
    try {
        $d0 = [datetime]::ParseExact($OpenedDate, 'yyyy-MM-dd', $null)
        $d1 = [datetime]::ParseExact([string]$CurrentDateInt, 'yyyyMMdd', $null)
        [int]($d1 - $d0).TotalDays
    }
    catch { 0 }
}

# J Law trim: one third once price is 3 ATR above entry. Returns $null or the order to send.
function Get-TrimOrder {
    param([double]$Entry, [double]$Last, [double]$Atr, [double]$Qty, $Config)
    if ($Entry -le 0 -or $Atr -le 0 -or $Qty -lt 2) { return $null }
    $jl = (Get-Rulebook).jlaw
    $mult = To-Num (Get-Prop $jl 'trim_atr_mult' 3.0)
    $frac = To-Num (Get-Prop $jl 'trim_fraction' 0.33)
    $extendedAt = $Entry + ($mult * $Atr)
    if ($Last -lt $extendedAt) { return $null }
    $q = [int][math]::Floor($Qty * $frac)
    if ($q -lt 1) { $q = 1 }
    if ($q -ge $Qty) { $q = [int]$Qty - 1 }
    if ($q -lt 1) { return $null }
    [pscustomobject]@{ qty = $q; extendedAt = $extendedAt; atrMult = $mult }
}

# A sell limit priced under the bid crosses like a market order. Outside RTH the paper API
# rejects market orders, so the same stop becomes a limit order in the EXTENDED session.
function Get-SellOrderArgs {
    param([string]$Symbol, $Qty, [double]$Reference, [string]$Text, [string]$Account, [string]$Market, [switch]$Extended)
    $a = @('sim', 'order', 'sell', $Symbol, "$Qty", '--account', $Account, '--market', $Market)
    if ($Extended) {
        $px = [math]::Round([math]::Max(0.01, $Reference), 2).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
        $a += @('--type', 'limit', '--price', $px, '--session', 'EXTENDED')
    }
    else {
        $a += @('--type', 'market')
    }
    $a + @('--text', $Text)
}

# Crossing price for an extended-session limit: just under the bid, or 2% under last.
function Get-CrossingPrice {
    param([double]$Bid, [double]$Last)
    if ($Bid -gt 0) { return $Bid * 0.995 }
    $Last * 0.98
}

# Symbols that already have a sell which can still fill. The order list returns history too,
# so a cancelled or fully filled order is not a reason to hold off.
function Get-WorkingSellSymbols {
    param($Orders)
    $map = @{}
    foreach ($o in @($Orders)) {
        if ($null -eq $o) { continue }
        if ((To-Num (Get-Prop $o 'side' 1)) -eq 1) { continue }
        $status = To-Num (Get-Prop $o 'status' 0)
        if ($status -lt 1 -or $status -gt 4) { continue }
        if ((To-Num (Get-Prop $o 'cum_qty' 0)) -ge (To-Num (Get-Prop $o 'qty' 0))) { continue }
        $sym = [string](Get-Prop $o 'symbol' (Get-Prop $o 'code' ''))
        if ($sym -and $sym -notmatch '^US\.') { $sym = "US.$sym" }
        if ($sym) { $map[$sym] = $true }
    }
    $map
}
