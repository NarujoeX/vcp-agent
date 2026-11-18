# 6-StopWatch.ps1
# Protective risk loop. Intended cadence: 60 seconds through the regular session and
# after-hours. Moomoo sim has no stop order type, so this IS the stop: on breach it sells
# immediately - a market order in RTH, a crossing limit with the EXTENDED session outside it.
#
#   powershell -File engine\6-StopWatch.ps1            # enforce (submits sells)
#   powershell -File engine\6-StopWatch.ps1 -DryRun    # report only
#   powershell -File engine\6-StopWatch.ps1 -Loop      # loop every 60s until 20:00 ET
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Loop
)

. "$PSScriptRoot/lib/Common.ps1"
. "$PSScriptRoot/lib/Data.ps1"
. "$PSScriptRoot/lib/Exits.ps1"

if ($Loop) {
    $passArgs = @{}
    if ($DryRun) { $passArgs.DryRun = $true }
    if ($Force) { $passArgs.Force = $true }
    while ($true) {
        $s = Get-SessionState
        if (-not $Force -and -not (Test-ProtectionWindow $s)) {
            Write-Output ("LOOP stop: session={0}" -f $s.session)
            break
        }
        & $PSCommandPath @passArgs
        Start-Sleep -Seconds 60
    }
    exit 0
}

$c = Get-Config
$session = Get-SessionState
if (-not $Force -and -not (Test-ProtectionWindow $session)) {
    Write-Output ("SKIP session={0} reason={1}" -f $session.session, $session.reason)
    exit 0
}
$extended = $session.session -eq 'afterhours'

$runDir = New-RunDir 'stopwatch'
$acc = $c.account.account_id
$mkt = $c.account.market

$posResp = Invoke-Moomoo -Arguments @('sim', 'position', '--account', $acc, '--market', $mkt) -RunDir $runDir
$raw = Get-Prop $posResp 'positions' (Get-Prop $posResp 'position_list' @())
$positions = New-Object System.Collections.Generic.List[object]
foreach ($p in @($raw)) {
    if ($null -eq $p) { continue }
    $sym = [string](Get-Prop $p 'code' (Get-Prop $p 'symbol' ''))
    if (-not $sym) { continue }
    if ($sym -notmatch '^US\.') { $sym = "US.$sym" }
    $qty = To-Num (Get-Prop $p 'qty' 0)
    if ($qty -le 0) { continue }
    $positions.Add([pscustomobject]@{
            symbol  = $sym
            qty     = $qty
            avgCost = To-Num (Get-Prop $p 'cost_price' 0)
        })
}

if ($positions.Count -eq 0) {
    Write-Output 'FLAT no positions'
    exit 0
}

Write-Log ("session={0} orderMode={1}" -f $session.session, $(if ($extended) { 'limit/EXTENDED' } else { 'market' })) $runDir

# A resting sell that can still fill must not be replaced by a second one 60 seconds later.
$ordResp = Invoke-Moomoo -Arguments @('sim', 'order', 'list', '--account', $acc, '--market', $mkt) -RunDir $runDir
$workingSells = Get-WorkingSellSymbols (Get-Prop $ordResp 'orders' @())
if ($workingSells.Count -gt 0) {
    Write-Log ("working sells: {0}" -f (($workingSells.Keys | Sort-Object) -join ', ')) $runDir
}

$snap = Invoke-Moomoo -Arguments (@('snapshot') + @($positions | ForEach-Object { $_.symbol })) -RunDir $runDir
Save-Raw $snap $runDir 'snapshot'
$snapMap = @{}
foreach ($s in @(Get-Prop $snap 'snapshot_list' @())) {
    if ($s) { $snapMap[[string]$s.code] = $s }
}

$stops = Get-Stops
$flatten = Test-PastFlattenDeadline
$today = (Get-EtNow).ToString('yyyyMMdd')
$exits = New-Object System.Collections.Generic.List[object]
$trims = New-Object System.Collections.Generic.List[object]

foreach ($pos in $positions) {
    $quote = if ($snapMap.ContainsKey($pos.symbol)) { $snapMap[$pos.symbol] } else { $null }
    if (-not $quote) { continue }
    $last = To-Num (Get-Prop $quote 'last_price' 0)
    if ($last -le 0) { continue }
    # Crossing price for an extended-session limit: just under the bid, or 2% under last.
    $bid = To-Num (Get-Prop $quote 'bid_price' 0)
    $reference = Get-CrossingPrice -Bid $bid -Last $last

    $rec = Get-Prop $stops $pos.symbol $null
    if (-not $rec) {
        Write-Log "no stop record for $($pos.symbol); seeding at -7% from cost" $runDir 'WARN'
        $rec = Add-Stop -Symbol $pos.symbol -Entry $pos.avgCost -Stop ($pos.avgCost * 0.93) -Atr 0 -OpenedDate ((Get-EtNow).ToString('yyyy-MM-dd')) -Pivot $pos.avgCost
        $stops = Get-Stops
    }

    $upd = Get-TrailedStop -StopRec $rec -Last $last -Config $c
    $rec.stop = $upd.stop
    $rec.highestClose = $upd.highestClose
    $rec.breakeven = $upd.breakeven
    $rec.lastUpdate = (Get-Date -Format 's')

    $holdDays = Get-HoldDays -OpenedDate $rec.openedDate -CurrentDateInt $today
    $reason = $null
    if ($flatten) { $reason = 'R11 flatten' }
    elseif ($last -le (To-Num $rec.stop)) { $reason = ('stop {0:N2} breached at {1:N2}' -f (To-Num $rec.stop), $last) }
    elseif ($holdDays -ge $c.strategy.max_hold_days) { $reason = ('time stop {0}d' -f $holdDays) }

    if ($reason) {
        $exits.Add([pscustomobject]@{ symbol = $pos.symbol; qty = $pos.qty; last = $last; reference = $reference; reason = $reason })
    }
    else {
        # J Law: trim a third once the position is 3 ATR above entry, one time only.
        $atr = To-Num (Get-Prop $rec 'atr' 0)
        $trimmed = [bool](Get-Prop $rec 'trimmed' $false)
        if (-not $flatten -and -not $trimmed) {
            $trim = Get-TrimOrder -Entry $pos.avgCost -Last $last -Atr $atr -Qty $pos.qty -Config $c
            if ($trim) {
                $trims.Add([pscustomobject]@{
                        symbol    = $pos.symbol; qty = $trim.qty; last = $last
                        reference = $reference
                        reason    = ('trim extended {0:P1} from entry ({1:N2} >= {2:N2} = entry + {3}xATR)' -f (($last / $pos.avgCost) - 1), $last, $trim.extendedAt, $trim.atrMult)
                    })
            }
        }
        Write-Log ("hold {0} qty={1} last={2:N2} stop={3:N2} be={4}" -f $pos.symbol, $pos.qty, $last, $rec.stop, $rec.breakeven) $runDir
    }
}

# Persist trailing updates before acting, so a crash never loses a raised stop.
$props = @{}
foreach ($p in $stops.PSObject.Properties) { $props[$p.Name] = $p.Value }
Save-Stops ([pscustomobject]$props)

foreach ($x in $exits) {
    if ($workingSells.ContainsKey($x.symbol)) {
        Write-Log ("EXIT HELD {0}: a sell is already working ({1})" -f $x.symbol, $x.reason) $runDir
        continue
    }
    $how = if ($extended) { ('limit {0:N2} EXTENDED' -f $x.reference) } else { 'market' }
    if ($DryRun) {
        Write-Log ("DRYRUN exit {0} qty={1} {2} ({3})" -f $x.symbol, $x.qty, $how, $x.reason) $runDir
        continue
    }
    try {
        $resp = Invoke-Moomoo -Arguments (Get-SellOrderArgs -Symbol $x.symbol -Qty $x.qty -Reference $x.reference `
                -Text ('exit: ' + $x.reason) -Account $acc -Market $mkt -Extended:$extended) -RunDir $runDir
        Save-Raw $resp $runDir ("exit-" + ($x.symbol -replace '\.', '_'))
        $px = if ($extended) { [math]::Round($x.reference, 2) } else { 'market' }
        Add-Jsonl -Object ([pscustomobject]@{
                ts = (Get-Date -Format 's'); symbol = $x.symbol; side = 'sell'; qty = $x.qty
                price = $px; orderType = $how; reason = $x.reason; orderId = (Get-Prop $resp 'order_id' $null); submitted = $true
            }) -Path (Get-Path 'journal\orders.jsonl')
        Write-Log ("EXIT {0} qty={1} {2} orderId={3} ({4})" -f $x.symbol, $x.qty, $how, (Get-Prop $resp 'order_id' ''), $x.reason) $runDir
    }
    catch {
        $msg = $_.Exception.Message
        Write-Log ("EXIT FAILED {0}: {1}" -f $x.symbol, $msg) $runDir 'ERROR'
        Add-Jsonl -Object ([pscustomobject]@{
                ts = (Get-Date -Format 's'); symbol = $x.symbol; side = 'sell'; qty = $x.qty
                price = $(if ($extended) { [math]::Round($x.reference, 2) } else { 'market' })
                orderType = $how; reason = $x.reason; orderId = $null; submitted = $false; error = $msg
            }) -Path (Get-Path 'journal\orders.jsonl')
    }
}

foreach ($t in $trims) {
    if ($workingSells.ContainsKey($t.symbol)) {
        Write-Log ("TRIM HELD {0}: a sell is already working" -f $t.symbol) $runDir
        continue
    }
    $how = if ($extended) { ('limit {0:N2} EXTENDED' -f $t.reference) } else { 'market' }
    if ($DryRun) {
        Write-Log ("DRYRUN trim {0} qty={1} {2} ({3})" -f $t.symbol, $t.qty, $how, $t.reason) $runDir
        continue
    }
    try {
        $resp = Invoke-Moomoo -Arguments (Get-SellOrderArgs -Symbol $t.symbol -Qty $t.qty -Reference $t.reference `
                -Text 'trim: extended' -Account $acc -Market $mkt -Extended:$extended) -RunDir $runDir
        Save-Raw $resp $runDir ("trim-" + ($t.symbol -replace '\.', '_'))
        $px = if ($extended) { [math]::Round($t.reference, 2) } else { 'market' }
        Add-Jsonl -Object ([pscustomobject]@{
                ts = (Get-Date -Format 's'); symbol = $t.symbol; side = 'sell'; qty = $t.qty
                price = $px; orderType = $how; reason = $t.reason; orderId = (Get-Prop $resp 'order_id' $null); submitted = $true
            }) -Path (Get-Path 'journal\orders.jsonl')
        $fresh = Get-Stops
        if ($fresh.PSObject.Properties[$t.symbol]) {
            $fresh.$t.symbol | Add-Member -NotePropertyName trimmed -NotePropertyValue $true -Force
            $trimProps = @{}
            foreach ($p in $fresh.PSObject.Properties) { $trimProps[$p.Name] = $p.Value }
            Save-Stops ([pscustomobject]$trimProps)
        }
        Write-Log ("TRIM {0} qty={1} orderId={2} ({3})" -f $t.symbol, $t.qty, (Get-Prop $resp 'order_id' ''), $t.reason) $runDir
    }
    catch {
        $msg = $_.Exception.Message
        Write-Log ("TRIM FAILED {0}: {1}" -f $t.symbol, $msg) $runDir 'ERROR'
        Add-Jsonl -Object ([pscustomobject]@{
                ts = (Get-Date -Format 's'); symbol = $t.symbol; side = 'sell'; qty = $t.qty
                price = $(if ($extended) { [math]::Round($t.reference, 2) } else { 'market' })
                orderType = $how; reason = $t.reason; orderId = $null; submitted = $false; error = $msg
            }) -Path (Get-Path 'journal\orders.jsonl')
    }
}

Write-Output ("WATCHED={0} EXITS={1} TRIMS={2} SESSION={3} DRYRUN={4} RUNDIR={5}" -f $positions.Count, $exits.Count, $trims.Count, $session.session, [bool]$DryRun, $runDir)
