create or replace view public.v_paper_strategy_breakdown as
 SELECT system_key,
    strategy_tag,
    side,
    count(*) FILTER (WHERE status = 'CLOSED'::text) AS closed_trades,
    count(*) FILTER (WHERE status = ANY (ARRAY['OPEN'::text, 'PARTIAL'::text])) AS open_trades,
    count(*) FILTER (WHERE status = 'CLOSED'::text AND COALESCE(realised_pnl_usd, 0::numeric) > 0::numeric) AS wins,
    round(COALESCE(sum(realised_pnl_usd) FILTER (WHERE status = 'CLOSED'::text), 0::numeric), 2) AS realised_pnl_usd,
    round(avg(realised_pnl_usd) FILTER (WHERE status = 'CLOSED'::text), 2) AS expectancy_usd,
    round(avg(realised_r_multiple) FILTER (WHERE status = 'CLOSED'::text), 3) AS avg_r_multiple,
        CASE
            WHEN abs(sum(realised_pnl_usd) FILTER (WHERE status = 'CLOSED'::text AND realised_pnl_usd < 0::numeric)) > 0::numeric THEN round(sum(realised_pnl_usd) FILTER (WHERE status = 'CLOSED'::text AND realised_pnl_usd > 0::numeric) / abs(sum(realised_pnl_usd) FILTER (WHERE status = 'CLOSED'::text AND realised_pnl_usd < 0::numeric)), 3)
            ELSE NULL::numeric
        END AS profit_factor
   FROM paper_strategy_trades
  GROUP BY system_key, strategy_tag, side;
