# MJ_PAPER_V1: Alpaca PAPER desk handover

Last updated 30 Sep 2026 (Europe/London). The desk is paper-only and kept separate from Trading 212.
Implementation and recovery steps: [`supabase/README.md`](../supabase/README.md).

## 1. Current state

| Item | State |
|---|---|
| Desk status | `PAPER_VALIDATION` |
| Master kill switch (`new_orders_enabled`) | **false**: no new orders of any kind |
| Strategy execution (`strategy_orders_enabled`) | **false**: no strategy is `APPROVED` |
| Diagnostic window (`diagnostic_enabled`) | false. It is armed per test, time-boxed, and auto-disarms. |
| Paper account | `PA******3BJ7`, ACTIVE, `paper-api.alpaca.markets` |
| Open orders | 0 |
| Positions | 8 legacy longs (AAPL, AMD, GOOGL, MSFT, NVDA, QQQ, SPY, TSLA), all pre-baseline and untouched |
| Execution test | **PENDING**: the market was closed while this was prepared (see §5) |

## 2. Where it runs

Everything runs remotely inside Supabase (Postgres functions, pg_cron, Vault).
Nothing runs on Joe's PC, so the PC does not need to stay on.
Supabase's own availability is the only dependency.

## 3. How an order can reach Alpaca (verified in code, 30 Sep)

There is exactly one outbound path: `private.alpaca_http`. It refuses:
- any host except `paper-api.alpaca.markets` and `data.alpaca.markets`
- any `POST` except to `paper-api…/v2/orders`, and only when the body's `client_order_id` equals the
  session's validated id **and** a non-dry-run audit row exists for it
- any `DELETE` except one order id (so no bulk cancel and no "close all positions")
- any key that does not start with `PK`

This is enforced by host, not only by key prefix. A live key would be sent only to the paper host, where it cannot trade.

The audit insert that precedes every POST fires the `enforce_mj_paper_order_hold` trigger, which requires:
1. master kill switch released
2. desk status `PAPER_VALIDATION`
3. the validated client id set by the calling function
4. **diagnostic ids (`mj-diag-…`)**: called from `private.paper_diag_run`, window armed and unexpired,
   whole-share DAY limit, qty ≤ 1, buy notional ≤ $100
5. **strategy ids**: `strategy_orders_enabled = true`, an MJ trade that owns the id, and a registry status of `APPROVED`

Who can call execution functions: only the database owner (`postgres`: SQL editor, pg_cron).
`anon` and `authenticated` cannot execute any of them and have no access to the `private` schema.
`service_role` (used by the dashboard) has no access to the `private` schema. It can read the views and
call the public desk functions: health check, reconcile, the sync/price/tripwire jobs,
`paper_kill_switch_engage` and `paper_submit_strategy_order`. Any order from these still passes through
the trigger and bridge gates above. The dashboard code calls none of them.

Duplicate prevention works at three levels:
- a unique `client_order_id` in the broker ledger (`paper_orders`)
- a unique live `client_order_id` in the audit table
- a broker lookup by client id before any retry of an uncertain submission (no blind resubmits)

Negative tests run 30 Sep (all inside rolled-back blocks, no HTTP sent):
POST without a validated id, `DELETE /v2/positions`, bulk cancel, live host, `POST /v2/positions/…`,
kill-switch engaged, strategy id while diagnostics are armed, diagnostic id from the wrong caller, qty 2,
$150 notional, market order and an expired window were **all refused**. A valid diagnostic row passed the gate.

## 4. Strategy audit: nothing is ready

No scheduled job generates signals. Every strategy trade so far was written by hand by an agent into
`paper_strategy_trades` and then submitted. The path is: agent → `paper_strategy_trades` (PLANNED) +
`mj_decision_records` → `paper_submit_strategy_order` (validator) → bridge.

| Strategy | Entry rule | Exit rule | Sizing | Holding | Protective orders | Monitoring | Status |
|---|---|---|---|---|---|---|---|
| LONG_MOMENTUM_BREAKOUT | not codified (per-trade text) | per-trade stop/target in DB only | validator caps; qty manual | per-trade (2–7 d) | **none** | none for exits | PAUSED_INCOMPLETE |
| LONG_PULLBACK_CONTINUATION | not codified | per-trade only | caps; sample breached 8% cap | per-trade (2–8 d) | **none** | none | PAUSED_INCOMPLETE |
| LONG_CATALYST | override samples only | not codified | not defined | not defined | none | none | PAUSED_INCOMPLETE |
| SHORT_BREAKDOWN | not codified | per-trade only; no buy-to-cover order | caps + shortable/ETB checks | per-trade (1–5 d) | **none (unbounded short risk)** | none | PAUSED_INCOMPLETE |
| SHORT_MEAN_REVERSION | override sample only | not codified | not defined | not defined | none | none | PAUSED_INCOMPLETE |
| EVENT_SWING | override samples (incl. options) | not codified | not defined | not defined | none | none | PAUSED_INCOMPLETE |
| SAMPLE_DAILY | curriculum wrapper, not a strategy | — | — | — | — | — | RETIRED |

Key finding: **exits depend on nobody.** Stops and targets are database fields. No broker-held stop,
bracket or OCO order is placed, and no job compares price to stop or target. The 30-minute health check
only reconciles order status. An open strategy position would be unprotected outside manual action.

The full detail is in `public.v_paper_strategy_status` (and on the dashboard).

### Schedules vs the exchange (UTC cron; DST)

- US regular session: 13:30–20:00 UTC until US DST ends on **1 Nov 2026**, then 14:30–21:00 UTC.
  The UK changes on 25 Oct, so for one week London is only 4 hours behind New York.
- All order gating uses the **broker clock** (`/v2/clock`), not cron times, so DST cannot open a
  trading window by mistake.
- `alpaca_paper_sync_request` at 21:05 UTC runs 65 min after the close in summer and **5 min** after it in
  winter. That is still after the close, but tight.
- `price_fetch_*_pm` at 16:20 UTC is intraday all year. `tripwire_evaluation` sends alerts only and never trades.
- There is no intraday exit monitoring at any time of year.

## 5. Diagnostic lifecycle test (Joe's settings, diagnostic-only)

Settings recorded with provenance in `paper_system_config.diagnostic_settings`:
- US equities only, no options
- $100 maximum exposure, cash only (no margin)
- quotes no older than 60 s
- one diagnostic order at a time
- legacy positions preserved

Engineer choices within those limits:
- 1 share
- spread ≤ 1%
- whole-share DAY limit orders in the regular session only
- the window auto-disarms

Procedure (SQL editor, during a broker-confirmed regular session):

```sql
-- 0) dry run (always first)
select private.paper_diag_run('fill', 'F', 'RUN_ONE_PAPER_DIAGNOSTIC_ORDER', true);
-- 1) arm a short window (strategies stay disabled)
select private.paper_diag_arm('ARM_DIAGNOSTIC_ONLY', 30, 'Joe');
-- 2) accepted -> cancelled: limit 5% below bid, must rest unfilled, then is cancelled
select private.paper_diag_run('rest',  'F', 'RUN_ONE_PAPER_DIAGNOSTIC_ORDER', false);
-- 3) accepted -> filled: marketable limit at ask + 0.2%; any unfilled remainder is cancelled
select private.paper_diag_run('fill',  'F', 'RUN_ONE_PAPER_DIAGNOSTIC_ORDER', false);
-- 4) close ONLY the diagnostic-owned filled quantity
select private.paper_diag_run('close', 'F', 'RUN_ONE_PAPER_DIAGNOSTIC_ORDER', false);
-- 5) disarm and review
select private.paper_diag_disarm('lifecycle test complete');
select * from public.v_paper_diagnostic_results order by id desc;
select * from public.v_paper_diagnostic_positions;   -- net qty must be 0
```

Every step records the broker's actual HTTP status, order status (`new`/`accepted`/`filled`/
`partially_filled`/`canceled`/`rejected`), fill quantity and price, and timestamps in `paper_diagnostic_runs`.
It then reconciles into `paper_orders` with `origin = 'DIAGNOSTIC'`.

Diagnostic results never enter strategy performance: the scoreboard reads only `paper_strategy_trades`.

## 6. Operating guide

| Task | Command |
|---|---|
| Status | `select * from public.v_paper_system_health;` |
| Force a health check | `select public.fn_paper_health_check();` |
| **Kill switch: stop all new orders** | `select public.paper_kill_switch_engage('reason', 'Joe');` |
| Cancel one open order (separate action) | `select private.alpaca_paper_cancel_order('<order uuid>');` |
| Close positions | not automated. It is a separate, explicit action and never done by the kill switch. |
| Reconcile after any outage | `select public.fn_reconcile_alpaca_orders();` |

The health check runs every 30 minutes and after restarts. The desk reports `FAILING` if identity,
clock, market data or reconciliation go stale for more than 75 minutes, and raises a red `PAPER_HEALTH` alert on the dashboard.

## 7. Decisions needed from Joe before any strategy can trade

For **each** strategy you want to run, give:
1. **Entry rule**: the exact condition, data and timeframe that creates a signal.
2. **Exit and stop execution**: broker-held bracket/OCO orders placed with the entry, or a monitoring job (and how often it runs).
3. **Sizing rule**: how quantity is derived. Today it is chosen by hand and only capped.
4. **Holding period / time stop**, and what happens at the limit.
5. **Failure behaviour**: what happens to open positions if monitoring stops.

Desk-wide, you also need to set:
- `permitted_strategy_tags`
- `permitted_asset_classes` (options remain out of scope unless you say otherwise)
- `max_quote_age_seconds` (the 60 s value applies to **diagnostics only**)
