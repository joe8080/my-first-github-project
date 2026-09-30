create or replace view public.v_paper_system_health as
 WITH c AS (
         SELECT paper_system_config.system_key,
            paper_system_config.system_name,
            paper_system_config.baseline_at,
            paper_system_config.baseline_equity_usd,
            paper_system_config.benchmark_spy_start,
            paper_system_config.benchmark_qqq_start,
            paper_system_config.target_closed_trades,
            paper_system_config.min_profit_factor,
            paper_system_config.max_drawdown_limit_pct,
            paper_system_config.max_risk_per_trade_pct,
            paper_system_config.exceptional_risk_per_trade_pct,
            paper_system_config.max_single_position_pct,
            paper_system_config.max_speculative_position_pct,
            paper_system_config.max_concurrent_positions,
            paper_system_config.max_gross_exposure_pct,
            paper_system_config.max_short_gross_exposure_pct,
            paper_system_config.daily_loss_circuit_breaker_pct,
            paper_system_config.status,
            paper_system_config.notes,
            paper_system_config.created_at,
            paper_system_config.updated_at,
            paper_system_config.new_orders_enabled,
            paper_system_config.kill_switch_reason,
            paper_system_config.kill_switch_changed_at,
            paper_system_config.kill_switch_changed_by,
            paper_system_config.permitted_strategy_tags,
            paper_system_config.permitted_asset_classes,
            paper_system_config.min_reward_risk,
            paper_system_config.market_data_feed,
            paper_system_config.max_quote_age_seconds,
            paper_system_config.diagnostic_max_notional_usd
           FROM paper_system_config
          WHERE paper_system_config.system_key = 'MJ_PAPER_V1'::text
        ), hb AS (
         SELECT max(
                CASE
                    WHEN paper_system_heartbeat.component = 'identity'::text THEN paper_system_heartbeat.ok::integer
                    ELSE NULL::integer
                END)::boolean AS identity_ok,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'identity'::text THEN paper_system_heartbeat.last_ok_at
                    ELSE NULL::timestamp with time zone
                END) AS identity_last_ok,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'identity'::text THEN paper_system_heartbeat.details::text
                    ELSE NULL::text
                END)::jsonb AS identity,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'clock'::text THEN paper_system_heartbeat.ok::integer
                    ELSE NULL::integer
                END)::boolean AS clock_ok,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'clock'::text THEN paper_system_heartbeat.details::text
                    ELSE NULL::text
                END)::jsonb AS clock,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'clock'::text THEN paper_system_heartbeat.last_ok_at
                    ELSE NULL::timestamp with time zone
                END) AS clock_last_ok,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'market_data'::text THEN paper_system_heartbeat.ok::integer
                    ELSE NULL::integer
                END)::boolean AS md_ok,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'market_data'::text THEN paper_system_heartbeat.last_ok_at
                    ELSE NULL::timestamp with time zone
                END) AS md_last_ok,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'market_data'::text THEN paper_system_heartbeat.details::text
                    ELSE NULL::text
                END)::jsonb AS md,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'order_reconcile'::text THEN paper_system_heartbeat.ok::integer
                    ELSE NULL::integer
                END)::boolean AS rec_ok,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'order_reconcile'::text THEN paper_system_heartbeat.last_ok_at
                    ELSE NULL::timestamp with time zone
                END) AS rec_last_ok,
            max(
                CASE
                    WHEN paper_system_heartbeat.component = 'order_reconcile'::text THEN paper_system_heartbeat.details::text
                    ELSE NULL::text
                END)::jsonb AS rec
           FROM paper_system_heartbeat
        ), sync_raw AS (
         SELECT max(paper_sync_requests.requested_at) FILTER (WHERE paper_sync_requests.kind = 'account'::text AND paper_sync_requests.processed AND paper_sync_requests.status_code = 200) AS a,
            max(paper_sync_requests.requested_at) FILTER (WHERE paper_sync_requests.kind = 'positions'::text AND paper_sync_requests.processed AND paper_sync_requests.status_code = 200) AS p,
            max(paper_sync_requests.requested_at) FILTER (WHERE paper_sync_requests.kind = 'fills'::text AND paper_sync_requests.processed AND paper_sync_requests.status_code = 200) AS f,
            max("left"(paper_sync_requests.error, 200)) FILTER (WHERE paper_sync_requests.requested_at > (now() - '24:00:00'::interval) AND paper_sync_requests.processed AND COALESCE(paper_sync_requests.status_code, 0) <> 200) AS recent_error
           FROM paper_sync_requests
        ), sync AS (
         SELECT
                CASE
                    WHEN sync_raw.a IS NULL OR sync_raw.p IS NULL OR sync_raw.f IS NULL THEN NULL::timestamp with time zone
                    ELSE LEAST(sync_raw.a, sync_raw.p, sync_raw.f)
                END AS last_ok,
            sync_raw.recent_error
           FROM sync_raw
        ), pos AS (
         SELECT count(*) AS n,
            COALESCE(sum(paper_positions.market_value_usd), 0::numeric) AS mv,
            count(*) FILTER (WHERE NOT (paper_positions.symbol IN ( SELECT paper_strategy_trades.symbol
                   FROM paper_strategy_trades
                  WHERE paper_strategy_trades.status = ANY (ARRAY['OPEN'::text, 'PARTIAL'::text])))) AS legacy_n
           FROM paper_positions
          WHERE paper_positions.snapshot_date = (( SELECT max(paper_positions_1.snapshot_date) AS max
                   FROM paper_positions paper_positions_1))
        ), ord AS (
         SELECT count(*) FILTER (WHERE paper_orders.status = ANY (ARRAY['new'::text, 'accepted'::text, 'pending_new'::text, 'partially_filled'::text, 'held'::text, 'accepted_for_bidding'::text, 'pending_replace'::text, 'pending_cancel'::text, 'calculated'::text])) AS open_orders,
            count(*) FILTER (WHERE paper_orders.origin = 'EXTERNAL_POST_BASELINE'::text AND paper_orders.reviewed_at IS NULL) AS external_orders,
            count(*) FILTER (WHERE paper_orders.origin = 'DIAGNOSTIC'::text) AS diagnostic_orders,
            count(*) FILTER (WHERE paper_orders.origin = 'DIAGNOSTIC'::text AND COALESCE(paper_orders.filled_qty, 0::numeric) > 0::numeric) AS diagnostic_filled
           FROM paper_orders
        ), sig AS (
         SELECT jsonb_build_object('symbol', paper_strategy_trades.symbol, 'side', paper_strategy_trades.side, 'strategy_tag', paper_strategy_trades.strategy_tag, 'status', paper_strategy_trades.status, 'created_at_london', to_char((paper_strategy_trades.created_at AT TIME ZONE 'Europe/London'::text), 'YYYY-MM-DD HH24:MI'::text)) AS latest
           FROM paper_strategy_trades
          WHERE paper_strategy_trades.system_key = 'MJ_PAPER_V1'::text
          ORDER BY paper_strategy_trades.created_at DESC
         LIMIT 1
        ), mj AS (
         SELECT count(*) FILTER (WHERE paper_strategy_trades.status = ANY (ARRAY['ORDERED'::text, 'PARTIAL'::text, 'OPEN'::text])) AS active_trades,
            count(*) FILTER (WHERE paper_strategy_trades.status = 'PLANNED'::text) AS planned_trades,
            count(*) FILTER (WHERE (paper_strategy_trades.status = ANY (ARRAY['ORDERED'::text, 'PARTIAL'::text])) AND paper_strategy_trades.entry_order_id IS NULL) AS uncertain
           FROM paper_strategy_trades
          WHERE paper_strategy_trades.system_key = 'MJ_PAPER_V1'::text
        ), problems AS (
         SELECT array_remove(ARRAY[
                CASE
                    WHEN NOT (EXISTS ( SELECT 1
                       FROM c c_1)) THEN 'FAIL: MJ_PAPER_V1 config row missing'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN hb_1.identity_ok IS NULL THEN 'FAIL: paper identity never checked'::text
                    WHEN NOT hb_1.identity_ok THEN 'FAIL: paper identity/auth check failing'::text
                    WHEN hb_1.identity_last_ok < (now() - '01:15:00'::interval) THEN 'FAIL: paper identity not confirmed for >75 min'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN hb_1.clock_ok IS DISTINCT FROM true THEN 'FAIL: broker clock check failing'::text
                    WHEN hb_1.clock_last_ok < (now() - '01:15:00'::interval) THEN 'FAIL: broker clock not confirmed for >75 min'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN hb_1.md_ok IS NULL THEN 'FAIL: market data never checked'::text
                    WHEN NOT hb_1.md_ok THEN ('FAIL: market data check failing ('::text || COALESCE(hb_1.md ->> 'feed'::text, '?'::text)) || ')'::text
                    WHEN hb_1.md_last_ok < (now() - '01:15:00'::interval) THEN 'FAIL: market data not confirmed for >75 min'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN hb_1.rec_ok IS NULL THEN 'FAIL: order reconciliation never ran'::text
                    WHEN NOT hb_1.rec_ok THEN 'FAIL: order reconciliation failing'::text
                    WHEN hb_1.rec_last_ok < (now() - '01:15:00'::interval) THEN 'FAIL: order reconciliation stale >75 min'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN sync_1.last_ok IS NULL THEN 'FAIL: account/positions/fills sync has not fully succeeded'::text
                    WHEN (now() - sync_1.last_ok) > '76:00:00'::interval OR (now() - sync_1.last_ok) > '28:00:00'::interval AND EXTRACT(isodow FROM now()) >= 2::numeric AND EXTRACT(isodow FROM now()) <= 6::numeric THEN 'WARN: account/positions/fills snapshot sync is stale'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN sync_1.recent_error IS NOT NULL THEN 'WARN: a sync request failed in the last 24h'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN ord_1.external_orders > 0 THEN ('FAIL: '::text || ord_1.external_orders) || ' unreviewed post-baseline orders placed outside the bridge'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN mj_1.uncertain > 0 THEN ('FAIL: '::text || mj_1.uncertain) || ' uncertain submission(s) not yet matched to a broker order'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN jsonb_array_length(COALESCE((hb_1.rec -> 'strategy'::text) -> 'discrepancies'::text, '[]'::jsonb)) > 0 THEN 'FAIL: broker/DB strategy trade discrepancies'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN ord_1.diagnostic_filled > 0 THEN 'WARN: a diagnostic order filled — diagnostic position must be closed explicitly'::text
                    ELSE NULL::text
                END], NULL::text) AS list
           FROM hb hb_1,
            sync sync_1,
            ord ord_1,
            mj mj_1
        ), blocked AS (
         SELECT array_remove(ARRAY[
                CASE
                    WHEN c_1.system_key IS NULL THEN 'Config row missing'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN NOT COALESCE(c_1.new_orders_enabled, false) THEN 'Kill switch engaged: '::text || COALESCE(c_1.kill_switch_reason, ''::text)
                    ELSE NULL::text
                END,
                CASE
                    WHEN c_1.status IS DISTINCT FROM 'PAPER_VALIDATION'::text THEN ('Desk status '::text || COALESCE(c_1.status, 'MISSING'::text)) || ' (strategy orders need PAPER_VALIDATION)'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN c_1.permitted_strategy_tags IS NULL THEN 'Decision needed: permitted strategy tags'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN c_1.permitted_asset_classes IS NULL THEN 'Decision needed: equity-only vs options scope'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN c_1.max_quote_age_seconds IS NULL THEN 'Decision needed: stale-quote limit (seconds)'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN c_1.diagnostic_max_notional_usd IS NULL THEN 'Decision needed: diagnostic test-order limit (diagnostic orders blocked)'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN COALESCE((hb_1.clock ->> 'is_open'::text)::boolean, false) IS FALSE THEN ('US regular session closed (next open '::text || COALESCE(to_char((((hb_1.clock ->> 'next_open'::text)::timestamp with time zone) AT TIME ZONE 'Europe/London'::text), 'Dy DD Mon HH24:MI "London"'::text), '?'::text)) || ')'::text
                    ELSE NULL::text
                END], NULL::text) AS list
           FROM ( SELECT 1 AS one) b
             LEFT JOIN c c_1 ON true
             CROSS JOIN hb hb_1
        )
 SELECT now() AS checked_at_utc,
    to_char((now() AT TIME ZONE 'Europe/London'::text), 'YYYY-MM-DD HH24:MI:SS'::text) AS checked_at_london,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM unnest(problems.list) p(p)
              WHERE p.p ~~ 'FAIL:%'::text)) THEN 'FAILING'::text
            WHEN cardinality(problems.list) > 0 THEN 'DEGRADED'::text
            ELSE 'HEALTHY'::text
        END AS overall_health,
    problems.list AS health_problems,
        CASE
            WHEN COALESCE(c.new_orders_enabled, false) AND c.status = 'PAPER_VALIDATION'::text THEN 'ORDERS_ENABLED'::text
            ELSE 'ORDERS_BLOCKED'::text
        END AS execution_state,
    blocked.list AS blocked_reasons,
    c.status AS desk_status,
    c.new_orders_enabled,
    c.kill_switch_reason,
    c.kill_switch_changed_at,
    'paper-api.alpaca.markets'::text AS trading_host,
    hb.identity ->> 'account_masked'::text AS paper_account,
    hb.identity ->> 'account_status'::text AS paper_account_status,
    (hb.identity ->> 'pass'::text)::boolean AS paper_identity_pass,
    hb.identity_last_ok AS identity_last_ok_at,
    (hb.identity ->> 'equity'::text)::numeric AS equity_usd,
    (hb.identity ->> 'cash'::text)::numeric AS cash_usd,
    (hb.identity ->> 'buying_power'::text)::numeric AS buying_power_usd,
    hb.md ->> 'feed'::text AS market_data_feed,
    hb.md ->> 'delay'::text AS market_data_delay,
    (hb.md ->> 'quote_ts'::text)::timestamp with time zone AS last_quote_at,
    (hb.md ->> 'quote_age_s'::text)::numeric AS last_quote_age_s,
    (hb.md ->> 'session_open'::text)::boolean AS session_open,
    sync.last_ok AS last_account_sync_at,
    round(EXTRACT(epoch FROM now() - sync.last_ok) / 60::numeric) AS account_sync_age_minutes,
    hb.rec_last_ok AS last_order_reconcile_at,
    pos.n AS positions,
    pos.legacy_n AS legacy_positions,
    round(pos.mv, 2) AS positions_market_value_usd,
    ord.open_orders,
    ord.external_orders AS external_post_baseline_orders,
    ord.diagnostic_orders,
    mj.active_trades AS mj_active_trades,
    mj.planned_trades AS mj_planned_trades,
    mj.uncertain AS uncertain_submissions,
    sig.latest AS latest_signal
   FROM ( SELECT 1 AS one) base
     LEFT JOIN c ON true
     CROSS JOIN hb
     CROSS JOIN sync
     CROSS JOIN pos
     CROSS JOIN ord
     CROSS JOIN mj
     CROSS JOIN problems
     CROSS JOIN blocked
     LEFT JOIN sig ON true;
