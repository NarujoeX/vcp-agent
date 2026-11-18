# Operating rules for any agent in this repo

This repo runs the Moomoo x Qoder AI Paper Trading Challenge entry. Read
`strategy/STRATEGY.md` and `strategy/rules.json` before touching anything.

## Non-negotiables

1. **One account:** `challenge-account` — "Moomoo x Qoder AI Paper Trading Agent Challenge", US market.
   Never another paper account. Never real money. No reset card, no revival.
2. **Long only, cash only.** US-listed stocks and ETFs. No options, shorts, margin or crypto.
   The account shows 2x buying power — ignore it. Every buy must fit in available cash.
3. **No averaging down.** Adds only to positions that are in profit, and only up to the 35%
   cap per name.
4. **Real stops.** Moomoo paper accounts have no stop-order type. The stop is the 60-second
   `6-StopWatch.ps1` loop that sells on breach — a market order in the regular session, a
   limit priced under the bid with the `EXTENDED` session outside it, because the paper API
   rejects market orders after the close. It runs until 20:00 ET, not just to the close. An
   alert is not a stop. Never remove or lower a stop record.
5. **Flatten before Thanksgiving.** All positions closed by 2026-11-25 16:00 ET. No new
   entries from 25 Nov. Do not trade 26 Nov (closed) or after 13:00 ET on 27 Nov.
6. **First live order of the competition is placed with the human watching.** Print symbol,
   qty, limit, stop and thesis; wait for explicit confirmation. Every order after that is
   logged to `journal/orders.jsonl`.
7. **Dry by default.** `5-Execute.ps1` and `Invoke-Cycle.ps1` send nothing without
   `-Execute`. `6-StopWatch.ps1` sends nothing with `-DryRun`.
8. **Never invent a trade.** Proposals come from `4-Propose.ps1` and must pass the R1–R15
   gate in `engine/lib/Gate.ps1`. Do not hand-edit approved proposals.
9. **Never edit `strategy/` in place.** Each strategy change bumps the version in
   `strategy/rules.json` and `strategy/STRATEGY.md`, with an entry in `strategy/CHANGELOG.md`.
10. **Secrets stay local.** Tokens and callback URLs never go into chat, logs, journals or
    committed files.
11. **No buys in the first 15 minutes** of the regular session (R14). The 22:29 SGT cycle
    is expected to be rejected by the gate; that is the rule working, not a bug.
12. **No buys while SPY is below a falling 50-day average** (R13). An unknown regime is a
    no-buy, never an assumption.
13. **Trim a third at entry + 3 ATR, once.** Do not trim into a stop-out, and never trim
    a loser to "make room" — that is averaging down in disguise.
14. **Catalysts are dated evidence, not permission.** Record them in
    `state/catalysts.json`; they add 0.05 conviction and are quoted in the thesis. They
    never bypass the price/volume layer or any R rule.
15. **Fallback is time-boxed.** From Thu 19 Nov 09:30 ET, plain VCP is allowed only while
    fewer than 3 distinct tickers have been traded. Once the third ticker trades, the
    multiple-edge filter is back on.

## Session clock (SGT)

| Window | SGT | What runs |
| --- | --- | --- |
| Pre-market | 17:00–22:30 | scan only, no entries |
| Regular | 22:30–05:00 (half-day to 02:00) | cycles every 15 min + 60 s stop watch |
| After-hours | 05:00–09:00 | no entries, 60 s stop watch (crossing limits) |
| Closed | weekend, 26 Nov | nothing |

The engine re-checks the ET session on every run, so a holiday or a closed market is a
no-op rather than an order.

## Entry points

- `RUN-ENGINE.cmd` — dry-run cycle. `RUN-ENGINE execute` — cycle that may trade.
- `engine/Build-Dashboard.ps1` — regenerates `dashboard/index.html` from the journals.
- `engine/9-Schedule.ps1 -Install` — registers the scheduled tasks (dry-run until `-Live`).
- `engine/8-KeepAwake.ps1 -Hold` — holds the machine out of idle sleep for the session. The
  stop watch is the stop, so a sleeping machine is a position with no stop. The scheduler
  starts the hold at 22:25 SGT; `-Status` reports power source and sleep timeouts.
- `engine/10-Shutdown.ps1 -Execute` — powers the machine off after the 05:15 end-of-day
  refresh, Mon–Sat at 05:20 and 09:05 SGT. The 05:20 run powers off only when flat; with a
  position open the after-hours stop watch needs the machine until 20:00 ET, so the 09:05 run
  does it. It refuses if the refresh did not run or failed, and only acts between 04:00 and
  12:00 SGT so a replayed run cannot shut the laptop down at the evening start. `RUN-ENGINE
  poweroff` is the dry check.
