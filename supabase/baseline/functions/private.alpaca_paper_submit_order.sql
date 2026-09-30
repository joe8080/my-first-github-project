CREATE OR REPLACE FUNCTION private.alpaca_paper_submit_order(p_symbol text, p_side text, p_qty numeric DEFAULT NULL::numeric, p_notional numeric DEFAULT NULL::numeric, p_order_type text DEFAULT 'market'::text, p_time_in_force text DEFAULT 'day'::text, p_limit_price numeric DEFAULT NULL::numeric, p_stop_price numeric DEFAULT NULL::numeric, p_client_order_id text DEFAULT NULL::text, p_extended_hours boolean DEFAULT false, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_payload jsonb;
  v_http jsonb;
  v_body jsonb;
  v_audit_id uuid;
  v_symbol text := upper(trim(p_symbol));
  v_side text := lower(trim(p_side));
  v_type text := lower(trim(p_order_type));
  v_tif text := lower(trim(p_time_in_force));
  v_coid text := nullif(trim(p_client_order_id), '');
begin
  if v_symbol is null or v_symbol !~ '^[A-Z0-9./-]{1,20}$' then raise exception 'Invalid symbol'; end if;
  if v_side not in ('buy','sell') then raise exception 'Side must be buy or sell'; end if;
  if v_type not in ('market','limit','stop','stop_limit') then raise exception 'Unsupported paper order type'; end if;
  if v_tif not in ('day','gtc','opg','cls','ioc','fok') then raise exception 'Unsupported time in force'; end if;
  if (p_qty is null and p_notional is null) or (p_qty is not null and p_notional is not null) then raise exception 'Provide exactly one of qty or notional'; end if;
  if p_qty is not null and p_qty <= 0 then raise exception 'qty must be positive'; end if;
  if p_notional is not null and p_notional <= 0 then raise exception 'notional must be positive'; end if;
  if p_notional is not null and p_notional > 25000 then raise exception 'Paper-order notional exceeds $25,000 safety cap'; end if;
  if v_type = 'limit' and p_limit_price is null then raise exception 'limit_price required for limit orders'; end if;
  if v_type = 'stop' and p_stop_price is null then raise exception 'stop_price required for stop orders'; end if;
  if v_type = 'stop_limit' and (p_stop_price is null or p_limit_price is null) then raise exception 'stop_price and limit_price required for stop_limit orders'; end if;
  if p_extended_hours and not (v_type = 'limit' and v_tif in ('day','gtc')) then raise exception 'Extended hours requires limit order with day or gtc time_in_force'; end if;
  if v_coid is not null and length(v_coid) > 128 then raise exception 'client_order_id too long'; end if;
  if not coalesce(p_dry_run, true) and v_coid is null then raise exception 'client_order_id is required for non-dry-run paper orders'; end if;

  v_payload := jsonb_build_object('symbol', v_symbol, 'side', v_side, 'type', v_type, 'time_in_force', v_tif,
                                  'extended_hours', coalesce(p_extended_hours, false));
  if p_qty is not null then v_payload := v_payload || jsonb_build_object('qty', p_qty::text); end if;
  if p_notional is not null then v_payload := v_payload || jsonb_build_object('notional', p_notional::text); end if;
  if p_limit_price is not null then v_payload := v_payload || jsonb_build_object('limit_price', p_limit_price::text); end if;
  if p_stop_price is not null then v_payload := v_payload || jsonb_build_object('stop_price', p_stop_price::text); end if;
  if v_coid is not null then v_payload := v_payload || jsonb_build_object('client_order_id', v_coid); end if;

  insert into private.alpaca_paper_order_audit(symbol, side, qty, notional, order_type, time_in_force, limit_price, stop_price,
                                               client_order_id, extended_hours, dry_run, request_payload)
  values (v_symbol, v_side, p_qty, p_notional, v_type, v_tif, p_limit_price, p_stop_price,
          v_coid, coalesce(p_extended_hours, false), coalesce(p_dry_run, true), v_payload)
  returning id into v_audit_id;

  if coalesce(p_dry_run, true) then
    return jsonb_build_object('ok', true, 'dry_run', true, 'paper_only', true, 'audit_id', v_audit_id, 'payload', v_payload);
  end if;

  v_http := private.alpaca_http('POST', 'https://paper-api.alpaca.markets/v2/orders', v_payload::text);

  if coalesce((v_http->>'transport_error')::boolean, false) then
    update private.alpaca_paper_order_audit
       set http_status = null,
           response_payload = jsonb_build_object('outcome', 'UNKNOWN', 'transport_error', true, 'error', v_http->>'error')
     where id = v_audit_id;
    return jsonb_build_object('ok', false, 'uncertain', true, 'paper_only', true, 'audit_id', v_audit_id,
                              'client_order_id', v_coid,
                              'next_step', 'Do NOT resubmit. Look up GET /v2/orders:by_client_order_id first (fn_reconcile_alpaca_orders).');
  end if;

  v_body := v_http->'body';
  update private.alpaca_paper_order_audit
     set http_status = (v_http->>'status')::int, alpaca_order_id = v_body->>'id', response_payload = v_body
   where id = v_audit_id;

  if not coalesce((v_http->>'ok')::boolean, false) then
    return jsonb_build_object('ok', false, 'paper_only', true, 'status', v_http->'status', 'audit_id', v_audit_id, 'body', v_body);
  end if;
  return jsonb_build_object('ok', true, 'paper_only', true, 'status', v_http->'status', 'audit_id', v_audit_id, 'order', v_body);
end;
$function$
