create or replace view public.v_paper_equity_curve as
 SELECT snapshot_date,
    equity_usd,
    cash_usd,
    equity_usd - lag(equity_usd) OVER (ORDER BY snapshot_date) AS day_change_usd,
    round(100.0 * (equity_usd / NULLIF(first_value(equity_usd) OVER (ORDER BY snapshot_date), 0::numeric) - 1::numeric), 2) AS total_return_pct
   FROM paper_account_snapshots
  ORDER BY snapshot_date;
