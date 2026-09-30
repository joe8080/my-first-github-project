CREATE OR REPLACE FUNCTION private.alpaca_paper_get(p_resource text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_key_id text;
  v_secret text;
  v_resp extensions.http_response;
begin
  if p_resource not in ('account','positions','orders') then
    raise exception 'Unsupported Alpaca resource';
  end if;

  select decrypted_secret into v_key_id from vault.decrypted_secrets
  where name in ('ALPACA_PAPER_KEY_ID','alpaca_paper_api_key_id')
  order by case when name='ALPACA_PAPER_KEY_ID' then 0 else 1 end limit 1;

  select decrypted_secret into v_secret from vault.decrypted_secrets
  where name in ('ALPACA_PAPER_SECRET','alpaca_paper_api_secret_key')
  order by case when name='ALPACA_PAPER_SECRET' then 0 else 1 end limit 1;

  if v_key_id is null or v_secret is null then
    raise exception 'Alpaca paper credentials are not configured in Vault';
  end if;

  select * into v_resp
  from extensions.http((
    'GET',
    'https://paper-api.alpaca.markets/v2/' || p_resource,
    array[
      ('APCA-API-KEY-ID', v_key_id)::extensions.http_header,
      ('APCA-API-SECRET-KEY', v_secret)::extensions.http_header,
      ('Accept', 'application/json')::extensions.http_header
    ],
    null,
    null
  )::extensions.http_request);

  return jsonb_build_object(
    'ok', v_resp.status between 200 and 299,
    'paper_only', true,
    'status', v_resp.status,
    case when v_resp.status between 200 and 299 then 'data' else 'body' end,
    case when v_resp.content is null then null else v_resp.content::jsonb end
  );
end;
$function$
