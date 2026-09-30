CREATE OR REPLACE FUNCTION private.paper_run_diagnostic_order(p_symbol text, p_confirm text, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.paper_system_config;
  v_id jsonb; v_clock jsonb; v_quote jsonb; v_pos jsonb; r jsonb; v_get jsonb; v_cancel jsonb; v_after jsonb;
  v_sym text := upper(trim(p_symbol));
  v_bid numeric; v_limit numeric; v_qts timestamptz; v_qage numeric;
  v_coid text := 'mj-diag-' || to_char(clock_timestamp() at time zone 'UTC', 'YYYYMMDD-HH24MISS');
  v_reasons text[] := '{}';
  v_log jsonb := '[]'::jsonb;
  v_final jsonb;
  v_n int;
begin
  if p_confirm is distinct from 'RUN_ONE_PAPER_DIAGNOSTIC_ORDER' then raise exception 'confirmation phrase missing'; end if;
  if v_sym is null or v_sym !~ '^[A-Z0-9.]{1,10}$' then raise exception 'invalid symbol'; end if;
  select * into c from public.paper_system_config where system_key = 'MJ_PAPER_V1';
  if c.diagnostic_max_notional_usd is null then v_reasons := v_reasons || 'BLOCKED: no approved diagnostic test limit (diagnostic_max_notional_usd is NULL)'::text; end if;
  if not coalesce(c.new_orders_enabled, false) then v_reasons := v_reasons || 'kill switch engaged'::text; end if;
  if c.max_quote_age_seconds is null then v_reasons := v_reasons || 'max_quote_age_seconds not set'::text; end if;
  select count(*) into v_n from public.paper_orders where origin = 'EXTERNAL_POST_BASELINE' and reviewed_at is null;
  if v_n > 0 then v_reasons := v_reasons || 'unreviewed orders from outside the bridge'::text; end if;
  v_id := private.alpaca_paper_identity();
  if not coalesce((v_id->>'pass')::boolean, false) then v_reasons := v_reasons || 'paper identity failed'::text; end if;
  v_clock := private.alpaca_paper_read('/v2/clock');
  if not coalesce((v_clock->'body'->>'is_open')::boolean, false) then v_reasons := v_reasons || 'US regular session is not open'::text; end if;
  v_pos := private.alpaca_paper_read('/v2/positions');
  if not coalesce((v_pos->>'ok')::boolean, false) then v_reasons := v_reasons || 'positions lookup failed'::text;
  elsif exists (select 1 from jsonb_array_elements(v_pos->'body') e where upper(e->>'symbol') = v_sym) then v_reasons := v_reasons || 'symbol has an existing position; choose a symbol with none'::text; end if;
  v_quote := private.alpaca_data_read('/v2/stocks/quotes/latest?symbols=' || v_sym || '&feed=' || coalesce(c.market_data_feed, 'iex'));
  v_bid := (v_quote->'body'->'quotes'->v_sym->>'bp')::numeric;
  v_qts := (v_quote->'body'->'quotes'->v_sym->>'t')::timestamptz;
  v_qage := extract(epoch from clock_timestamp() - v_qts);
  if coalesce(v_bid, 0) <= 0 then v_reasons := v_reasons || 'no valid bid'::text; end if;
  if c.max_quote_age_seconds is not null and (v_qage is null or v_qage > c.max_quote_age_seconds) then v_reasons := v_reasons || 'quote is stale'::text; end if;
  v_limit := round(v_bid * 0.90, 2);
  if c.diagnostic_max_notional_usd is not null and v_limit > c.diagnostic_max_notional_usd then v_reasons := v_reasons || ('1 share at $' || v_limit || ' exceeds diagnostic limit'); end if;
  if cardinality(v_reasons) > 0 or coalesce(p_dry_run, true) then
    return jsonb_build_object('ok', cardinality(v_reasons) = 0, 'dry_run', coalesce(p_dry_run, true), 'blocked', cardinality(v_reasons) > 0,
                              'reasons', to_jsonb(v_reasons), 'would_submit', jsonb_build_object('symbol', v_sym, 'side', 'buy', 'qty', 1, 'type', 'limit', 'limit_price', v_limit, 'client_order_id', v_coid));
  end if;

  perform set_config('mj.paper_validated_submit', v_coid, true);
  r := private.alpaca_paper_submit_order(v_sym, 'buy', 1, null, 'limit', 'day', v_limit, null, v_coid, false, false);
  perform set_config('mj.paper_validated_submit', '', true);
  v_log := v_log || jsonb_build_object('step', 'submit', 'at', clock_timestamp(), 'ok', r->'ok', 'http', r->'status', 'broker_status', r->'order'->'status', 'order_id', r->'order'->'id', 'uncertain', r->'uncertain');
  perform pg_sleep(2);
  v_get := private.alpaca_paper_read('/v2/orders:by_client_order_id?client_order_id=' || v_coid);
  v_log := v_log || jsonb_build_object('step', 'lookup', 'at', clock_timestamp(), 'http', v_get->'status', 'broker_status', v_get->'body'->'status', 'filled_qty', v_get->'body'->'filled_qty');
  v_final := v_get->'body';
  if coalesce((v_get->>'ok')::boolean, false) and (v_get->'body'->>'status') not in ('filled','canceled','expired','rejected') then
    v_cancel := private.alpaca_http('DELETE', 'https://paper-api.alpaca.markets/v2/orders/' || (v_get->'body'->>'id'), null);
    v_log := v_log || jsonb_build_object('step', 'cancel', 'at', clock_timestamp(), 'http', v_cancel->'status');
    perform pg_sleep(2);
    v_after := private.alpaca_paper_read('/v2/orders:by_client_order_id?client_order_id=' || v_coid);
    v_log := v_log || jsonb_build_object('step', 'verify', 'at', clock_timestamp(), 'broker_status', v_after->'body'->'status', 'filled_qty', v_after->'body'->'filled_qty');
    v_final := v_after->'body';
  end if;
  if v_final is not null and v_final ? 'id' then perform private.paper_upsert_order(v_final); end if;
  perform private.paper_heartbeat('diagnostic_order',
    coalesce(v_final->>'status', '') = 'canceled' and coalesce((v_final->>'filled_qty')::numeric, 0) = 0,
    jsonb_build_object('client_order_id', v_coid, 'log', v_log),
    'diagnostic ended with status ' || coalesce(v_final->>'status', 'unknown') || ', filled_qty ' || coalesce(v_final->>'filled_qty', '?'));
  return jsonb_build_object('ok', coalesce(v_final->>'status', '') = 'canceled', 'client_order_id', v_coid, 'final_status', v_final->'status',
                            'filled_qty', v_final->'filled_qty', 'log', v_log,
                            'note', 'If filled_qty > 0 a diagnostic position exists: it is tagged DIAGNOSTIC in paper_orders and must be closed explicitly.');
end;
$function$
