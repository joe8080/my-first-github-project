create or replace view public.v_paper_trading_scoreboard as
 WITH cfg AS (
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
            paper_system_config.updated_at
           FROM paper_system_config
          WHERE paper_system_config.system_key = 'MJ_PAPER_V1'::text
        ), closed AS (
         SELECT count(*) FILTER (WHERE paper_strategy_trades.status = 'CLOSED'::text) AS closed_trades,
            count(*) FILTER (WHERE paper_strategy_trades.status = ANY (ARRAY['OPEN'::text, 'PARTIAL'::text])) AS open_trades,
            count(*) FILTER (WHERE paper_strategy_trades.status = 'CLOSED'::text AND COALESCE(paper_strategy_trades.realised_pnl_usd, 0::numeric) > 0::numeric) AS wins,
            count(*) FILTER (WHERE paper_strategy_trades.status = 'CLOSED'::text AND COALESCE(paper_strategy_trades.realised_pnl_usd, 0::numeric) < 0::numeric) AS losses,
            COALESCE(sum(paper_strategy_trades.realised_pnl_usd) FILTER (WHERE paper_strategy_trades.status = 'CLOSED'::text), 0::numeric) AS realised_pnl,
            COALESCE(sum(paper_strategy_trades.unrealised_pnl_usd) FILTER (WHERE paper_strategy_trades.status = ANY (ARRAY['OPEN'::text, 'PARTIAL'::text])), 0::numeric) AS unrealised_pnl,
            avg(paper_strategy_trades.realised_pnl_usd) FILTER (WHERE paper_strategy_trades.status = 'CLOSED'::text AND paper_strategy_trades.realised_pnl_usd > 0::numeric) AS avg_win,
            avg(paper_strategy_trades.realised_pnl_usd) FILTER (WHERE paper_strategy_trades.status = 'CLOSED'::text AND paper_strategy_trades.realised_pnl_usd < 0::numeric) AS avg_loss,
            sum(paper_strategy_trades.realised_pnl_usd) FILTER (WHERE paper_strategy_trades.status = 'CLOSED'::text AND paper_strategy_trades.realised_pnl_usd > 0::numeric) AS gross_profit,
            abs(sum(paper_strategy_trades.realised_pnl_usd) FILTER (WHERE paper_strategy_trades.status = 'CLOSED'::text AND paper_strategy_trades.realised_pnl_usd < 0::numeric)) AS gross_loss,
            avg(EXTRACT(epoch FROM paper_strategy_trades.closed_at - paper_strategy_trades.opened_at) / 86400.0) FILTER (WHERE paper_strategy_trades.status = 'CLOSED'::text AND paper_strategy_trades.opened_at IS NOT NULL AND paper_strategy_trades.closed_at IS NOT NULL) AS avg_holding_days,
            count(*) FILTER (WHERE paper_strategy_trades.rule_exception = true) AS rule_exceptions
           FROM paper_strategy_trades
          WHERE paper_strategy_trades.system_key = 'MJ_PAPER_V1'::text
        ), latest_daily AS (
         SELECT paper_system_daily.snapshot_date,
            paper_system_daily.system_key,
            paper_system_daily.account_equity_usd,
            paper_system_daily.new_system_realised_pnl_usd,
            paper_system_daily.new_system_unrealised_pnl_usd,
            paper_system_daily.new_system_total_pnl_usd,
            paper_system_daily.new_system_return_pct,
            paper_system_daily.equity_high_watermark_usd,
            paper_system_daily.drawdown_pct,
            paper_system_daily.gross_exposure_usd,
            paper_system_daily.long_exposure_usd,
            paper_system_daily.short_exposure_usd,
            paper_system_daily.spy_price,
            paper_system_daily.qqq_price,
            paper_system_daily.spy_return_since_baseline_pct,
            paper_system_daily.qqq_return_since_baseline_pct,
            paper_system_daily.closed_trades,
            paper_system_daily.open_trades,
            paper_system_daily.rule_violations,
            paper_system_daily.notes,
            paper_system_daily.created_at,
            paper_system_daily.updated_at
           FROM paper_system_daily
          WHERE paper_system_daily.system_key = 'MJ_PAPER_V1'::text
          ORDER BY paper_system_daily.snapshot_date DESC
         LIMIT 1
        ), violations AS (
         SELECT count(*) AS rule_violations
           FROM paper_trade_events e
             JOIN paper_strategy_trades t ON t.id = e.trade_id
          WHERE t.system_key = 'MJ_PAPER_V1'::text AND e.event_type = 'RULE_VIOLATION'::text
        )
 SELECT cfg.system_name,
    cfg.status AS system_status,
    cfg.baseline_at,
    cfg.baseline_equity_usd,
    latest_daily.account_equity_usd,
    closed.realised_pnl AS new_system_realised_pnl_usd,
    closed.unrealised_pnl AS new_system_unrealised_pnl_usd,
    closed.realised_pnl + closed.unrealised_pnl AS new_system_total_pnl_usd,
        CASE
            WHEN cfg.baseline_equity_usd > 0::numeric THEN round((closed.realised_pnl + closed.unrealised_pnl) / cfg.baseline_equity_usd * 100::numeric, 4)
            ELSE NULL::numeric
        END AS new_system_return_pct,
    latest_daily.spy_return_since_baseline_pct,
    latest_daily.qqq_return_since_baseline_pct,
    closed.closed_trades,
    closed.open_trades,
    closed.wins,
    closed.losses,
        CASE
            WHEN closed.closed_trades > 0 THEN round(closed.wins::numeric / closed.closed_trades::numeric * 100::numeric, 2)
            ELSE NULL::numeric
        END AS win_rate_pct,
    closed.avg_win AS avg_win_usd,
    closed.avg_loss AS avg_loss_usd,
        CASE
            WHEN closed.gross_loss > 0::numeric THEN round(closed.gross_profit / closed.gross_loss, 3)
            ELSE NULL::numeric
        END AS profit_factor,
        CASE
            WHEN closed.closed_trades > 0 THEN round(closed.realised_pnl / closed.closed_trades::numeric, 2)
            ELSE NULL::numeric
        END AS expectancy_usd_per_closed_trade,
    closed.avg_holding_days,
    latest_daily.drawdown_pct AS max_current_drawdown_pct,
    violations.rule_violations,
    closed.rule_exceptions,
    cfg.target_closed_trades,
    cfg.min_profit_factor,
    cfg.max_drawdown_limit_pct,
        CASE
            WHEN closed.closed_trades < cfg.target_closed_trades THEN 'BUILD_SAMPLE'::text
            WHEN closed.realised_pnl <= 0::numeric THEN 'FAIL_EXPECTANCY'::text
            WHEN closed.gross_loss IS NULL OR closed.gross_loss = 0::numeric THEN 'NEEDS_MORE_LOSS_SAMPLE'::text
            WHEN (closed.gross_profit / closed.gross_loss) < cfg.min_profit_factor THEN 'FAIL_PROFIT_FACTOR'::text
            WHEN COALESCE(latest_daily.drawdown_pct, 0::numeric) > cfg.max_drawdown_limit_pct THEN 'FAIL_DRAWDOWN'::text
            WHEN violations.rule_violations > 0 THEN 'REVIEW_RULE_VIOLATIONS'::text
            ELSE 'ELIGIBLE_FOR_GRADUATION_REVIEW'::text
        END AS graduation_gate
   FROM cfg
     CROSS JOIN closed
     CROSS JOIN violations
     LEFT JOIN latest_daily ON true;
