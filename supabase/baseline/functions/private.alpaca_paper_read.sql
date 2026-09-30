CREATE OR REPLACE FUNCTION private.alpaca_paper_read(p_path text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_path is null or p_path !~ '^/v2/(account|account/configurations|clock|positions|orders|orders\?[A-Za-z0-9=&,._:%-]*|orders:by_client_order_id\?client_order_id=[A-Za-z0-9._:-]{1,128}|orders/[0-9a-f-]{36}|calendar\?[A-Za-z0-9=&._:-]*|assets/[A-Z0-9./-]{1,20}|account/activities/FILL\?[A-Za-z0-9=&,._:%-]*)$' then
    raise exception 'REFUSED: path is not on the paper read allowlist';
  end if;
  return private.alpaca_http('GET', 'https://paper-api.alpaca.markets' || p_path, null);
end;
$function$
