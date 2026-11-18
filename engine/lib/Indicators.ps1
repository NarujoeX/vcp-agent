# Indicators.ps1 - technical maths for the VCP engine.
# Bars are PSCustomObjects: date(int yyyymmdd), open, high, low, close, volume (doubles).

function Get-SmaSeries {
    param([double[]]$Values, [int]$Period = 20)
    $n = $Values.Count
    $out = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) { $out[$i] = [double]::NaN }
    if ($n -lt $Period) { return $out }
    $sum = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $sum += $Values[$i]
        if ($i -ge $Period) { $sum -= $Values[$i - $Period] }
        if ($i -ge $Period - 1) { $out[$i] = $sum / $Period }
    }
    $out
}

function Get-Sma {
    param([double[]]$Values, [int]$Period = 20)
    $s = Get-SmaSeries -Values $Values -Period $Period
    if ($s.Count -eq 0) { return $null }
    $v = $s[$s.Count - 1]
    if ([double]::IsNaN($v)) { return $null }
    $v
}

function Get-Rsi {
    param([double[]]$Closes, [int]$Period = 14)
    $n = $Closes.Count
    if ($n -lt $Period + 1) { return $null }
    $gain = 0.0; $loss = 0.0
    for ($i = 1; $i -le $Period; $i++) {
        $d = $Closes[$i] - $Closes[$i - 1]
        if ($d -ge 0) { $gain += $d } else { $loss -= $d }
    }
    $avgGain = $gain / $Period
    $avgLoss = $loss / $Period
    for ($i = $Period + 1; $i -lt $n; $i++) {
        $d = $Closes[$i] - $Closes[$i - 1]
        $g = if ($d -gt 0) { $d } else { 0 }
        $l = if ($d -lt 0) { -$d } else { 0 }
        $avgGain = (($avgGain * ($Period - 1)) + $g) / $Period
        $avgLoss = (($avgLoss * ($Period - 1)) + $l) / $Period
    }
    if ($avgLoss -eq 0) { return 100.0 }
    $rs = $avgGain / $avgLoss
    100.0 - (100.0 / (1.0 + $rs))
}

function Get-Atr {
    param($Bars, [int]$Period = 14)
    $n = $Bars.Count
    if ($n -lt $Period + 1) { return $null }
    $trs = New-Object 'double[]' $n
    $trs[0] = $Bars[0].high - $Bars[0].low
    for ($i = 1; $i -lt $n; $i++) {
        $hl = $Bars[$i].high - $Bars[$i].low
        $hc = [math]::Abs($Bars[$i].high - $Bars[$i - 1].close)
        $lc = [math]::Abs($Bars[$i].low - $Bars[$i - 1].close)
        $trs[$i] = [math]::Max($hl, [math]::Max($hc, $lc))
    }
    $atr = 0.0
    for ($i = 1; $i -le $Period; $i++) { $atr += $trs[$i] }
    $atr = $atr / $Period
    for ($i = $Period + 1; $i -lt $n; $i++) {
        $atr = (($atr * ($Period - 1)) + $trs[$i]) / $Period
    }
    $atr
}

# Average daily dollar turnover over the last Period sessions. J Law liquidity floor.
function Get-DollarVolume {
    param($Bars, [int]$Period = 20)
    $n = $Bars.Count
    if ($n -lt 1) { return 0.0 }
    $take = [math]::Min($Period, $n)
    $start = $n - $take
    $sum = 0.0
    for ($i = $start; $i -lt $n; $i++) { $sum += ([double]$Bars[$i].close * [double]$Bars[$i].volume) }
    $sum / $take
}

# High of the last completed calendar week. Used as the weekly-level edge.
function Get-PriorWeekHigh {
    param($Bars)
    $n = $Bars.Count
    if ($n -lt 10) { return 0.0 }
    $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
    $weekOf = {
        param([int]$d)
        $dt = [datetime]::ParseExact([string]$d, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
        $cal.GetWeekOfYear($dt, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [System.DayOfWeek]::Monday)
    }
    $curWeek = & $weekOf $Bars[$n - 1].date
    $i = $n - 1
    while ($i -ge 0 -and (& $weekOf $Bars[$i].date) -eq $curWeek) { $i-- }
    if ($i -lt 0) { return 0.0 }
    $prevWeek = & $weekOf $Bars[$i].date
    $hi = 0.0
    while ($i -ge 0 -and (& $weekOf $Bars[$i].date) -eq $prevWeek) {
        if ([double]$Bars[$i].high -gt $hi) { $hi = [double]$Bars[$i].high }
        $i--
    }
    $hi
}

# How many of the Look sessions ending at the pivot traded >= Mult x the 50-day average.
# J Law wants the move into the base on 2-3 heavy days, not a single spike.
function Get-HeavyVolumeDays {
    # Counts sessions on >= Mult x vol50 in the Look sessions ending at $EndIdx. For the J Law
    # layer this index is the start of the base (the first high of the contraction sequence),
    # so the window measures the advance into the base. Fails closed on a short window.
    param($Bars, [int]$EndIdx, [double]$Vol50, [double]$Mult = 1.5, [int]$Look = 10)
    if ($Vol50 -le 0 -or $EndIdx -lt 0) { return 0 }
    $n = $Bars.Count
    if ($EndIdx -ge $n) { $EndIdx = $n - 1 }
    if ($EndIdx + 1 -lt $Look) { return 0 }
    $start = $EndIdx - $Look + 1
    $count = 0
    for ($i = $start; $i -le $EndIdx; $i++) {
        if ([double]$Bars[$i].volume -ge ($Mult * $Vol50)) { $count++ }
    }
    $count
}

# Multiple-edge zone: supports that overlap the pivot within +/- BandPct.
# Types: old resistance (pivot or last two swing highs), the 10/20-day average as one
# zone, the 50-day average, the prior week's high, the 52-week high, all in one band.
function Get-EdgeZone {
    param($Bars, [double]$Pivot, [double]$BandPct = 0.02, [double]$High52 = 0, [double]$SwingThresholdPct = 0.03)
    if ($Pivot -le 0) { return $null }
    $closes = [double[]]@($Bars | ForEach-Object { [double]$_.close })
    $ma10 = Get-Sma -Values $closes -Period 10
    $ma20 = Get-Sma -Values $closes -Period 20
    $ma50 = Get-Sma -Values $closes -Period 50

    $cands = New-Object System.Collections.Generic.List[object]

    $resPrice = $Pivot
    $piv = @(Find-Swings -Bars $Bars -ThresholdPct $SwingThresholdPct)
    $hs = @($piv | Where-Object { $_.type -eq 'H' } | Select-Object -Last 2)
    foreach ($h in $hs) {
        $hp = [double]$h.price
        if ([math]::Abs($hp - $Pivot) -lt [math]::Abs($resPrice - $Pivot)) { $resPrice = $hp }
    }
    $cands.Add([pscustomobject]@{ type = 'old-resistance'; price = $resPrice })

    $nearMa = 0.0
    if ($ma10 -and $ma20) { $nearMa = if ([math]::Abs($ma10 - $Pivot) -le [math]::Abs($ma20 - $Pivot)) { $ma10 } else { $ma20 } }
    elseif ($ma10) { $nearMa = $ma10 }
    elseif ($ma20) { $nearMa = $ma20 }
    if ($nearMa -gt 0) { $cands.Add([pscustomobject]@{ type = 'ma10_20'; price = $nearMa }) }

    if ($ma50) { $cands.Add([pscustomobject]@{ type = 'ma50'; price = $ma50 }) }

    $wk = Get-PriorWeekHigh -Bars $Bars
    if ($wk -gt 0) { $cands.Add([pscustomobject]@{ type = 'prior-week-high'; price = $wk }) }

    if ($High52 -gt 0) { $cands.Add([pscustomobject]@{ type = '52w-high'; price = $High52 }) }

    $inBand = New-Object System.Collections.Generic.List[object]
    foreach ($cd in $cands) {
        if (([math]::Abs($cd.price - $Pivot) / $Pivot) -le $BandPct) { $inBand.Add($cd) }
    }
    $lo = $Pivot; $hi = $Pivot
    foreach ($cd in $inBand) {
        if ($cd.price -lt $lo) { $lo = $cd.price }
        if ($cd.price -gt $hi) { $hi = $cd.price }
    }
    [pscustomobject]@{
        count    = $inBand.Count
        zoneLow  = [math]::Round($lo, 4)
        zoneHigh = [math]::Round($hi, 4)
        edges    = @($inBand | ForEach-Object { $_.type })
        prices   = @($inBand | ForEach-Object { [math]::Round($_.price, 2) })
    }
}

# Stop 4% under the confluence zone, clamped into the R8 6-10% band.
function Get-ZoneStop {
    param([double]$Entry, [double]$ZoneLow, [double]$BelowPct = 0.04, [double]$MinPct = 0.06, [double]$MaxPct = 0.10)
    if ($Entry -le 0) { return 0.0 }
    $z = if ($ZoneLow -gt 0) { $ZoneLow } else { $Entry }
    $raw = $z * (1 - $BelowPct)
    [math]::Round([math]::Max($Entry * (1 - $MaxPct), [math]::Min($Entry * (1 - $MinPct), $raw)), 4)
}

# Index regime: a correction is close below a falling 50-day average. No new buys there.
function Get-MarketRegime {
    param($Bars, [int]$SmaPeriod = 50, [int]$SlopeLook = 5, [string]$Symbol = 'US.SPY')
    if (-not $Bars -or $Bars.Count -lt ($SmaPeriod + $SlopeLook + 1)) {
        return [pscustomobject]@{ ok = $false; symbol = $Symbol; bearish = $false; reason = 'insufficient benchmark history' }
    }
    $closes = [double[]]@($Bars | ForEach-Object { [double]$_.close })
    $series = Get-SmaSeries -Values $closes -Period $SmaPeriod
    $n = $closes.Count
    $sma = $series[$n - 1]
    $prev = $series[$n - 1 - $SlopeLook]
    $close = $closes[$n - 1]
    $falling = ($sma -lt $prev)
    [pscustomobject]@{
        ok        = $true
        symbol    = $Symbol
        asOf      = $Bars[$n - 1].date
        close     = [math]::Round($close, 2)
        sma       = [math]::Round($sma, 2)
        smaPeriod = $SmaPeriod
        falling   = $falling
        bearish   = (($close -lt $sma) -and $falling)
    }
}

# Zigzag swing detection: confirms a swing only after price reverses ThresholdPct.
# Returns alternating pivots: @{ i = barIndex; price = double; type = 'H'|'L' }
function Find-Swings {
    param($Bars, [double]$ThresholdPct = 0.03)
    $n = $Bars.Count
    if ($n -lt 5) { return @() }

    $pivots = New-Object System.Collections.Generic.List[object]
    $dir = 0
    $extIdx = 0
    $extHi = $Bars[0].high
    $extLo = $Bars[0].low

    for ($i = 1; $i -lt $n; $i++) {
        $h = $Bars[$i].high
        $l = $Bars[$i].low

        if ($dir -eq 0) {
            if ($h -gt $extHi) { $extHi = $h; $extIdx = $i }
            if ($l -lt $extLo) { $extLo = $l; $extIdx = $i }
            if (($extHi - $extLo) / $extLo -ge $ThresholdPct) {
                if ($extHi -ge $Bars[0].high) { $dir = 1; $extIdx = $i; $extHi = $h }
                else { $dir = -1; $extIdx = $i; $extLo = $l }
                $extIdx = $i
            }
            continue
        }

        if ($dir -eq 1) {
            if ($h -gt $extHi) { $extHi = $h; $extIdx = $i }
            elseif ($l -lt $extHi * (1 - $ThresholdPct)) {
                $pivots.Add([pscustomobject]@{ i = $extIdx; price = $extHi; type = 'H' })
                $dir = -1; $extIdx = $i; $extLo = $l
            }
        }
        else {
            if ($l -lt $extLo) { $extLo = $l; $extIdx = $i }
            elseif ($h -gt $extLo * (1 + $ThresholdPct)) {
                $pivots.Add([pscustomobject]@{ i = $extIdx; price = $extLo; type = 'L' })
                $dir = 1; $extIdx = $i; $extHi = $h
            }
        }
    }
    # Unconfirmed final leg is intentional: the running extreme is the evolving swing.
    $pivots
}

# Stage 2 trend template + RSI gate. Returns a hashtable of checks.
function Get-Stage2 {
    param($Bars, $Config)
    $s = $Config.strategy
    $closes = [double[]]@($Bars | ForEach-Object { [double]$_.close })
    $n = $closes.Count
    $close = $closes[$n - 1]

    $sma200 = Get-Sma -Values $closes -Period 200
    $sma50 = Get-Sma -Values $closes -Period 50
    $rsi = Get-Rsi -Closes $closes -Period $s.rsi_period
    $atr = Get-Atr -Bars $Bars -Period 14

    $look = [math]::Min(252, $n)
    $hi52 = ($Bars[($n - $look)..($n - 1)] | Measure-Object -Property high -Maximum).Maximum
    $lo52 = ($Bars[($n - $look)..($n - 1)] | Measure-Object -Property low -Minimum).Minimum

    $sma200Prev = $null
    if ($n -ge 220) {
        $prevSlice = $closes[0..($n - 21)]
        $sma200Prev = Get-Sma -Values $prevSlice -Period 200
    }

    $res = [pscustomobject]@{
        close = $close
        sma50 = $sma50
        sma200 = $sma200
        rsi = $rsi
        atr = $atr
        high52 = $hi52
        low52 = $lo52
        above200 = ($null -ne $sma200 -and $close -gt $sma200)
        sma200Rising = ($null -ne $sma200 -and $null -ne $sma200Prev -and $sma200 -gt $sma200Prev)
        maStacked = ($null -ne $sma50 -and $null -ne $sma200 -and $sma50 -gt $sma200 -and $close -gt $sma50)
        offLow = ($null -ne $lo52 -and $lo52 -gt 0 -and $close -ge 1.25 * $lo52)
        nearHigh = ($hi52 -gt 0 -and $close -ge 0.75 * $hi52)
        rsiOk = ($null -ne $rsi -and $rsi -gt $s.rsi_min)
        vol50 = (Get-Sma -Values ([double[]]@($Bars | ForEach-Object { [double]$_.volume })) -Period 50)
    }
    $res | Add-Member -NotePropertyName pass -NotePropertyValue ($res.above200 -and $res.sma200Rising -and $res.maStacked -and $res.offLow -and $res.nearHigh -and $res.rsiOk)
    $res
}

# VCP base detection.
# Returns $null, or:
#   state = 'breakout' | 'setup'
#   pivot, pivotIdx, baseStartIdx, contractions[], depth[], volRatios[], baseStart, score, distPct
function Get-Vcp {
    param($Bars, $Config, [double]$Vol50 = 0)
    $s = $Config.strategy
    $n = $Bars.Count
    if ($n -lt 80) { return $null }

    $pivots = @(Find-Swings -Bars $Bars -ThresholdPct $s.swing_threshold_pct)
    if ($pivots.Count -lt 4) { return $null }

    $baseStart = [math]::Max(0, $n - $s.base_lookback)
    $inBase = @($pivots | Where-Object { $_.i -ge $baseStart })
    if ($inBase.Count -lt 4) { return $null }

    # Walk the pivot sequence and extract high->low pullbacks.
    $pullbacks = New-Object System.Collections.Generic.List[object]
    for ($k = 0; $k -lt $inBase.Count - 1; $k++) {
        if ($inBase[$k].type -eq 'H' -and $inBase[$k + 1].type -eq 'L') {
            $h = $inBase[$k]; $l = $inBase[$k + 1]
            $depth = ($h.price - $l.price) / $h.price
            if ($depth -lt $s.min_contraction_pct) { continue }
            $nextH = $null
            if ($k + 2 -lt $inBase.Count -and $inBase[$k + 2].type -eq 'H') { $nextH = $inBase[$k + 2] }
            $endIdx = if ($nextH) { $nextH.i } else { $n - 1 }
            $volSlice = @($Bars[($h.i)..$endIdx] | ForEach-Object { [double]$_.volume })
            $avgVol = if ($volSlice.Count) { ($volSlice | Measure-Object -Average).Average } else { 0 }
            $pullbacks.Add([pscustomobject]@{ high = $h.price; low = $l.price; hiIdx = $h.i; loIdx = $l.i; depth = $depth; avgVol = $avgVol })
        }
    }
    if ($pullbacks.Count -lt $s.min_contractions) { return $null }

    # Take the last N contractions, require monotonic decay.
    $consider = @($pullbacks | Select-Object -Last 4)
    $best = $null
    for ($take = $s.max_contractions; $take -ge $s.min_contractions; $take--) {
        if ($consider.Count -lt $take) { continue }
        $seq = @($consider | Select-Object -Last $take)
        $decaying = $true
        for ($j = 1; $j -lt $seq.Count; $j++) {
            if ($seq[$j].depth -ge $seq[$j - 1].depth) { $decaying = $false; break }
        }
        $lastVolRatio = if ($Vol50 -gt 0) { $seq[$seq.Count - 1].avgVol / $Vol50 } else { 0 }
        $volDecay = $true
        for ($j = 1; $j -lt $seq.Count; $j++) {
            if ($seq[$j].avgVol -ge $seq[$j - 1].avgVol) { $volDecay = $false; break }
        }
        if (-not $decaying) { continue }
        # Volume must dry up in the final contraction: below the 50-day average.
        if ($Vol50 -gt 0 -and $lastVolRatio -ge $s.volume_dryup_ratio) { continue }
        if ($seq[$seq.Count - 1].depth -gt 0.12) { continue }
        if ($seq[$seq.Count - 1].depth -gt $s.contraction_decay_min * $seq[0].depth) { continue }
        $best = [pscustomobject]@{ seq = $seq; volDecay = $volDecay; lastVolRatio = $lastVolRatio }
        break
    }
    if (-not $best) { return $null }

    # Pivot = high of the base = highest high of the base, excluding the last (possibly breakout) bar.
    $baseBars = @($Bars[$baseStart..($n - 2)])
    if ($baseBars.Count -lt 5) { return $null }
    $pivot = 0.0
    $pivotIdx = $baseStart
    for ($q = $baseStart; $q -le ($n - 2); $q++) {
        if (([double]$Bars[$q].high) -gt $pivot) { $pivot = [double]$Bars[$q].high; $pivotIdx = $q }
    }

    $lastClose = [double]$Bars[$n - 1].close
    $lastVol = [double]$Bars[$n - 1].volume
    $distPct = ($lastClose - $pivot) / $pivot

    $state = 'none'
    if ($distPct -gt 0 -and $distPct -le $s.max_extension_pct) { $state = 'breakout' }
    elseif ($distPct -lt 0 -and $distPct -ge -0.12) { $state = 'setup' }
    else { return $null }

    $triggerVol = $Vol50 * $s.breakout_volume_mult
    # Breakout volume is measured against the recent 20-session average (excluding the
    # trigger bar), not the 50-day average: after a dry-up the 50-day average still contains
    # the pre-base volume, which made the 1.5x bar almost unreachable.
    $vol20 = 0.0
    if ($n -ge 22) {
        $v20 = @($Bars[($n - 21)..($n - 2)] | ForEach-Object { [double]$_.volume })
        $vol20 = ($v20 | Measure-Object -Average).Average
    }
    if ($vol20 -le 0) { $vol20 = $Vol50 }
    $triggerVol = $vol20 * $s.breakout_volume_mult
    $volumeOk = ($vol20 -gt 0 -and $lastVol -ge $triggerVol)

    # --- conviction score -------------------------------------------------
    $firstDepth = $best.seq[0].depth
    $lastDepth = $best.seq[$best.seq.Count - 1].depth
    $tighten = [math]::Min(1.0, [math]::Max(0.0, 1.0 - ($lastDepth / [math]::Max($firstDepth, 0.0001))))
    # Dry-up: a final contraction at half the 50-day average volume scores 1.0.
    $dryUp = [math]::Min(1.0, [math]::Max(0.0, (1.0 - $best.lastVolRatio) / 0.5))
    $hi52 = ($Bars[([math]::Max(0, $n - 252))..($n - 1)] | Measure-Object -Property high -Maximum).Maximum
    $nearHigh = [math]::Min(1.0, [math]::Max(0.0, 1.0 - (($hi52 - $lastClose) / [math]::Max($hi52, 0.0001)) * 4))
    $volDecayScore = if ($best.volDecay) { 1.0 } else { 0.4 }
    $countScore = switch ($best.seq.Count) { 3 { 1.0 } 2 { 0.85 } default { 0.7 } }

    $raw = (0.30 * $tighten) + (0.25 * $dryUp) + (0.20 * $nearHigh) + (0.15 * $volDecayScore) + (0.10 * $countScore)
    if (-not $volumeOk) { $raw = $raw * 0.85 }

    [pscustomobject]@{
        state = $state
        pivot = [math]::Round($pivot, 4)
        pivotIdx = $pivotIdx
        baseStartIdx = $best.seq[0].hiIdx
        contractions = $best.seq.Count
        depths = @($best.seq | ForEach-Object { [math]::Round($_.depth, 4) })
        avgVols = @($best.seq | ForEach-Object { [math]::Round($_.avgVol, 0) })
        volDecay = $best.volDecay
        lastVolRatio = [math]::Round($best.lastVolRatio, 3)
        baseBars = ($n - 1 - $best.seq[0].hiIdx)
        close = [math]::Round($lastClose, 4)
        distPct = [math]::Round($distPct, 4)
        lastVol = $lastVol
        vol20 = [math]::Round($vol20, 0)
        triggerVol = [math]::Round($triggerVol, 0)
        volumeOk = $volumeOk
        score = [math]::Round([math]::Min(1.0, [math]::Max(0.0, $raw)), 3)
    }
}
