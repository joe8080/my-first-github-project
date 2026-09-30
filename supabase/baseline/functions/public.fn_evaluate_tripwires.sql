CREATE OR REPLACE FUNCTION public.fn_evaluate_tripwires()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE n int := 0; r record;
BEGIN
  FOR r IN
    SELECT p.ticker, p.price_usd,
           (regexp_match(p.notes, 'prev_close=([0-9.]+)'))[1]::numeric AS prev_close
    FROM public.price_snapshots p
    JOIN (SELECT DISTINCT upper(ticker) t FROM public.v_current_portfolio WHERE upper(ticker)<>'CASH') h
      ON h.t = p.ticker
    WHERE p.snapshot_date = CURRENT_DATE AND p.data_source='alpaca_iex'
  LOOP
    IF r.prev_close IS NOT NULL AND r.prev_close > 0
       AND (r.price_usd / r.prev_close - 1) <= -0.08 THEN
      INSERT INTO public.alerts_log (agent_source, alert_type, severity, ticker, headline, detail, action_required)
      SELECT 'tripwire_engine','price_drop','red', r.ticker,
             r.ticker || ' down ' || round((1 - r.price_usd/r.prev_close)*100,1) || '% today',
             'Price $' || r.price_usd || ' vs prev close $' || r.prev_close || '. Check thesis exit conditions and news before acting.',
             true
      WHERE NOT EXISTS (
        SELECT 1 FROM public.alerts_log a
        WHERE a.ticker=r.ticker AND a.alert_type='price_drop'
          AND a.created_at::date = CURRENT_DATE);
      n := n + 1;
    END IF;
  END LOOP;

  FOR r IN
    SELECT h.ticker, h.account, h.avg_cost, p.price_usd
    FROM (SELECT upper(ticker) AS ticker, account, max(avg_cost_gbp) AS avg_cost
          FROM public.holdings
          WHERE status='active' AND avg_cost_gbp IS NOT NULL
          GROUP BY 1,2) h
    JOIN public.price_snapshots p
      ON p.ticker = h.ticker AND p.snapshot_date = CURRENT_DATE AND p.data_source='alpaca_iex'
    WHERE h.avg_cost > 0 AND p.price_usd / h.avg_cost - 1 <= -0.25
  LOOP
    INSERT INTO public.alerts_log (agent_source, alert_type, severity, ticker, headline, detail, action_required)
    SELECT 'tripwire_engine','drawdown_vs_cost','amber', r.ticker,
           r.ticker || ' (' || r.account || ') ~' || round((1 - r.price_usd/r.avg_cost)*100,0) || '% below avg cost',
           'Note: cost stored in GBP vs price USD — approximate until FX-adjusted. Review thesis exit conditions.',
           true
    WHERE NOT EXISTS (
      SELECT 1 FROM public.alerts_log a
      WHERE a.ticker=r.ticker AND a.alert_type='drawdown_vs_cost'
        AND a.created_at >= CURRENT_DATE - 7);
    n := n + 1;
  END LOOP;
  RETURN n || ' tripwires evaluated';
END $function$
