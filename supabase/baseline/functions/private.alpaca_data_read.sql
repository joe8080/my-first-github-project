CREATE OR REPLACE FUNCTION private.alpaca_data_read(p_path text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_path is null
     or p_path !~ '^/v2/stocks/(quotes/latest|trades/latest|bars/latest|snapshots|bars)\?[A-Za-z0-9=&,._:%-]+$'
     or p_path !~ '[?&]feed=(iex|sip|delayed_sip)(&|$)' then
    raise exception 'REFUSED: market-data path must be allowlisted and must name the feed explicitly (iex, sip or delayed_sip)';
  end if;
  return private.alpaca_http('GET', 'https://data.alpaca.markets' || p_path, null);
end;
$function$
