CREATE OR REPLACE FUNCTION public.fn_process_prices()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE req record; resp record; j jsonb; k text; v jsonb; n int := 0;
BEGIN
  FOR req IN SELECT * FROM public.price_fetch_requests WHERE NOT processed ORDER BY requested_at LOOP
    SELECT status_code, content INTO resp FROM net._http_response WHERE id = req.request_id;
    IF resp IS NULL THEN CONTINUE; END IF;
    IF resp.status_code <> 200 THEN
      UPDATE public.price_fetch_requests SET processed=true, status_code=resp.status_code, error=left(resp.content,300)
        WHERE request_id=req.request_id;
      CONTINUE;
    END IF;
    j := resp.content::jsonb;
    FOR k, v IN SELECT * FROM jsonb_each(j) LOOP
      INSERT INTO public.price_snapshots (snapshot_date, ticker, price_usd, data_source, notes)
      VALUES (CURRENT_DATE, k,
              COALESCE((v#>>'{latestTrade,p}')::numeric, (v#>>'{dailyBar,c}')::numeric),
              'alpaca_iex',
              'prev_close=' || COALESCE(v#>>'{prevDailyBar,c}','') || ';day_open=' || COALESCE(v#>>'{dailyBar,o}',''))
      ON CONFLICT DO NOTHING;
      n := n + 1;
    END LOOP;
    UPDATE public.price_fetch_requests SET processed=true, status_code=200 WHERE request_id=req.request_id;
  END LOOP;
  RETURN n || ' prices stored';
END $function$
