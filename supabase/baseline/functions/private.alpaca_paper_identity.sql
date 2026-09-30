CREATE OR REPLACE FUNCTION private.alpaca_paper_identity()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r jsonb;
  a jsonb;
  v_reasons text[] := '{}';
  v_acct text;
begin
  r := private.alpaca_paper_read('/v2/account');
  a := r->'body';
  if coalesce((r->>'ok')::boolean, false) is false then
    v_reasons := v_reasons || ('account endpoint failed: HTTP ' || coalesce(r->>'status', 'none') || ' ' || coalesce(r->>'error', a->>'message', ''));
  else
    v_acct := a->>'account_number';
    if v_acct is null or v_acct not like 'PA%' then v_reasons := v_reasons || 'account number is not a PAPER (PA) account'::text; end if;
    if coalesce(a->>'status', '') <> 'ACTIVE' then v_reasons := v_reasons || ('account status ' || coalesce(a->>'status', 'unknown')); end if;
    if coalesce((a->>'trading_blocked')::boolean, true) then v_reasons := v_reasons || 'trading_blocked'::text; end if;
    if coalesce((a->>'account_blocked')::boolean, true) then v_reasons := v_reasons || 'account_blocked'::text; end if;
    if coalesce((a->>'trade_suspended_by_user')::boolean, false) then v_reasons := v_reasons || 'trade_suspended_by_user'::text; end if;
    if coalesce(a->>'currency', '') <> 'USD' then v_reasons := v_reasons || 'unexpected currency'::text; end if;
  end if;
  return jsonb_build_object(
    'pass', cardinality(v_reasons) = 0,
    'checked_at', now(),
    'host', 'paper-api.alpaca.markets',
    'http_status', r->'status',
    'account_masked', case when v_acct is null then null else left(v_acct, 2) || repeat('*', greatest(length(v_acct) - 6, 0)) || right(v_acct, 4) end,
    'account_status', a->>'status',
    'trading_blocked', a->'trading_blocked',
    'account_blocked', a->'account_blocked',
    'shorting_enabled', a->'shorting_enabled',
    'options_trading_level', a->'options_trading_level',
    'multiplier', a->'multiplier',
    'equity', a->'equity',
    'last_equity', a->'last_equity',
    'cash', a->'cash',
    'buying_power', a->'buying_power',
    'long_market_value', a->'long_market_value',
    'short_market_value', a->'short_market_value',
    'reasons', to_jsonb(v_reasons));
end;
$function$
