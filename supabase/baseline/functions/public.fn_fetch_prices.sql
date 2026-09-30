CREATE OR REPLACE FUNCTION public.fn_fetch_prices()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE kid text; sec text; syms text; rid bigint;
BEGIN
  SELECT decrypted_secret INTO kid FROM vault.decrypted_secrets WHERE name='ALPACA_PAPER_KEY_ID';
  SELECT decrypted_secret INTO sec FROM vault.decrypted_secrets WHERE name='ALPACA_PAPER_SECRET';
  SELECT string_agg(DISTINCT t, ',') INTO syms FROM (
    SELECT upper(ticker) AS t FROM public.v_current_portfolio
      WHERE upper(ticker) <> 'CASH' AND ticker !~ '[^A-Za-z.]'
    UNION
    SELECT upper(ticker) FROM public.watchlist
      WHERE coalesce(status,'active') NOT IN ('dropped','bought') AND ticker !~ '[^A-Za-z.]'
  ) x;
  IF syms IS NULL THEN RETURN 'no tickers'; END IF;
  rid := net.http_get(
    'https://data.alpaca.markets/v2/stocks/snapshots?feed=iex&symbols=' || syms,
    headers := jsonb_build_object('APCA-API-KEY-ID', kid, 'APCA-API-SECRET-KEY', sec));
  INSERT INTO public.paper_sync_requests(request_id, kind)
    VALUES (rid, 'account') ON CONFLICT DO NOTHING; -- reuse tracker; kind repurposed below
  UPDATE public.paper_sync_requests SET kind='account' WHERE request_id=rid; -- placeholder
  -- track separately:
  DELETE FROM public.paper_sync_requests WHERE request_id=rid;
  INSERT INTO public.price_fetch_requests(request_id) VALUES (rid);
  RETURN 'price request sent for: ' || syms;
END $function$
