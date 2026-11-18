# VCP Trading Agent — Moomoo x Qoder AI Trading Agent Challenge

## Redacted submission export - offline review only

This is a separately sanitised copy, not the operative trading project or original
broker evidence. The account identifier is replaced by the non-numeric placeholder
`challenge-account`, and workstation profile paths by `C:\Users\REDACTED_USER`.
See [the redaction report](submission/REDACTION-REPORT.txt) and
[the per-file manifest](submission/redaction-manifest.json) for the exact changes.

### Safe account-binding example

[`config/config.example.json`](config/config.example.json) contains the full
configuration with `account.account_id` set to `challenge-account`. The included
`config/config.json` uses the same placeholder so root discovery and the offline tests
work. Neither file contains a usable account binding. All other values are preserved.

`engine/lib/Common.ps1` reads `account.account_id` from `config/config.json`; broker
calls use that value. `MOOMOO_EXE` selects an executable, not an account. In a
separately authorised private deployment, the account owner supplies only the
designated challenge paper-account identifier in that field, leaving the market,
account title and risk settings unchanged. Keep that private configuration outside
shared exports and never substitute another paper account or a real-money account.
This explains the binding; it is not permission to trade.

Do not activate this export, install its scheduled tasks, run its historical broker
probes or reconnect its redacted historical state. Continue using the existing
authorised operative project. A placeholder is not a sandbox: some commands can still
contact the broker or change machine state. Only the listed offline checks are review
commands.

An automated paper-trading agent for the Moomoo x Qoder AI Trading Agent Challenge
(17–27 Nov 2026). It trades the challenge paper account, `challenge-account` in this repo
(the real account number stays only in the original private config) (US, US$100,000 at the start;
US$99,998.01 after the extended-session probe in §8) long-only
in US stocks and ETFs, following a Mark Minervini-style Volatility Contraction Pattern (VCP)
breakout strategy, with every order filtered by a deterministic risk gate before it is sent.

**No real money.** No options, shorts, margin or crypto. No averaging down. Flat before
Thanksgiving.

## 1. Strategy (v1.8)

Details and the version history: [`strategy/STRATEGY.md`](strategy/STRATEGY.md),
[`strategy/rules.json`](strategy/rules.json), [`strategy/CHANGELOG.md`](strategy/CHANGELOG.md).

- **Universe** — top 300 US stocks by market capitalisation (the moomoo screen endpoint caps
  a page at 300 names; this is a practical S&P 500 proxy and covers the liquid large caps).
  Cached daily bars; the only live read in the signal path is the once-a-day SPY refresh
  that feeds R13.
- **Trend template (Stage 2)** — close > 200DMA, 200DMA rising, 50DMA > 200DMA, close ≥ 1.25×
  the 52-week low, within 25% of the 52-week high, RSI(14) > 50.
- **VCP** — 3% zigzag swings inside a ≤ 65-session base; 2–3 contractions, each shallower
  than the last, the last ≤ 55% of the first and ≤ 12% deep; the final contraction's average
  volume **below** the 50-day average (volume dry-up is a hard requirement, not a score).
- **J Law multiple-edge layer (v1.5, tuned in v1.6–v1.8)** — the move into the base needs
  ≥ 2 of the 30 sessions ending at the **start of the base** on ≥ 1.5× the 50-day average
  volume (not one spike); the pivot must sit on ≥ 2
  overlapping supports within ±2% (old resistance, the 10/20DMA zone, the 50DMA, the prior
  week's high, the 52-week high); 20-session dollar volume ≥ US$100m; and the stock must beat
  SPY over 63 sessions. A dated catalyst adds 0.05 conviction but is never required.
- **Entry** — limit order at the pivot (base high) when price clears it, volume ≥ 1.5× the
  recent 20-session average, price ≤ 5% above the pivot. Ladder: step +US$0.10 per cycle,
  cap pivot × 1.05. No market orders on entry. No buys in the first 15 minutes (R14) and none
  while SPY is below a falling 50DMA (R13).
- **Conviction** — `0.70 × VCP score + 0.20 × RS percentile + 0.05 (+0.05 dated catalyst)`,
  floor **0.50**.
- **Exit** — stop 4% under the confluence zone, clamped into the 6–10% band and always below
  the pivot; breakeven at +5%; then 2×ATR(14) trailing stop; trim one third at entry + 3×ATR
  once; time stop after 10 sessions.
- **Fallback** — from Thu 19 Nov 09:30 ET, plain VCP breakouts are allowed while fewer than
  3 distinct tickers have traded, so the competition's 3-ticker minimum stays reachable.
- **Context, not signal** — leading sectors are ranked first and a post-midterm tailwind is
  noted in the thesis, but neither creates a trade. A signal requires a verified, dated
  reading.

## 2. Risk rules (hard gate, R1–R15)

Enforced in [`engine/lib/Gate.ps1`](engine/lib/Gate.ps1); the Scout cannot bypass it.

| ID | Rule |
|----|------|
| R1 | Long only — buys for entries, sells for exits, no shorts. |
| R2 | US common stock or ETF only; no options, futures, crypto, FX, warrants. |
| R3 | Cash only — cost + reserved ≤ available cash; the 2× buying power is ignored. |
| R4 | Starter = 3.5% of equity (±2%); adds only to winners. |
| R5 | At most 3 new positions per cycle. |
| R6 | At most 8 open positions (competition cap 100). |
| R7 | At most 35% of equity per name (competition hard cap 40%). |
| R8 | Stop 6–10% under entry, below the pivot, live before the next cycle. |
| R9 | Conviction ≥ 0.50. |
| R10 | **No averaging down**, ever. |
| R11 | Flat before Thanksgiving: no new entries from 25 Nov, all positions closed by 16:00 ET 25 Nov. |
| R12 | Event blackout — no new entries in a name around a scheduled earnings print (NVDA through 18 Nov). |
| R13 | Index regime — no new buys while SPY closes below a falling 50DMA; unknown regime fails closed. |
| R14 | Opening blackout — no new buys in the first 15 minutes of the regular session. |
| R15 | Liquidity — 20-session average dollar volume ≥ US$100m; unknown volume fails closed. |

Competition limits are enforced too: price ≥ US$1, market cap ≥ US$500m, ≤ 200 executed
orders/day, no trading after 13:00 ET on 27 Nov.

## 3. Architecture

```
Scout  (analysis agent)            Guard  (portfolio agent)
  thesis → scan → outlook             reconcile → execute → protect
        │                                   │
        └── state/proposals-latest.json ────┘
                     │
             R1–R15 gate (Gate.ps1)  ← deterministic, logs every rejection
                     │
              journal/decisions.jsonl   dashboard/index.html
```

| Piece | File | Job |
| --- | --- | --- |
| Scout prompt | [`.qoder/agents/scout.md`](.qoder/agents/scout.md) | Writes the thesis, ranks candidates. Never places orders. |
| Guard prompt | [`.qoder/agents/guard.md`](.qoder/agents/guard.md) | Executes approved proposals only, keeps stops real. |
| Cycle | `engine/Invoke-Cycle.ps1` | stops → reconcile → scan → propose → execute → dashboard |
| Stop watch | `engine/6-StopWatch.ps1` | 60-second loop that sends the stop (market order in RTH, crossing limit in after-hours), because the paper API has no stop order type |
| Dashboard | `engine/Build-Dashboard.ps1` | Self-contained HTML: journal, playbook, research |

The engine is plain PowerShell 5.1 (no Node, no Python, no OpenD). It talks to the official
moomoo CLI and keeps its own JSON state, so a cycle costs no model credits. Qoder agents are
used where judgement is needed (thesis, review), not for the mechanical steps.

## 4. Evidence

`engine/Backtest.ps1` replays the same rules over the cached daily bars of the top 200 names
by market cap, walk-forward with a 70/30 in-sample / out-of-sample split, and models:

- costs: 5 bp slippage + 2 bp half-spread on both sides (the paper account also charges about
  US$0.99 a ticket, so a round trip on a 3.5% starter costs ~US$2.00 — inside this model);
- **partial fills**: a limit at the pivot only fills if the session high reached it, and the
  fill is at the open when the session gapped through the pivot;
- gap-through-stop exits at the open, not at the stop price;
- cash-only sizing (3.5% starters, max 3 new/day, max 8 open);
- R13 blocks entries on days when SPY closes below a falling 50DMA; the one-third trim is
  booked as its own fill.

_(Numbers from `state/backtest-latest.json` — see §7 for the exact command.)_

Window 31 Mar – 13 Nov 2026, 159 sessions, 195 names, costs 5 bp + 2 bp per side.

**v1.5–v1.8 (J Law layer).** The funnel, unchanged until the last row:

| Stage | Symbol-days |
| --- | --- |
| Trend template passed, entries allowed | 8,545 |
| VCP formed | 1,196 |
| Breakout | 143 |
| Breakout volume ≥ 1.5× 20-session average | 6 |
| J Law — all four conditions | 1 (v1.5–v1.7: 0) |
| Fills | 1 (v1.5–v1.7: 0) |

J Law sub-funnel over the same six breakouts (first failing condition):

| Version | Anchor / width | < US$100m/day | < 2 heavy days | < 2 edges | lagging SPY | passed |
| --- | --- | --- | --- | --- | --- | --- |
| v1.5 | pivot, 3 sessions | 2 | 4 | 0 | 0 | 0 |
| v1.6 | pivot, 10 sessions | 2 | 3 | 1 | 0 | 0 |
| v1.7 | base start, 10 sessions | 2 | 4 | 0 | 0 | 0 |
| v1.8 | base start, 30 sessions | 2 | 2 | 1 | 0 | **1** |

**v1.8 fills: one.** 6 shares of VRTX, bought 2 Sep 2026 at the 556.08 pivot on 1.73m shares
(~1.55× the 20-session average), stopped out three sessions later on 8 Sep at 522.35 — the 6%
floor of the zone stop, since the confluence sat less than 6% under the pivot. −6.07% per
share, −US$202.38, −0.20% of the US$100,000 account.

| Segment | Trades | Win rate | Expectancy | Return | Max DD | Sharpe |
| --- | --- | --- | --- | --- | --- | --- |
| All | 1 | 0.0% | −US$202 | −0.20% | 0.21% | −1.60 |
| In-sample (70%) | 1 | 0.0% | −US$202 | −0.20% | 0.21% | −1.91 |
| Out-of-sample (30%) | 0 | — | — | 0.00% | 0.00% | — |

The other five still fail, and for the reasons the diagnostic predicted: ISNPY (US$7m/day)
and UBS (US$83m/day) are too thin, AMD and GS each show one heavy day in thirty, ADI has
three heavy days but a pivot sitting on a single support.

Where the heavy days actually are (bars since the last ≥1.5× day, counting back from the
breakout), with the heavy-day count in a 20- and 30-session window ending at the base start:

| Symbol | Date | $ volume | Last heavy day | Heavy / 20 | Heavy / 30 | Blocked by |
| --- | --- | --- | --- | --- | --- | --- |
| AMD | 2026-04-16 | $7,962m | 36 bars | 0 | 1 | heavy volume |
| ADI | 2026-04-17 | $1,099m | 19 bars | 2 | 3 | edges (1) |
| GS | 2026-07-14 | $2,340m | 11 bars | 1 | 1 | heavy volume |
| ISNPY | 2026-08-13 | $7m | 32 bars | 4 | 6 | liquidity |
| UBS | 2026-08-31 | $83m | 8 bars | 3 | 6 | liquidity |
| VRTX | 2026-09-02 | $606m | 17 bars | 1 | 3 | **filled** |

**v1.4 baseline (no J Law layer), same cache and window: 10 trades.**

| Segment | Trades | Win rate | Expectancy | Profit factor | Return | Max DD | Sharpe | Sortino | Avg hold |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| All | 10 | 30.0% | −US$51 | 0.66 | −0.52% | 1.94% | −0.67 | −0.46 | 7.1 d |
| In-sample (70%) | 7 | 28.6% | −US$22 | 0.85 | +0.10% | 1.26% | 0.17 | 0.12 | 7.9 d |
| Out-of-sample (30%) | 3 | 33.3% | −US$120 | 0.23 | −0.62% | 0.69% | −3.78 | −2.15 | 5.3 d |

Every loss in that run was a −7.1% stop or a gap through it; the two best trades were +16.7%
(AMD, trailing stop after a breakout) and +9.3% (ADI, time stop).

**What this shows and what it does not.** One trade is not an edge. It is the smallest
possible sample, it lost, and buy-and-hold beat it by 16.2 points over the window. What the
run does show is that the filter is calibrated rather than switched off: four versions of the
heavy-volume rule admitted one name between them, that name is the one the diagnostic
predicted, and the five rejections each have a stated reason — two too thin to trade, two
with heavy demand only once in thirty sessions, one with a single support under the pivot.

The v1.8 change itself is one parameter moving one way: 10 → 30 sessions, anchor unchanged.
The judgement behind it is in the diagnostic, not in the outcome — "the move into the base"
is the whole advance, and on these charts the last ≥1.5× day sat 17–36 sessions before the
breakout, so no ten-session window could ever contain two of them. The cost of being wrong
here is the one trade above: 0.20% of equity, which is the number the 3.5% starter rule is
sized to absorb.

The purpose of the backtest remains to validate the plumbing (partial fills, gap-through
stops, costs, cash-only sizing, trims, regime blocks) and to calibrate risk: at 3.5% starters
a stopped-out trade costs ~0.25% of equity, so eight simultaneous stops cost ~2%.

Not modelled: R14 (the first 15 minutes of the session — daily bars carry no intraday clock)
and the 60-second stop watch between checks. Both are live-only, and the gap risk between
checks is the accepted cost of the paper API having no stop-order type. Because the live plan
depends on names actually appearing, the time-boxed fallback in §1 is the escape hatch if
fewer than three tickers have traded by 19 Nov. The live journal, not this table, is the real
test — and the strategy is versioned so the next change is measured, not guessed.

## 5. Session clock (SGT, US winter time)

| Window | SGT | Engine behaviour |
| --- | --- | --- |
| Pre-market | 17:00–22:30 | scan only; entries closed |
| Regular | 22:30–05:00 (27 Nov: to 02:00) | 15-minute cycles + 60-second stop watch; no new buys 22:30–22:45 SGT (first 15 minutes, R14) |
| After-hours | 05:00–09:00 | exits only; no new entries; stop watch keeps running with crossing limits |
| Closed | weekends, 26 Nov | no-op — the session check runs first |

## 6. Run it

### Fresh-copy setup and offline verification

Copy the whole tree, including `.qoder`, `config`, `data`, `state`, `journal` and `runs`.
The local `config/config.json` is required even for root discovery; keep its account
binding unchanged. A copied project does not copy CLI installation, authentication or
Windows Scheduled Tasks. Do not activate another copy while the operative agent is running.

For connected operation, install the official Windows [Moomoo CLI](https://github.com/MoomooOpen/moomoo-cli#installation)
and complete the official browser sign-in on the machine that will run the agent.
The executable is resolved from `MOOMOO_EXE`, then the author's local installation, then
`moomoo` on `PATH`; set `MOOMOO_EXE` to the installed executable when needed.
Use `moomoo version`, `moomoo auth status --format json`, `moomoo check --format json`
and `moomoo config get api_base` to verify the installation separately. The API base must
be `https://webapi.moomoo.com`. Keep authentication output private; never copy tokens or
callback URLs into this project. The connected checks are not part of the offline test.

In a disposable copy, open a new PowerShell session at the project root and run only this
offline allowlist. The executable override intentionally points to a nonexistent file.
The process-only execution-policy flag matches the existing launcher; it does not change
persistent Windows policy and does not override an organisation's enforced policy.

```powershell
$env:MOOMOO_EXE = Join-Path $PWD 'BROKER_EXECUTION_DISABLED.exe'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tmp\test-gate.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tmp\test-fallback.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tmp\test-jlaw.ps1
.\RUN-ENGINE.cmd dashboard
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\engine\9-Schedule.ps1
```

Close that test shell afterwards. Dashboard generation overwrites only the copy's dashboard;
open it and check every tab. The no-flag scheduler command is a preview, not installation.
The J Law test includes assertions against the bundled cache, not immutable fixtures.
An absent decision journal is displayed as empty; do not manufacture decision records.

**Not offline tests:** cycles, scans, reconciliation, backtests, stop-watch passes, broker
probes and scheduler installation. A dry cycle can still call the broker and write state.
Installing the scheduler without `-Live` still enables protective sells, refresh, keep-awake
and shutdown tasks. The other scripts in `tmp` are research or execution evidence, not a
batch test suite; some bypass the executable override with hard-coded broker paths.

**Redacted package:** the copied config, portfolio/proposals and run evidence use
`challenge-account`. These are sanitised review copies, not original broker records or
an operational account binding. Original evidence and the unredacted package stay private.

### Operational commands

```cmd
RUN-ENGINE               :: dry-run cycle (writes decisions, sends nothing)
RUN-ENGINE execute       :: cycle that may send approved orders
RUN-ENGINE stops         :: one protective pass
RUN-ENGINE watch         :: stop-watch loop until close
RUN-ENGINE scan          :: rescan the universe (local, free)
RUN-ENGINE dashboard     :: rebuild dashboard\index.html
RUN-ENGINE backtest      :: walk-forward backtest
```

Unattended: `powershell -File engine\9-Schedule.ps1 -Install` registers the cycle (every
15 min), stop watch (every minute), end-of-day refresh, the keep-awake hold and the
post-refresh shutdown as Windows Scheduled Tasks; add `-Live` to let the cycle task place
orders. The script refuses to run outside US hours. The refresh and shutdown run Mon–Sat
because Friday's session ends on Saturday morning SGT.

**Keeping the machine awake.** The stop is the 60-second watch, and a sleeping machine has no
stop. `engine\8-KeepAwake.ps1 -Hold -Hours 10.75` holds the session out of idle sleep from
22:25 to about 09:10 SGT; the scheduler runs it, and it works on AC and on battery. Check the
current state with `powershell -File engine\8-KeepAwake.ps1 -Status`. A hold cannot survive a
closed lid, a Windows Update restart or an unplugged battery, so keep the laptop on mains, lid
open and vents clear for 22:25–09:10 SGT. The scheduled tasks also carry `-WakeToRun`, so a
sleep that slips through is woken for the next cycle.

Open `dashboard/index.html` in a browser: Trade Journal (every decision, including rejected
ones and the rule that rejected them), Playbook (positions, stops, distance to stop, open
orders, ranked proposals), Research (backtest, scan counts).

**Powering off after the close.** `engine\10-Shutdown.ps1 -Execute` runs as
`VCP-Agent-Shutdown` at 05:20 SGT and `VCP-Agent-Shutdown-Late` at 09:05 SGT, Mon–Sat, behind
the 05:15 end-of-day refresh. At 05:20 it powers off only when the book is flat: with a
position open the after-hours stop watch still needs the machine until 20:00 ET, so it logs
the position and leaves the shutdown to the 09:05 run. It refuses to power off when the
refresh has not run that day or finished non-zero, and it only acts between 04:00 and 12:00
SGT — a missed run replayed by Task Scheduler when the laptop is switched on for the evening
must never shut it down. `RUN-ENGINE poweroff` reports what would happen without powering
anything off.


## 7. Reproducibility

- **Deterministic**: the scan, the gate and the sizing are pure functions of cached bars +
  `config/config.json`. Re-running a cycle on the same data produces the same proposals.
- **Data**: `data/klines/US_*.json` are point-in-time daily bars, written at refresh time.
  `runs/<date>/<timestamp>-*/raw/` keeps every raw API response used in that step.
- **Journals**: `journal/decisions.jsonl` (one line per proposal, approved or rejected, with
  rule ids) and `journal/orders.jsonl` (every order and the dry-run attempts).
- **Versioned strategy**: every rule change bumps the version in `rules.json` and
  `STRATEGY.md` and adds a `CHANGELOG.md` entry. Backtest output records `strategyVersion`.
- **Backtest command**: `powershell -File engine\Backtest.ps1 -Top 200` →
  `state/backtest-latest.json`.

## 8. Disclosures and deviations

1. **No stop-order type in the moomoo paper API.** A resting stop order cannot be placed, so
   the stop is enforced by a 60-second watch loop that sells on breach: a market order in the
   regular session, and a limit priced under the bid with the `EXTENDED` session after the
   close, where the paper API rejects market orders. Both are real orders, not alerts; the gap
   risk between checks is the accepted cost. A working sell is never duplicated — the watch
   reads open orders first and holds off on a symbol that already has one.
2. **One accidental paper order on 17 Nov** (order `3265691`, AAPL, 1 share) was submitted
   while smoke-testing the CLI before the engine existed. It was cancelled 39 seconds later
   with zero shares filled (`status 5`, `cum_qty 0`), and the balance was verified back at
   exactly US$100,000.00. It predates the journal and so appears in the broker's order
   history only.
3. **Extended-session probe on 17 Nov**, run with the account holder's authorisation to prove
   the after-hours stop path before relying on it: buy 1 F at 11.58 (`3266051`, filled
   11.558), then a sell two ticks above the market at 11.59 (`3266054`) which rested unfilled
   in the `EXTENDED` book for 25 seconds and was cancelled (`status 5`, `cum_qty 0`), then
   sell 1 F at 11.55 (`3266055`, filled 11.56). Ended flat. Both filled legs cost US$1.99 in
   broker fees — about US$0.99 a ticket plus a per-share charge — so the account stands at
   US$99,998.01, not 100,000. The three fills are journalled with `probe: true`; F therefore
   counts as a traded ticker for the 3-ticker fallback, because the fill is real whatever the
   intent. Harness: `tmp/probe-extended.ps1`.
4. **Universe is 300 names, not 500**: the screen API caps one page at 300 results.
5. **Account isolation**: the engine is pinned to the `challenge-account` id in
   `config/config.json` (the real number stays local); it never reads or writes any other account.
6. **J Law trendline edge** is approximated by the prior week's high. A drawn rising
   trendline and a rising weekly level ask the same question — has the market already
   defended this price? Round-number levels are not modelled.
7. **Catalysts are manual and dated.** There is no paid news feed in this build, so the Scout
   records a verified catalyst in `state/catalysts.json`; it adds 0.05 conviction and is
   quoted in the thesis. An expired or missing record simply means no bonus.
8. **R13 fails closed.** If `state/market.json` is missing or stale, the gate refuses new
   buys rather than assuming the index is healthy.
