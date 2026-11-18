# VCP Swing Strategy — v1.8

Status: **ACTIVE** for the Moomoo x Qoder AI Paper Trading Agent Challenge (17–27 Nov 2026).
Owner: Joe Lee. Implemented by: `engine/` (deterministic) + Qoder Scout/Guard agents.
Version history: see `strategy/CHANGELOG.md`. Every rule change bumps the version and is
recorded there before code changes land.

## 1. Thesis

Trade Mark Minervini's Volatility Contraction Pattern (VCP) long-only, in Stage 2
uptrends, weighted toward leading sectors. The edge is not "momentum" — it is the
sequence of shrinking pullbacks on drying volume that precedes a supply-exhausted
breakout. A pattern without a dated, verified reading is not a signal.

Post-midterm-election years have historically been a strong window for US equities
(midterms 3 Nov 2026). That is context for sizing aggression, never an entry trigger.

## 2. Universe

1. US-listed common stock or ETF, price ≥ US$1.00, market cap ≥ US$500m, and
   20-session average dollar volume ≥ US$100m (R15, added in v1.5).
2. Universe source: top 500 US-listed names by market cap (S&P 500 proxy), refreshed
   daily. The kickoff's "211 matches" screen = S&P 500 ∩ Stage 2 ∩ above 200DMA ∩ RSI>50;
   we reproduce the same *conditions* over a market-cap-ranked universe and log the
   resulting count each day. We do not hunt the whole market.
3. Stage 2 filter, all must hold:
   - close > SMA200, and SMA200 rising over the last 20 sessions
   - SMA50 > SMA200, close > SMA50
   - close ≥ 1.25 × 52-week low
   - close within 25% of 52-week high
   - RSI(14) > 50
4. Sector weighting: tech / AI and communication services are leading (expansion phase).
   A VCP in a leading sector scores higher than the same pattern in a lagging one.

## 3. VCP definition (the baseline)

Computed on daily bars, base lookback ≤ 65 sessions:

- **2–3 contractions.** Swing highs/lows found with a 3% zigzag. Depth of contraction
  *n* = (swing high − swing low) / swing high. Each contraction must be shallower than
  the previous one, and the last must be ≤ 55% of the first.
- **Volume dry-up.** Average volume inside each successive contraction is lower than the
  previous one, and the final contraction's average volume **must** be below the 50-day
  average. No dry-up, no trade.
- **Pivot** = the high of the base (most recent swing high inside the base).
- **Entry trigger**: close (or live price) above the pivot, volume ≥ 1.5 × the recent
  20-session average (excluding the trigger bar), and price no more than 5% above the pivot
  (no chasing).
- **Tightness**: final contraction ≤ 12% deep for a tradable base.

One verified, dated reading = one signal. Momentum alone is never a signal.

## 3A. J Law multiple-edge layer (v1.5, heavy-volume anchor and width tuned in v1.6–v1.8)

The VCP is the pattern; this layer decides which bases are worth the risk. Every field
is computed in `engine/lib/Indicators.ps1` and recorded on the scan row, so a rejection
can be audited from the journal.

1. **Heavy volume into the base.** At least 2 of the 30 sessions ending at the start of the
   base must trade ≥ 1.5× the 50-day average volume. The start of the base is the first high
   of the selected contraction sequence — the top of the advance the base is consolidating —
   so the window measures the demand that created the base, not the quiet bars inside it.
   The window includes that high bar. One spike does not qualify; the pullbacks inside the
   base must come on lighter volume (§3 dry-up). v1.6 widened the window from 3 to 10
   sessions; v1.7 moved the anchor from the pivot to the base start, because a late re-test
   of the high put the pivot inside the dry-up zone and asked the same bars to be both dry
   and heavy; v1.8 widened the window from 10 to 30 sessions once v1.7 showed the last heavy
   day typically sits 17–36 sessions behind the breakout.
2. **Multiple-edge zone.** The pivot must sit on at least two overlapping supports
   within ±2%: old resistance (the pivot or the last two swing highs), the 10/20-day
   average as a single zone, the 50-day average, the prior week's high, or the 52-week
   high. The 10/20-day averages are counted once — they are one zone, not two edges.
3. **Liquidity.** 20-session average dollar volume ≥ US$100m (R15).
4. **Relative strength.** The stock's 63-session return must beat the S&P 500's (SPY).
5. **Catalyst is optional.** A dated, verified catalyst (earnings beat, raised guidance,
   product launch) recorded by the Scout in `state/catalysts.json` adds +0.05 conviction
   and is quoted in the thesis. It never substitutes for the price/volume footprint.
6. **Stop at the zone.** The stop is 4% under the bottom of the confluence zone, clamped
   into R8's 6–10% band, so it never sits inside the zone it is meant to protect.
7. **Index regime (R13).** No new buys while SPY closes below a falling 50-day average.
8. **Opening blackout (R14).** No new buys in the first 15 minutes of the regular session.
9. **Trim when extended.** Sell one third once price is 3 ATR above entry, once per
   position; the remainder keeps the 2 ATR trail.
10. **Fallback.** From Thu 19 Nov 09:30 ET, if fewer than 3 distinct tickers have been
    traded, the multiple-edge filter is waived and plain VCP breakouts are allowed so the
    competition's 3-ticker minimum stays reachable. R13, R14, R15 and §6 still apply.

The trendline edge in the original J Law checklist is approximated by the prior week's
high: a rising weekly level and a drawn trendline produce the same test — does the pivot
sit on a support the market has already respected? Round-number levels are not modelled.

## 4. Entry

- Buy the breakout with a **limit order at the pivot**.
- Live entries use the broker's intraday `volume_ratio` (≥ 1.0) as the volume confirmation;
  the 1.5× daily-average test applies to the completed daily bar in the scan and the
  backtest, because a mid-session bar is never a full day of volume.
- Ladder refinement: start the limit below the ask, step up US$0.10 every 5 minutes,
  cap at the ask, stop when filled. Never chase with a market order.
- **Starter size**: 3.5% of equity (US$3,500 at US$100,000).
- Conviction score (0–1) must be ≥ 0.50.
  Conviction = 0.70 × VCP score + 0.20 × relative-strength percentile + 0.05 (+ 0.05 if a
  dated catalyst is on record), where the
  VCP score is 0.30 × tightening + 0.25 × volume dry-up + 0.20 × proximity to the 52-week
  high + 0.15 × volume decay across contractions + 0.10 × contraction count (× 0.85 if the
  trigger bar is under 1.5× average volume). The RS percentile is measured against the whole
  Stage 2 set, not against the other VCP names.
- A stop order is placed **immediately** after the fill. An alert is not a stop.

## 5. Exit

- Initial stop **6–10% below entry and below the pivot**, sent as a real resting stop
  order, never mental. With the J Law layer the stop is 4% under the confluence zone,
  clamped into that band (§3A.6).
- Stop moves to breakeven once the trade is +5%.
- Then trail at 2 × ATR(14) from the highest close since entry.
- Trim one third at entry + 3 × ATR(14), once per position (§3A.9); the remainder keeps
  the trail.
- Time stop: exit on close of day 10 if neither stop nor target hit.
- **No averaging down, ever.** Adds are only allowed to *winners* (unrealised P/L > 0
  and price above pivot) and never beyond the 35% single-stock cap.

## 6. Risk rules R1–R15 (hard, deterministic gate)

Machine-readable in `strategy/rules.json`; enforced by `engine/lib/Gate.ps1` and called from
`engine/4-Propose.ps1`. A rejected order is logged with the rule id that rejected it.

| ID | Rule |
|----|------|
| R1 | Long only. Buy entries, sell exits. No shorts. |
| R2 | No options, futures, crypto, FX. US common stock / ETF only. |
| R3 | Cash-only. Cash reserved by open buys + position cost ≤ cash balance. Never use `max_power_long` (2×). |
| R4 | Starter = 3.5% of equity ± 2%; adds only to winners. |
| R5 | Max 3 new positions per cycle. |
| R6 | Max 8 open positions. |
| R7 | Max 35% of equity in one stock (competition hard cap 40%). |
| R8 | Stop 6–10% below entry, below the pivot, and sent as a real stop order. |
| R9 | Conviction ≥ 0.50. |
| R10 | No averaging down. |
| R11 | Flatten everything before Thanksgiving (26 Nov); no new entries from 25 Nov. |
| R12 | Event blackout: no new entries in a name around a scheduled earnings print (NVDA through 18 Nov). |
| R13 | Index regime: no new buys while SPY closes below a falling 50-day average. Unknown regime fails closed. |
| R14 | Opening blackout: no new buys in the first 15 minutes of the regular session. |
| R15 | Liquidity: 20-session average dollar volume ≥ US$100m. Unknown volume fails closed. |

Competition limits also enforced: price ≥ US$1, cap ≥ US$500m, ≤ 200 executed orders
per day, ≤ 100 positions, ≥ 3 distinct tickers over the competition, no trading after
27 Nov 13:00 ET.

## 7. Session rules (SGT)

| Session | SGT | Engine |
|---|---|---|
| Pre-market | 17:00–22:30 | plan only, no entries |
| Regular | 22:30–05:00 | entries, stops, trails |
| After-hours | 05:00–09:00 | exits only |

Cycle every 15 minutes **only while the regular session is open**, skipping holidays
(26 Nov) and stopping after 27 Nov 13:00 ET. Cycles outside the window are no-ops that
exit immediately without calling the API.

## 8. Costs and execution assumptions

- Commission modelled at US$0 (moomoo US paper).
- Slippage 5 bp + 2 bp half-spread on every fill; stops fill at the stop with gap
  slippage modelled as the worse of stop and open.
- Partial fills: a limit at the pivot does not fill if the session high < pivot; this is
  modelled explicitly in the backtest.
- Financing 4.8%/yr long would apply to overnight margin; we never use margin, so it is
  zero by construction.
