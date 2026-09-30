CREATE OR REPLACE FUNCTION private.alpaca_http(p_method text, p_url text, p_body text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_key text;
  v_sec text;
  v_resp extensions.http_response;
  v_body jsonb;
  v_t0 timestamptz := clock_timestamp();
begin
  if p_url is null or p_url !~ '^https://(paper-api|data)\.alpaca\.markets/v2/' then
    raise exception 'REFUSED: only https://paper-api.alpaca.markets and https://data.alpaca.markets are permitted';
  end if;
  if p_method not in ('GET','POST','DELETE') then
    raise exception 'REFUSED: unsupported HTTP method %', p_method;
  end if;
  if p_method <> 'GET' and p_url !~ '^https://paper-api\.alpaca\.markets/v2/' then
    raise exception 'REFUSED: write methods are only allowed against the PAPER trading API';
  end if;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'ALPACA_PAPER_KEY_ID' limit 1;
  select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'ALPACA_PAPER_SECRET' limit 1;
  if v_key is null or v_sec is null then
    raise exception 'REFUSED: Alpaca PAPER credentials are not configured in Vault';
  end if;
  if left(v_key, 2) <> 'PK' then
    raise exception 'REFUSED: configured Alpaca key is not a PAPER key';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');

  begin
    select * into v_resp
    from extensions.http((
      p_method,
      p_url,
      array[
        ('APCA-API-KEY-ID', v_key)::extensions.http_header,
        ('APCA-API-SECRET-KEY', v_sec)::extensions.http_header,
        ('Accept', 'application/json')::extensions.http_header
      ],
      case when p_body is null then null else 'application/json' end,
      p_body
    )::extensions.http_request);
  exception when others then
    return jsonb_build_object('ok', false, 'transport_error', true, 'status', null,
                              'error', left(sqlerrm, 300), 'url', p_url,
                              'elapsed_ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000));
  end;

  begin
    v_body := case when v_resp.content is null or length(v_resp.content) = 0 then null else v_resp.content::jsonb end;
  exception when others then
    v_body := to_jsonb(left(coalesce(v_resp.content, ''), 1000));
  end;

  return jsonb_build_object('ok', v_resp.status between 200 and 299, 'transport_error', false,
                            'status', v_resp.status, 'body', v_body, 'url', p_url,
                            'elapsed_ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000));
end;
$function$
