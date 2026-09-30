create or replace view public.v_paper_positions_current as
 SELECT snapshot_date,
    symbol,
    qty,
    side,
    avg_entry_price_usd,
    current_price_usd,
    market_value_usd,
    unrealized_pl_usd,
    unrealized_pl_pct
   FROM paper_positions
  WHERE snapshot_date = (( SELECT max(paper_positions_1.snapshot_date) AS max
           FROM paper_positions paper_positions_1))
  ORDER BY market_value_usd DESC;
