create or replace view public.v_paper_fills_needing_review as
 SELECT alpaca_id,
    filled_at::date AS fill_date,
    symbol,
    side,
    qty,
    price_usd,
    CURRENT_DATE - filled_at::date AS days_since_fill
   FROM paper_fills
  WHERE NOT reviewed AND filled_at <= (now() - '30 days'::interval)
  ORDER BY filled_at;
