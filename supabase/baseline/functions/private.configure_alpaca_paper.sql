CREATE OR REPLACE FUNCTION private.configure_alpaca_paper(p_key_id text, p_secret_key text, p_base_url text DEFAULT 'https://paper-api.alpaca.markets/v2'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_id uuid;
begin
  if p_key_id is null or length(trim(p_key_id)) < 10 then raise exception 'Invalid Alpaca API key ID'; end if;
  if left(trim(p_key_id), 2) <> 'PK' then raise exception 'REFUSED: not an Alpaca PAPER key (paper key IDs start with PK)'; end if;
  if p_secret_key is null or length(trim(p_secret_key)) < 20 then raise exception 'Invalid Alpaca API secret key'; end if;
  if p_base_url is null or p_base_url !~ '^https://paper-api\.alpaca\.markets/v2/?$' then raise exception 'REFUSED: only the PAPER base URL is accepted'; end if;

  select id into v_id from vault.secrets where name = 'ALPACA_PAPER_KEY_ID' limit 1;
  if v_id is null then
    perform vault.create_secret(trim(p_key_id), 'ALPACA_PAPER_KEY_ID', 'Alpaca PAPER trading key ID — paper account only');
  else
    perform vault.update_secret(v_id, trim(p_key_id), 'ALPACA_PAPER_KEY_ID', 'Alpaca PAPER trading key ID — rotated ' || to_char(now() at time zone 'Europe/London', 'DD Mon YYYY') || '; paper account only');
  end if;

  v_id := null;
  select id into v_id from vault.secrets where name = 'ALPACA_PAPER_SECRET' limit 1;
  if v_id is null then
    perform vault.create_secret(trim(p_secret_key), 'ALPACA_PAPER_SECRET', 'Alpaca PAPER trading secret — paper account only');
  else
    perform vault.update_secret(v_id, trim(p_secret_key), 'ALPACA_PAPER_SECRET', 'Alpaca PAPER trading secret — rotated ' || to_char(now() at time zone 'Europe/London', 'DD Mon YYYY') || '; paper account only');
  end if;

  return jsonb_build_object('ok', true, 'stored', jsonb_build_array('ALPACA_PAPER_KEY_ID', 'ALPACA_PAPER_SECRET'),
                            'next', 'run select private.alpaca_paper_identity(); to confirm the new key');
end;
$function$
