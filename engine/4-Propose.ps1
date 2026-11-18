# 4-Propose.ps1  (Scout core)
# Turns VCP candidates into sized, gated proposals. Deterministic:
# enrichment -> live breakout re-check -> sector weight -> sizing -> J Law layer -> R1-R15 gate.
#
#   powershell -File engine\4-Propose.ps1 [-Top 15] [-AllowBuy]
[CmdletBinding()]
param(
    [int]$Top = 15,
    [switch]$AllowBuy
)

. "$PSScriptRoot/lib/Common.ps1"
. "$PSScriptRoot/lib/Data.ps1"
. "$PSScriptRoot/lib/Indicators.ps1"
. "$PSScriptRoot/lib/Gate.ps1"

$c = Get-Config
$jlaw = (Get-Rulebook).jlaw
$runDir = New-RunDir 'propose'
$session = Get-SessionState
$state = Get-LatestPortfolioState
if (-not $state) { throw 'No portfolio state. Run 3-Reconcile.ps1 first.' }

$scan = Read-JsonFile (Get-Path 'state\candidates-latest.json')
if (-not $scan) { throw 'No candidates. Run 2-Scan-Vcp.ps1 first.' }
$market = Get-Prop $scan 'market' $null

$universe = Load-Universe
$universeSymbols = @($universe.members | ForEach-Object { $_.symbol })

# J Law fallback: from Thu 19 Nov, if fewer than 3 distinct tickers have been traded,
# plain VCP breakouts are allowed so the competition minimum is still reachable.
$traded = @(
    (Read-Jsonl (Get-Path 'journal\orders.jsonl') | Where-Object { (Get-Prop $_ 'side' '') -eq 'buy' -and (Get-Prop $_ 'submitted' $false) } | ForEach-Object { [string](Get-Prop $_ 'symbol' '') })
    ($state.positions | ForEach-Object { $_.symbol })
) | Where-Object { $_ } | Sort-Object -Unique
$tradedCount = @($traded).Count
$fallbackActive = Test-JLawFallback -TradedCount $tradedCount
if ($fallbackActive) { Write-Log ("J Law fallback active: {0} distinct ticker(s) traded, plain VCP permitted" -f $tradedCount) $runDir 'WARN' }

# Entries only during the regular session and only if the caller allows them.
$entriesAllowed = ($session.open -and $session.session -eq 'regular' -and -not (Test-NoNewEntries) -and $AllowBuy)
if (-not $session.open) { Write-Log "session=$($session.session) ($($session.reason)): no entries" $runDir }
if (Test-NoNewEntries (Get-EtNow)) { Write-Log 'inside no-new-entries window (R11)' $runDir }
if (-not $AllowBuy) { Write-Log 'entries not authorised for this run (pass -AllowBuy)' $runDir }

$breakouts = @($scan.candidates | Where-Object { $_.vcp.state -eq 'breakout' -and $_.conviction -ge $c.risk.conviction_floor })
$shortlist = @($breakouts | Sort-Object conviction -Descending | Select-Object -First $Top)
Write-Log "breakout candidates=$($breakouts.Count) shortlisted=$($shortlist.Count)" $runDir

$sized = New-Object System.Collections.Generic.List[object]
if ($shortlist.Count -gt 0) {
    $snap = Invoke-Moomoo -Arguments (@('snapshot') + @($shortlist | ForEach-Object { $_.symbol })) -RunDir $runDir
    Save-Raw $snap $runDir 'snapshot'
    $snapMap = @{}
    foreach ($s in @(Get-Prop $snap 'snapshot_list' @())) { if ($s) { $snapMap[[string]$s.code] = $s } }

    $leadingWords = @('semiconductor', 'software', 'internet', 'communication', 'information technology',
        'computer', 'media', 'electronics', 'entertainment', 'artificial intelligence', 'data')

    foreach ($cand in $shortlist) {
        $q = $null
        if ($snapMap.ContainsKey($cand.symbol)) { $q = $snapMap[$cand.symbol] }
        if (-not $q) { Write-Log "no snapshot for $($cand.symbol)" $runDir 'WARN'; continue }

        $last = To-Num (Get-Prop $q 'last_price' 0)
        $ask = To-Num (Get-Prop $q 'ask_price' 0)
        $bid = To-Num (Get-Prop $q 'bid_price' 0)
        $volRatio = To-Num (Get-Prop $q 'volume_ratio' 0)
        $mc = To-Num (Get-Prop $q 'total_market_val' 0)
        $pivot = To-Num $cand.vcp.pivot

        if ($last -le 0 -or $pivot -le 0) { continue }
        if ($last -lt $pivot) { Write-Log ("  {0} dropped: live {1:N2} below pivot {2:N2}" -f $cand.symbol, $last, $pivot) $runDir; continue }
        if ($last -gt $pivot * (1 + $c.strategy.max_extension_pct)) {
            Write-Log ("  {0} dropped: {1:P1} above pivot (chasing)" -f $cand.symbol, ($last / $pivot - 1)) $runDir; continue
        }
        if ($volRatio -lt 1.0) { Write-Log ("  {0} dropped: volume ratio {1:N2} below average" -f $cand.symbol, $volRatio) $runDir; continue }

        # J Law multiple-edge gate. Plain VCP only when the Thu fallback is live.
        $jlawMode = 'multiple-edge'
        if ($jlaw.enabled) {
            if (-not (Get-Prop $cand 'jlawPass' $false)) {
                if ($fallbackActive) {
                    $jlawMode = 'fallback-vcp'
                    Write-Log ("  {0} J Law not met; fallback VCP allowed ({1}/{2} tickers traded)" -f $cand.symbol, $tradedCount, $jlaw.min_distinct_tickers) $runDir 'WARN'
                }
                else {
                    Write-Log ("  {0} dropped: J Law not met (edges={1} heavyDays={2} dv={3:N0}M rs63={4:P2})" -f `
                            $cand.symbol, (Get-Prop $cand 'edges' 0), (Get-Prop $cand 'heavyVolDays' 0), ((To-Num (Get-Prop $cand 'dollarVolume' 0)) / 1e6), (To-Num (Get-Prop $cand 'rs63' 0))) $runDir
                    continue
                }
            }
        }
        else { $jlawMode = 'vcp-only' }

        # Sector weight: industry plate from the broker, leading sectors first.
        $sector = ''
        $leading = $false
        try {
            $plates = Invoke-Moomoo -Arguments @('plate', $cand.symbol, '--view', 'owner') -RunDir $runDir
            foreach ($pl in @(Get-Prop $plates 'sectors' @())) {
                if ((Get-Prop $pl 'plate_type' '') -eq 'INDUSTRY') { $sector = [string](Get-Prop $pl 'plate_name' ''); break }
            }
            if ($sector) {
                $low = $sector.ToLowerInvariant()
                foreach ($w in $leadingWords) { if ($low.Contains($w)) { $leading = $true; break } }
            }
        }
        catch { Write-Log "  sector lookup failed for $($cand.symbol)" $runDir 'WARN' }

        $rankScore = [math]::Round($cand.conviction + $(if ($leading) { 0.05 } else { 0 }), 3)

        $entry = [math]::Round([math]::Min($pivot, $(if ($ask -gt 0) { [math]::Max($ask, $pivot) } else { $pivot })), 2)
        # Stop 4% under the confluence zone (J Law), clipped into R8's 6-10% band.
        $zoneLow = To-Num (Get-Prop $cand 'edgeZoneLow' 0)
        if ($zoneLow -le 0) { $zoneLow = $pivot }
        $stop = Get-ZoneStop -Entry $entry -ZoneLow $zoneLow -BelowPct $jlaw.stop_below_edge_pct `
            -MinPct $c.risk.stop_min_pct -MaxPct $c.risk.stop_max_pct
        $qty = Get-StarterQty -Equity (To-Num $state.equity) -Price $entry -Config $c

        $sized.Add([pscustomobject]@{
                symbol     = $cand.symbol
                name       = $cand.name
                sector     = $sector
                leading    = $leading
                conviction = $cand.conviction
                rankScore  = $rankScore
                pivot      = $pivot
                entry      = $entry
                stop       = $stop
                qty        = $qty
                atr        = $cand.atr
                marketCap  = $mc
                last       = $last
                bid        = $bid
                ask        = $ask
                volRatio   = $volRatio
                depths     = $cand.vcp.depths
                volDryRatio = $cand.vcp.lastVolRatio
                rsScore    = $cand.rsScore
                rs63       = (Get-Prop $cand 'rs63' 0)
                dollarVolume = (Get-Prop $cand 'dollarVolume' 0)
                edges      = (Get-Prop $cand 'edges' 0)
                edgeList   = (Get-Prop $cand 'edgeList' @())
                edgeZoneLow = [math]::Round($zoneLow, 4)
                heavyVolDays = (Get-Prop $cand 'heavyVolDays' 0)
                catalyst   = (Get-Prop $cand 'catalyst' $null)
                jlawMode   = $jlawMode
            })
    }
}

$sizedSorted = @($sized | Sort-Object -Property @{ Expression = 'rankScore'; Descending = $true })

# Gate in priority order; R5 counts new names cumulatively inside this batch.
$verdicts = New-Object System.Collections.Generic.List[object]
$newThisCycle = 0
foreach ($s in $sizedSorted) {
    $alreadyHeld = @($state.positions | Where-Object { $_.symbol -eq $s.symbol }).Count -gt 0
    $proposal = [pscustomobject]@{
        decisionId = ((Get-Date -Format 'yyyyMMddHHmmss') + '-' + ($s.symbol -replace '\.', ''))
        symbol     = $s.symbol
        side       = 'buy'
        qty        = $s.qty
        price      = $s.entry
        pivot      = $s.pivot
        stopPrice  = $s.stop
        conviction = $s.conviction
        marketCap  = $s.marketCap
        dollarVolume = $s.dollarVolume
        jlawMode   = $s.jlawMode
        edges      = $s.edges
        catalyst   = $s.catalyst
        thesis     = ('{0}: VCP {1}-contraction, depths {2}, dry-up {3}, pivot {4}, {5} edges [{6}] within +/-2%, heavy days {7}, dv {8:N0}M, rs63 {9:P1}{10}' -f `
                $s.jlawMode, (@($s.depths).Count), (($s.depths | ForEach-Object { '{0:P1}' -f $_ }) -join '/'), $s.volDryRatio, $s.pivot,
            $s.edges, (@($s.edgeList) -join '/'), $s.heavyVolDays, ($s.dollarVolume / 1e6), $s.rs63,
            $(if ($s.catalyst) { ', catalyst: ' + $s.catalyst } else { '' }))
    }
    $verdict = Test-Proposal -Proposal $proposal -State $state -Config $c -EtNow (Get-EtNow) `
        -NewThisCycle $newThisCycle -UniverseSymbols $universeSymbols -Market $market -AllowBuy:$entriesAllowed
    Add-Decision -Verdict $verdict -Proposal $proposal -Reason $(if ($verdict.approved) { 'approved within R1-R15' } else { 'rejected by rule gate' })
    if ($verdict.approved -and -not $alreadyHeld) { $newThisCycle++ }
    $verdict | Add-Member -NotePropertyName meta -NotePropertyValue $s -Force
    $verdicts.Add($verdict)
    Write-Log ("  {0,-10} {1} qty={2} @{3:N2} stop={4:N2} conv={5:N2} sector='{6}'" -f `
            $s.symbol, $(if ($verdict.approved) { 'APPROVE' } else { 'REJECT ' }), $s.qty, $s.entry, $s.stop, $s.conviction, $s.sector) $runDir
    if (-not $verdict.approved) {
        foreach ($vv in @($verdict.violations)) { Write-Log ("      {0}: {1}" -f $vv.rule, $vv.msg) $runDir }
    }
}

# Flatten verdict + sizing into one row per candidate, so the dashboard and the
# cycle summary can read a single array.
$rows = New-Object System.Collections.Generic.List[object]
foreach ($vd in $verdicts) {
    $m = $vd.meta
    $row = [ordered]@{}
    foreach ($p in $vd.PSObject.Properties) { $row[$p.Name] = $p.Value }
    if ($m) {
        $row['name'] = $m.name; $row['sector'] = $m.sector; $row['leading'] = $m.leading
        $row['conviction'] = $m.conviction; $row['rankScore'] = $m.rankScore
        $row['entry'] = $m.entry; $row['stop'] = $m.stop; $row['atr'] = $m.atr
        $row['depths'] = $m.depths; $row['volDryRatio'] = $m.volDryRatio; $row['rsScore'] = $m.rsScore
        $row['jlawMode'] = $m.jlawMode; $row['edges'] = $m.edges; $row['edgeList'] = $m.edgeList
        $row['edgeZoneLow'] = $m.edgeZoneLow; $row['heavyVolDays'] = $m.heavyVolDays
        $row['dollarVolume'] = $m.dollarVolume; $row['rs63'] = $m.rs63; $row['catalyst'] = $m.catalyst
    }
    $rows.Add([pscustomobject]$row)
}
$ranked = $rows.ToArray()

$out = [pscustomobject]@{
    generated     = (Get-Date -Format 's')
    strategyVersion = ('v' + (Get-Rulebook).version)
    session       = $session
    entriesAllowed = $entriesAllowed
    market        = (Get-Prop $scan 'market' $null)
    jlaw          = [pscustomobject]@{ enabled = [bool]$jlaw.enabled; fallbackActive = $fallbackActive; distinctTickers = $tradedCount }
    state         = $state
    ranked        = $ranked
    verdicts      = $verdicts.ToArray()
    approvedCount = @($verdicts | Where-Object { $_.approved }).Count
}
Write-JsonFile -Object $out -Path (Get-Path 'state\proposals-latest.json')
Write-JsonFile -Object $out -Path (Join-Path $runDir 'proposals.json')

Write-Output ("RANKED={0} APPROVED={1} ENTRIES_ALLOWED={2} RUNDIR={3}" -f $ranked.Count, $out.approvedCount, $entriesAllowed, $runDir)
