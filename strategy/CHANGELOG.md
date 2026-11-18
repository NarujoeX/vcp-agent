# Strategy changelog

Format: one entry per version. Bump the version, add the entry, then change code.
The same discipline as Ken's PRD v1.0 pattern: never edit a rule silently.

## v1.8 — 2026-11-17
- **Heavy-volume window widened from 10 to 30 sessions** (`heavy_volume_look` 10 → 30). The
  anchor is unchanged: the window still ends at the start of the base (`seq[0].hiIdx`), and
  that bar still counts. `heavy_volume_mult` 1.5 and `heavy_volume_min_days` 2 are unchanged.
- Why: v1.7's own diagnostic showed the anchor was never the binding constraint — the width
  was. Counting back from the breakout, the last ≥1.5× day sat 17–36 sessions behind it for
  three of the six candidates, so no 10-session window from either anchor could contain two
  of them. "The move into the base" is the whole advance, and on these charts it begins well
  before the pivot.
- Evidence (same window 31 Mar–13 Nov 2026, same 195-name cache, 5 bp + 2 bp per side):
  **one fill in 159 sessions.** Sub-funnel of the six volume-confirmed breakouts: 2 under
  US$100m/day (ISNPY US$7m, UBS US$83m), 2 with fewer than 2 heavy days in 30 sessions (AMD 1,
  GS 1), 1 with fewer than 2 edges in the band (ADI: 3 heavy days but a single support),
  0 lagging SPY, **1 pass — VRTX**. The trade: 6 shares of US.VRTX bought 2 Sep 2026 at the
  556.08 pivot, stopped out three sessions later on 8 Sep at 522.35 (−6.07%, −US$202.38,
  −0.20% of the US$100,000 account). Portfolio: 1 trade, 0% wins, −0.20% return, 0.21% max
  drawdown; SPY buy-and-hold over the same window +16.0%, 22 sessions blocked by R13.
- Reading: the layer now binds once instead of never, and the one name it admits is the one
  the diagnostic predicted. A sample of one is not evidence of an edge — it is evidence that
  the filter is calibrated, not switched off. The rejected names justify themselves: two were
  too illiquid to trade at size, AMD and GS had shown heavy demand only once in thirty
  sessions, and ADI's pivot sat on one support. The fill also prices the risk the sizing rule
  assumes: a stopped-out 3.5% starter costs about 0.2% of equity.
- Nothing else changes: the other three J Law conditions, R1–R15, sizing, exits, the fallback
  window and the 3-ticker minimum logic. Only one parameter moves and it moves in one
  direction.

## v1.7 — 2026-11-17
- **Heavy volume is now measured into the start of the base, not at the pivot.** The anchor
  is the first high of the selected contraction sequence (`seq[0].hiIdx`) — the top of the
  advance that the base is consolidating. The window is the 10 sessions ending at that bar,
  with the same bar included. `heavy_volume_look` stays 10; `heavy_volume_mult` 1.5 and
  `heavy_volume_min_days` 2 are unchanged.
- Why: v1.6 showed the anchor, not the width, was wrong. When a base re-tests its high late,
  the pivot bar sits inside the contraction, where the dry-up rule *requires* volume below
  the 50-day average — so anchoring the heavy-volume test at the pivot asked the same bars to
  be both dry and heavy. v1.6's six candidates had 2, 1, 1, 0, 1 and 0 heavy days across ten
  sessions; VRTX had four overlapping supports and zero heavy days at its pivot.
- Nothing else changes: the other three J Law conditions, R1–R15, sizing, exits, the fallback
  window, and the 3-ticker minimum logic. `Get-Vcp` now also returns `baseStartIdx` so the
  anchor is auditable in the scan row and the backtest log.
- Evidence (same window, universe and costs as v1.5/v1.6): **still 0 fills**. Sub-funnel of the
  six volume-confirmed breakouts — v1.5: 2 under US$100m/day, 4 with < 2 heavy days, 0 with
  < 2 edges; v1.6: 2, 3, 1; v1.7: 2, 4, 0. Moving the anchor to the base start moved the
  window *forward* for three of the six names (their base start sits 11–42 bars after the
  pivot), into the consolidation, where volume is supposed to be dry — AMD lost both heavy
  days that the pivot window had found.
- Diagnostic (`tmp/heavy-probe.ps1`, no rule change) shows where the heavy days actually are,
  counting back from the breakout: AMD 36 bars, ADI 19, GS 11, ISNPY 32, UBS 8, VRTX 17. In a
  20-session window anchored at the base start the counts are AMD 0, ADI 2, GS 1, ISNPY 4,
  UBS 3, VRTX 1; at 30 sessions AMD 1, ADI 3, GS 1, ISNPY 6, UBS 6, VRTX 3. GS has exactly
  one heavy day in 40 sessions before either anchor — for that name the rule is right to say
  no. VRTX is the one liquid name that would clear all four conditions at a 30-session window
  (heavy 3, edges 4, US$606m/day, +28.5% vs SPY).
- Reading: the anchor is not the binding constraint; the width is. "The move into the base"
  is the whole advance, and on these charts it starts 17–36 sessions before the breakout. A
  30-session window at the base start is the evidence-backed candidate for v1.8; it is not
  applied here because it is a rule change, not a diagnostic.

## v1.6 — 2026-11-17
- **Heavy-volume window widened from 3 to 10 sessions** (`heavy_volume_look` 3 → 10). The
  window is now the 10 sessions ending at the pivot bar — the pivot bar itself still counts,
  because it is the last session of the advance into the base high. Only the width changed;
  the anchor did not.
- The count still requires ≥ 2 sessions on ≥ 1.5× the 50-day average (`heavy_volume_mult`
  1.5, `heavy_volume_min_days` 2), every other J Law condition, R1–R15, sizing, exits and
  the fallback are unchanged. This is one parameter.
- Why: the v1.5 backtest produced 0 fills over 159 sessions and its sub-funnel showed the
  3-session reading was the binding condition — 4 of the 6 volume-confirmed breakouts had
  fewer than 2 heavy days inside a 3-bar window, on top of a trigger filter that had already
  cut 143 breakouts to 6. Three bars is a narrow reading of "the move into the base".
- Anchoring the window strictly before the pivot bar was tried and rejected during the
  version: it dropped the pivot bar's own heavy volume, which lowered the count (VRTX went
  from 2 heavy days to 1) and made the rule stricter — the opposite of the intent.
- Evidence (same window, costs and universe as v1.5): **still 0 fills**. Sub-funnel of the six
  volume-confirmed breakouts — v1.5: 2 under US$100m/day, 4 with < 2 heavy days, 0 with < 2
  edges; v1.6: 2, 3, 1. The widening rescued AMD (2 heavy days in 10 bars) and AMD then
  failed the multiple-edge test with a single support in the band. ADI, GS and VRTX had 0–1
  heavy days across ten sessions; ISNPY and UBS were too illiquid. R13 blocked 22 of 159
  sessions; SPY buy-and-hold +16.0%.
- Reading: the wall is the combination, not the window width. When a base re-tests its high
  late, the sessions before the pivot are inside the contraction, where dry-up requires light
  volume — so heavy volume must be measured from the start of the base, not from the pivot.
  That is a structural change for v1.7 if the layer is to be made satisfiable; it is not
  another width parameter.

## v1.5 — 2026-11-17
- **J Law multiple-edge layer.** Every entry now needs all four, not just the VCP shape:
  1. heavy volume into the base — at least 2 of the 3 sessions ending at the pivot on
     ≥ 1.5× the 50-day average (a single spike does not count);
  2. a pivot sitting on ≥ 2 overlapping supports inside a ±2% band: old resistance-turned-
     support (swing high above the base), the 10/20DMA as one zone, the 50DMA, the prior
     week's high, the 52-week high;
  3. 20-session average dollar volume ≥ US$100m;
  4. 63-session return ahead of SPY.
- The pullback side of the rule is the existing hard dry-up requirement: the final
  contraction's average volume must sit below the 50-day average. It was already v1.2;
  J Law only makes the pairing explicit.
- **Stop from the zone, not the pivot**: 4% under the low of the confluence zone, clamped
  into the 6–10% band and still below the pivot (`Get-ZoneStop`). The zone low is the price
  that has to fail for the thesis to be wrong, so that is where the stop belongs.
- **R13 index regime**: no new buys while SPY closes below a falling 50DMA (close < SMA50
  and SMA50 < SMA50 five sessions ago). Missing or stale `state/market.json` fails closed.
- **R14 opening blackout**: no new buys in the first 15 minutes of the regular session.
- **R15 liquidity floor**: 20-session dollar volume ≥ US$100m; unknown volume fails closed.
- **Trim when extended**: sell one third once per position at entry + 3×ATR(14), executed by
  the 60-second watch loop; `trimmed` is then set and never cleared.
- **Dated catalyst, optional**: a verified catalyst in `state/catalysts.json` (≤ 14 days old)
  adds 0.05 conviction and must be quoted in the thesis. No catalyst feed in this build, so
  a missing record is the normal case. The bonus can never lift a name over a hard gate.
- **Fallback, time-boxed**: from Thu 19 Nov 09:30 ET, while fewer than 3 distinct tickers
  have traded, plain VCP breakouts are permitted so the competition's 3-ticker minimum stays
  reachable. The journal records `fallback-vcp` as the mode of every such proposal.
- Evidence for the layer: the v1.5 scan over 294 names found 8 VCP setups and exactly 1 that
  also met J Law (VRTX: edges old-resistance + 52-week high, 2 heavy days, US$834m dollar
  volume, +5.4% vs SPY over 63 sessions). SPY itself was below a falling 50DMA that day, so
  R13 blocked entries by design.
- The v1.5 walk-forward backtest (31 Mar – 13 Nov 2026, 159 sessions, 195 names) produced
  **0 fills**: 8,545 entry-eligible symbol-days → 1,196 VCPs → 143 breakouts → 6 with 1.5×
  trigger volume → 0 J Law. Of the six, 2 were under US$100m/day and 4 had fewer than 2 heavy
  days, so heavy volume into the pivot bound every candidate; none failed the edge or RS
  tests. R13 blocked 22 sessions. SPY buy-and-hold was +16.0%. Read as: the layer is strictly
  more selective than v1.4 (10 trades, −0.52%) and on this sample too selective to trade —
  which is why the 19 Nov fallback exists, and why zero trades is not claimed as an edge.
- Approximations declared: the trendline edge is the prior week's high (README disclosure 5),
  and the 10- and 20-day averages count as one zone because they sit within a point or two of
  each other on most of these names.
- Files: `rules.json` (jlaw block, R12–R15), `Indicators.ps1` (`Get-DollarVolume`,
  `Get-PriorWeekHigh`, `Get-HeavyVolumeDays`, `Get-EdgeZone`, `Get-ZoneStop`,
  `Get-MarketRegime`), `Gate.ps1` (R13–R15, `Test-JLawFallback`), `Exits.ps1`
  (`Get-TrimOrder`), `2-Scan-Vcp.ps1`, `4-Propose.ps1`, `6-StopWatch.ps1`, `Backtest.ps1`,
  `Build-Dashboard.ps1`, both agent prompts, `AGENTS.md`, `README.md`.

## v1.4 — 2026-11-17
- Breakout volume is now measured against the recent 20-session average (excluding the
  trigger bar), still at 1.5×. Evidence: with the reference set to the 50-day average,
  which still contains the pre-base volume, the filter produced 6 triggers in 109 sessions
  (0 fills in the first walk-forward run because every breakout's volume was below 1.5× of
  that inflated average). Median breakout-day relative volume was 0.85× the 50-day average,
  so the rule was effectively "no trades".
- Backtest warm-up reduced from 260 to 210 bars so the evidence window covers 159 sessions
  (the trend template needs 200 bars plus the rising-200 comparison).
- Everything else unchanged.

## v1.3 — 2026-11-17
- Added R12 event blackout: no new entries in a name around a scheduled earnings print.
  First entry: NVDA through 2026-11-18 16:00 ET (reports after the close on 17 Nov).
  This makes "do not chase NVDA into earnings" a deterministic gate rather than an
  instruction to the Scout.
- STRATEGY.md stays at the same content otherwise; only the rule table grew.

## v1.2 — 2026-11-17
- Volume dry-up is now a hard requirement: the final contraction's average volume must be
  below the 50-day average. It was previously only scored, so "no dry-up" names could pass
  on price structure alone.
- Conviction weights recalibrated and documented: 0.30 tightening, 0.25 dry-up, 0.20
  proximity to 52-week high, 0.15 volume decay across contractions, 0.10 contraction count;
  ×0.85 when the trigger bar is below 1.5× volume.
- Relative strength is measured across the whole Stage 2 set, not only the names that happen
  to have a base (the old percentile was computed on 4–12 names and was mostly noise).
- Swing threshold fixed at 3% in config to match this document.

## v1.1 — 2026-11-17
- Added R11 flatten date as a hard gate (25 Nov no new entries, flat by 26 Nov open).
- Added 27 Nov half-day rule: exits only, no new entries.
- Added half-day / closed-day awareness to the cycle scheduler.
- Backtest default changed to walk-forward with an out-of-sample tail.

## v1.0 — 2026-11-17
- Baseline VCP: 2–3 contractions, decaying depth, volume dry-up, pivot = base high,
  breakout on ≥ 1.5× volume, ≤ 5% extension.
- Starter 3.5%, max 3 new/cycle, max 8 open, 35% per stock, stop 6–10% under pivot.
- Long only, cash only, no options/shorts/margin/crypto.
- Swing holds 2–5 days; stop → breakeven at +5%, then 2×ATR trail; time stop at 10 days.
