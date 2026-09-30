# Alpaca PAPER desk (MJ_PAPER_V1): handover

Verified 30 Sep 2026, 05:57–06:05 Europe/London (04:57–05:05 UTC).
This is a paper-only system. It is kept separate from the Trading 212 accounts.

## Where it runs
The whole system runs **remotely in Supabase** (project "finance chief", Postgres + pg_cron + Vault).
Nothing runs on the PC, so the PC does not need to stay awake.
This repo holds only this note. It holds no code and no secrets.

| Job (pg_cron, UTC) | Schedule | Purpose |
|---|---|---|
| `alpaca_paper_health_check` | every 30 min | Checks identity, clock, data freshness and order reconciliation, then writes heartbeat rows |
| `alpaca_paper_sync_request` / `_process` | 21:05 / 21:15 Mon–Fri | Daily sync of account, positions and fills |
| `price_fetch_*`, `tripwire_evaluation*` | 16:20–16:30, 21:20–21:30 | Prices and tripwires |

**Order execution owner:** only `public.paper_submit_strategy_order` (strategy) and
`private.paper_run_diagnostic_order` (diagnostic) can place orders. Both go through
`private.alpaca_paper_submit_order`. A trigger (`enforce_mj_paper_order_hold`) refuses any other caller.
No edge function or other scheduler posts orders.

## Safety controls (verified)
- `private.alpaca_http` refuses any host other than `paper-api.alpaca.markets` and `data.alpaca.markets`, and refuses writes to anything except the paper API.
- It refuses keys that do not start with `PK` (paper keys). Credentials are held only in Vault (`ALPACA_PAPER_KEY_ID`, `ALPACA_PAPER_SECRET`).
- Identity check: the account number must start with `PA`, the account must be ACTIVE and not blocked, and the currency must be USD.
- Kill switch: `paper_system_config.new_orders_enabled` (now **false**). It stops NEW orders only.
- `client_order_id` is required and unique in `public.paper_orders`. If a submission is uncertain, the system looks the order up by client ID and never resubmits blind.
- The legacy pre-baseline book (8 positions, 37 filled orders) is tagged `LEGACY_PRE_BASELINE` and excluded from strategy performance.

## Verification evidence (live broker responses)
- Account `PA******3BJ7`: ACTIVE, trading not blocked, shorting enabled, equity $103,307, cash $62,897, buying power $361,334.
- Open orders: **0**. Uncertain submissions: 0. Duplicate client IDs: 0. External orders since baseline: 0.
- Positions (all legacy, none placed by the strategy): AAPL 17, AMD 9, GOOGL 13, MSFT 12, NVDA 24, QQQ 6, SPY 6, TSLA 12.
- Last broker fill: 6 Aug 2026 (AVGO sell). There have been no fills since the baseline.
- Market data: `iex` feed, real-time but IEX venue only (not NBBO). The latest SPY quote was from the 29 Sep close, which is expected while the market is closed. IEX daily bars return data for 22–29 Sep. Historical SIP bars return HTTP 200.
- Diagnostic dry run: **blocked**. Reasons: no approved test limit, kill switch engaged, no quote-age limit, session closed.

## Remaining blockers (Joe decisions — not invented)
1. `permitted_strategy_tags`: which strategy tags may trade (e.g. LONG_MOMENTUM_BREAKOUT, short, swing).
2. `permitted_asset_classes`: equity-only, or equity + options.
3. `max_quote_age_seconds`: the stale-quote block (health check uses 120s until this is set).
4. `diagnostic_max_notional_usd`: the limit for the one-share diagnostic order.
5. Then move desk status from PAUSED_RISK to PAPER_VALIDATION and release the kill switch.

## Known limitations
- There is no live websocket stream (trade_updates or market data). Postgres cannot hold a socket open, so state is reconciled by polling every 30 minutes and after each submission.
- The dashboard terminal shows the paper scoreboard, not `v_paper_system_health`. Health failures do reach the dashboard as red `PAPER_HEALTH` alerts.

## Operating guide (run in the Supabase SQL editor)
```sql
-- Status
select * from public.v_paper_system_health;
select public.fn_paper_health_check();          -- force a fresh check

-- Kill switch (stops NEW orders only)
select public.paper_kill_switch_engage('reason');
-- Release only after the decisions above are recorded:
-- select private.paper_kill_switch_release(...);

-- Diagnostic order: dry run first, live only in a regular session once limits are set
select private.paper_run_diagnostic_order('SYMBOL','RUN_ONE_PAPER_DIAGNOSTIC_ORDER', true);
```
Cancelling orders (`private.alpaca_paper_cancel_order`) and closing positions are separate explicit actions.
The kill switch never does either.

## Config template (redacted)
```
market_data_feed = iex
max_single_position_pct = 8      max_gross_exposure_pct = 125
max_short_gross_exposure_pct = 35 max_risk_per_trade_pct = 0.5
min_reward_risk = 2              daily_loss_circuit_breaker_pct = 2
max_concurrent_positions = 8     max_drawdown_limit_pct = 8
permitted_strategy_tags = <DECISION NEEDED>
permitted_asset_classes = <DECISION NEEDED>
max_quote_age_seconds   = <DECISION NEEDED>
diagnostic_max_notional_usd = <DECISION NEEDED>
Vault: ALPACA_PAPER_KEY_ID=PK****  ALPACA_PAPER_SECRET=****
```
Stack: Postgres 17.6, pg_cron, `http` extension, Vault. Dashboard edge function uses supabase-js 2.95.0.

**Status: READ-ONLY VERIFIED.** Paper execution is blocked pending the decisions above.
