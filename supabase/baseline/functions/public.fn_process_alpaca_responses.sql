CREATE OR REPLACE FUNCTION public.fn_process_alpaca_responses()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE req record; resp record; j jsonb; item jsonb; n int := 0;
BEGIN
  FOR req IN SELECT * FROM public.paper_sync_requests WHERE NOT processed ORDER BY requested_at LOOP
    SELECT status_code, content INTO resp FROM net._http_response WHERE id = req.request_id;
    IF resp IS NULL THEN CONTINUE; END IF; -- not arrived yet
    IF resp.status_code <> 200 THEN
      UPDATE public.paper_sync_requests
        SET processed=true, status_code=resp.status_code, error=left(resp.content,500)
        WHERE request_id=req.request_id;
      CONTINUE;
    END IF;
    j := resp.content::jsonb;

    IF req.kind = 'account' THEN
      INSERT INTO public.paper_account_snapshots(snapshot_date, equity_usd, cash_usd, buying_power_usd)
      VALUES (CURRENT_DATE, (j->>'equity')::numeric, (j->>'cash')::numeric, (j->>'buying_power')::numeric)
      ON CONFLICT (snapshot_date) DO UPDATE
        SET equity_usd=EXCLUDED.equity_usd, cash_usd=EXCLUDED.cash_usd,
            buying_power_usd=EXCLUDED.buying_power_usd, snapshot_at=now();

    ELSIF req.kind = 'positions' THEN
      DELETE FROM public.paper_positions WHERE snapshot_date = CURRENT_DATE;
      FOR item IN SELECT * FROM jsonb_array_elements(j) LOOP
        INSERT INTO public.paper_positions
          (snapshot_date, symbol, qty, side, avg_entry_price_usd, current_price_usd,
           market_value_usd, unrealized_pl_usd, unrealized_pl_pct)
        VALUES (CURRENT_DATE, item->>'symbol', (item->>'qty')::numeric, item->>'side',
                (item->>'avg_entry_price')::numeric, (item->>'current_price')::numeric,
                (item->>'market_value')::numeric, (item->>'unrealized_pl')::numeric,
                round((item->>'unrealized_plpc')::numeric * 100, 2))
        ON CONFLICT (snapshot_date, symbol) DO NOTHING;
      END LOOP;

    ELSIF req.kind = 'fills' THEN
      FOR item IN SELECT * FROM jsonb_array_elements(j) LOOP
        INSERT INTO public.paper_fills(alpaca_id, filled_at, symbol, side, qty, price_usd, order_id)
        VALUES (item->>'id', (item->>'transaction_time')::timestamptz, item->>'symbol',
                item->>'side', (item->>'qty')::numeric, (item->>'price')::numeric, item->>'order_id')
        ON CONFLICT (alpaca_id) DO NOTHING;
      END LOOP;
    END IF;

    UPDATE public.paper_sync_requests SET processed=true, status_code=200 WHERE request_id=req.request_id;
    n := n + 1;
  END LOOP;
  RETURN n || ' responses processed';
END $function$
