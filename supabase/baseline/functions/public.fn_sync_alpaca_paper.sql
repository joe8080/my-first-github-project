CREATE OR REPLACE FUNCTION public.fn_sync_alpaca_paper()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE kid text; sec text; hdrs jsonb; rid bigint;
BEGIN
  SELECT decrypted_secret INTO kid FROM vault.decrypted_secrets WHERE name='ALPACA_PAPER_KEY_ID';
  SELECT decrypted_secret INTO sec FROM vault.decrypted_secrets WHERE name='ALPACA_PAPER_SECRET';
  IF kid IS NULL OR sec IS NULL THEN RETURN 'Vault secrets missing'; END IF;
  hdrs := jsonb_build_object('APCA-API-KEY-ID', kid, 'APCA-API-SECRET-KEY', sec);

  rid := net.http_get('https://paper-api.alpaca.markets/v2/account', headers := hdrs);
  INSERT INTO public.paper_sync_requests(request_id, kind) VALUES (rid,'account');

  rid := net.http_get('https://paper-api.alpaca.markets/v2/positions', headers := hdrs);
  INSERT INTO public.paper_sync_requests(request_id, kind) VALUES (rid,'positions');

  rid := net.http_get('https://paper-api.alpaca.markets/v2/account/activities?activity_types=FILL&page_size=100', headers := hdrs);
  INSERT INTO public.paper_sync_requests(request_id, kind) VALUES (rid,'fills');

  RETURN '3 requests sent';
END $function$
