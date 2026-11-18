# Gate.ps1 - deterministic R1-R15 enforcement. No API calls, no judgement.
# Every proposal is either APPROVED with the exact rule table evaluated, or REJECTED
# with the ids of the rules it broke. This is the only path to an order.

function Get-StarterQty {
    param([double]$Equity, [double]$Price, $Config)
    if ($Price -le 0) { return 0 }
    $target = $Config.risk.starter_pct * $Equity
    [int][math]::Floor($target / $Price)
}

# J Law fallback: from fallback_from, plain VCP is allowed while fewer than the minimum
# number of distinct tickers has traded. Time-boxed and counted, never a general waiver.
function Test-JLawFallback {
    param([int]$TradedCount, [datetimeoffset]$EtNow = (Get-EtNow), $Rulebook = (Get-Rulebook))
    $jl = Get-Prop $Rulebook 'jlaw' $null
    if (-not $jl -or -not [bool](Get-Prop $jl 'enabled' $false)) { return $false }
    $from = [string](Get-Prop $jl 'fallback_from' '')
    if (-not $from) { return $false }
    if ($EtNow -lt [datetimeoffset]::Parse($from)) { return $false }
    ($TradedCount -lt [int](Get-Prop $jl 'min_distinct_tickers' 3))
}

function Test-Proposal {
    param(
        [Parameter(Mandatory)] $Proposal,
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] $Config,
        [datetimeoffset]$EtNow = (Get-EtNow),
        [int]$NewThisCycle = 0,
        [string[]]$UniverseSymbols = @(),
        $Market = $null,
        [switch]$AllowBuy
    )
    $v = New-Object System.Collections.Generic.List[object]
    $rules = Get-Rulebook
    $lim = $rules.competition_limits

    $sym = [string]$Proposal.symbol
    $side = [string]$Proposal.side
    $price = To-Num $Proposal.price
    $qty = [int](To-Num $Proposal.qty)
    $isBuy = ($side -eq 'buy')

    $held = @($State.positions | Where-Object { $_.symbol -eq $sym })
    $heldQty = if ($held.Count) { [int]$held[0].qty } else { 0 }
    $heldPl = if ($held.Count) { To-Num $held[0].unrealizedPl } else { 0 }
    $heldMv = if ($held.Count) { To-Num $held[0].marketValue } else { 0 }
    $isNew = ($heldQty -eq 0)

    # ---- R1 long only --------------------------------------------------
    if ($side -notin @('buy', 'sell')) { $v.Add(@{ rule = 'R1'; msg = "side '$side' is not buy/sell" }) }
    if (-not $isBuy -and $qty -gt $heldQty) { $v.Add(@{ rule = 'R1'; msg = "sell $qty exceeds held $heldQty (would short)" }) }

    # ---- R2 instrument whitelist ---------------------------------------
    if ($sym -notmatch '^US\.[A-Z][A-Z0-9.\-]*$') { $v.Add(@{ rule = 'R2'; msg = "symbol '$sym' is not a US stock/ETF code" }) }
    if ($sym -match '\d{6}[CP]\d') { $v.Add(@{ rule = 'R2'; msg = 'options are not permitted' }) }
    if ($UniverseSymbols.Count -and $UniverseSymbols -notcontains $sym) { $v.Add(@{ rule = 'R2'; msg = "$sym is outside the audited universe" }) }

    # ---- R3 cash only --------------------------------------------------
    # State.cash is *available* cash (pending-order holds already excluded),
    # so it can never cover a 2x buying-power position. max_power_long is unused.
    if ($isBuy) {
        $cost = $qty * $price
        $reserved = To-Num $State.reserved
        if (($cost + $reserved) -gt (To-Num $State.cash)) {
            $v.Add(@{ rule = 'R3'; msg = ("cost {0:N0} + reserved {1:N0} > available cash {2:N0}" -f $cost, $reserved, (To-Num $State.cash)) })
        }
    }

    # ---- R4 starter size / adds to winners only -------------------------
    if ($isBuy) {
        $equity = To-Num $State.equity
        if ($isNew) {
            $target = $Config.risk.starter_pct * $equity
            $cost = $qty * $price
            if ($qty -lt 1) { $v.Add(@{ rule = 'R4'; msg = ('one share {0:N2} exceeds starter {1:N0}' -f $price, $target) }) }
            elseif ($cost -gt $target * (1 + $Config.risk.starter_tolerance_pct)) {
                $v.Add(@{ rule = 'R4'; msg = ('starter {0:N0} exceeds {1:N0} target' -f $cost, $target) })
            }
        }
        else {
            if ($heldPl -le 0) { $v.Add(@{ rule = 'R10'; msg = ('add to {0} refused: unrealised P/L {1:N0} <= 0 (no averaging down)' -f $sym, $heldPl) }) }
        }
    }

    # ---- R5 max new positions per cycle --------------------------------
    if ($isBuy -and $isNew -and $NewThisCycle -ge $Config.risk.max_new_per_cycle) {
        $v.Add(@{ rule = 'R5'; msg = ("already {0} new positions this cycle (max {1})" -f $NewThisCycle, $Config.risk.max_new_per_cycle) })
    }

    # ---- R6 max open positions -----------------------------------------
    $positions = @(Get-Prop $State 'positions' @())
    $openCount = $positions.Count
    if ($isBuy -and $isNew -and $openCount -ge $Config.risk.max_open_positions) {
        $v.Add(@{ rule = 'R6'; msg = ("{0} open positions (max {1})" -f $openCount, $Config.risk.max_open_positions) })
    }
    if ($isBuy -and $isNew -and $openCount -ge $lim.max_positions) {
        $v.Add(@{ rule = 'R6'; msg = ("competition cap {0} positions reached" -f $lim.max_positions) })
    }

    # ---- R7 single-stock cap -------------------------------------------
    if ($isBuy) {
        $equity = To-Num $State.equity
        $resulting = $heldMv + ($qty * $price)
        if ($equity -gt 0 -and ($resulting / $equity) -gt $Config.risk.hard_stock_cap_pct) {
            $v.Add(@{ rule = 'R7'; msg = ('{0} at {1:P0} of equity exceeds competition hard cap {2:P0}' -f $sym, ($resulting / $equity), $Config.risk.hard_stock_cap_pct) })
        }
        elseif ($equity -gt 0 -and ($resulting / $equity) -gt $Config.risk.max_stock_pct) {
            $v.Add(@{ rule = 'R7'; msg = ('{0} at {1:P0} of equity exceeds {2:P0} cap' -f $sym, ($resulting / $equity), $Config.risk.max_stock_pct) })
        }
    }

    # ---- R8 protective stop --------------------------------------------
    if ($isBuy) {
        $stop = To-Num $Proposal.stopPrice
        $pivot = To-Num $Proposal.pivot
        if ($stop -le 0) { $v.Add(@{ rule = 'R8'; msg = 'buy without a stop price' }) }
        else {
            $stopPct = ($price - $stop) / $price
            if ($stopPct -lt $Config.risk.stop_min_pct -or $stopPct -gt $Config.risk.stop_max_pct) {
                $v.Add(@{ rule = 'R8'; msg = ('stop distance {0:P1} outside {1:P0}-{2:P0}' -f $stopPct, $Config.risk.stop_min_pct, $Config.risk.stop_max_pct) })
            }
            if ($pivot -gt 0 -and $stop -ge $pivot) { $v.Add(@{ rule = 'R8'; msg = ('stop {0:N2} is not below pivot {1:N2}' -f $stop, $pivot) }) }
        }
    }

    # ---- R9 conviction floor -------------------------------------------
    if ($isBuy -and (To-Num $Proposal.conviction) -lt $Config.risk.conviction_floor) {
        $v.Add(@{ rule = 'R9'; msg = ('conviction {0:N2} below floor {1:N2}' -f (To-Num $Proposal.conviction), $Config.risk.conviction_floor) })
    }

    # ---- R11 holiday flatten -------------------------------------------
    if ($isBuy) {
        if (Test-PastFlattenDeadline $EtNow) { $v.Add(@{ rule = 'R11'; msg = 'past the Thanksgiving flatten deadline' }) }
        elseif (Test-NoNewEntries $EtNow) { $v.Add(@{ rule = 'R11'; msg = 'no new entries after 25 Nov' }) }
        if (-not $AllowBuy) { $v.Add(@{ rule = 'GATE'; msg = 'entries are closed for this cycle' }) }
    }

    # ---- R12 event blackout --------------------------------------------
    if ($isBuy) {
        foreach ($eb in @(Get-Prop $rules 'event_blackout' @())) {
            if ($null -eq $eb) { continue }
            $ebSym = [string](Get-Prop $eb 'symbol' '')
            $ebUntil = [string](Get-Prop $eb 'until' '')
            if ($ebSym -and $ebSym -eq $sym -and $ebUntil) {
                if ($EtNow -lt [datetimeoffset]::Parse($ebUntil)) {
                    $v.Add(@{ rule = 'R12'; msg = ('{0} in earnings blackout until {1} ({2})' -f $sym, $ebUntil, (Get-Prop $eb 'reason' '')) })
                }
            }
        }
    }

    # ---- R13 index regime (J Law: no buys into a correction) ------------
    if ($isBuy) {
        $mkt = $Market
        if (-not $mkt) {
            $mp = Get-Path 'state\market.json'
            if (Test-Path $mp) { $mkt = Read-JsonFile $mp }
        }
        if (-not $mkt -or -not [bool](Get-Prop $mkt 'ok' $false)) {
            $v.Add(@{ rule = 'R13'; msg = 'market regime unknown: no fresh state\market.json (fail closed)' })
        }
        elseif ([bool](Get-Prop $mkt 'bearish' $false)) {
            $v.Add(@{ rule = 'R13'; msg = ('{0} {1:N2} below a falling {2}-day {3:N2}: no new buys in a correction' -f `
                        (Get-Prop $mkt 'symbol' 'US.SPY'), (To-Num (Get-Prop $mkt 'close' 0)), (Get-Prop $mkt 'smaPeriod' 50), (To-Num (Get-Prop $mkt 'sma' 0))) })
        }
    }

    # ---- R14 opening blackout ------------------------------------------
    if ($isBuy) {
        $mins = To-Num (Get-Prop (Get-Prop $rules 'jlaw' $null) 'opening_blackout_minutes' 15)
        $et = To-EtDate $EtNow
        $t = $et.TimeOfDay
        $open = [TimeSpan]'09:30:00'
        if ($t -ge $open -and $t -lt $open.Add([TimeSpan]::FromMinutes($mins))) {
            $v.Add(@{ rule = 'R14'; msg = ('first {0} minutes after the open: no new buys' -f $mins) })
        }
    }

    # ---- R15 liquidity floor -------------------------------------------
    if ($isBuy) {
        $dv = To-Num (Get-Prop $Proposal 'dollarVolume' 0)
        $floor = To-Num (Get-Prop (Get-Prop $rules 'jlaw' $null) 'min_dollar_volume' 100000000)
        if ($dv -le 0) { $v.Add(@{ rule = 'R15'; msg = 'dollar volume unknown for this proposal' }) }
        elseif ($dv -lt $floor) { $v.Add(@{ rule = 'R15'; msg = ('dollar volume {0:N0}M below the US${1:N0}M floor' -f ($dv / 1e6), ($floor / 1e6)) }) }
    }

    # ---- competition limits --------------------------------------------
    if ($isBuy) {
        if ($price -lt $lim.min_price) { $v.Add(@{ rule = 'LIMIT'; msg = ('price {0:N2} below US${1:N2}' -f $price, $lim.min_price) }) }
        $mc = To-Num $Proposal.marketCap
        if ($mc -gt 0 -and $mc -lt $lim.min_market_cap) { $v.Add(@{ rule = 'LIMIT'; msg = ('market cap {0:N0} below US${1:N0}' -f $mc, $lim.min_market_cap) }) }
    }
    $ordersToday = 0
    if (Get-Prop (Get-Prop $State 'today') 'executedOrders') { $ordersToday = [int]$State.today.executedOrders }
    if ($ordersToday -ge $lim.max_executed_orders_per_day) { $v.Add(@{ rule = 'LIMIT'; msg = ('{0} orders today (max {1})' -f $ordersToday, $lim.max_executed_orders_per_day) }) }

    [pscustomobject]@{
        decisionId   = Get-Prop $Proposal 'decisionId' ((Get-Date -Format 'yyyyMMddHHmmss') + '-' + $sym)
        symbol       = $sym
        side         = $side
        qty          = $qty
        price        = $price
        notional     = [math]::Round($qty * $price, 2)
        approved     = ($v.Count -eq 0)
        violations   = $v.ToArray()
        rulesChecked = @('R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7', 'R8', 'R9', 'R10', 'R11', 'R12', 'R13', 'R14', 'R15', 'LIMIT')
        evaluatedAt  = (Get-Date -Format 's')
    }
}

function Add-Decision {
    param([Parameter(Mandatory)] $Verdict, $Proposal, [string]$Reason = '')
    Add-Jsonl -Object ([pscustomobject]@{
            ts         = (Get-Date -Format 's')
            decisionId = $Verdict.decisionId
            symbol     = $Verdict.symbol
            side       = $Verdict.side
            qty        = $Verdict.qty
            price      = $Verdict.price
            notional   = $Verdict.notional
            approved   = $Verdict.approved
            violations = $Verdict.violations
            conviction = (Get-Prop $Proposal 'conviction' $null)
            thesis     = (Get-Prop $Proposal 'thesis' '')
            pivot      = (Get-Prop $Proposal 'pivot' $null)
            stopPrice  = (Get-Prop $Proposal 'stopPrice' $null)
            reason     = $Reason
        }) -Path (Get-Path 'journal\decisions.jsonl')
}
