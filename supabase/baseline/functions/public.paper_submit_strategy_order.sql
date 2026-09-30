CREATE OR REPLACE FUNCTION public.paper_submit_strategy_order(p_trade_id uuid, p_limit_price numeric, p_client_order_id text, p_dry_run boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v jsonb;
  r jsonb;
  t public.paper_strategy_trades;
  v_coid text := nullif(trim(p_client_order_id), '');
  v_lookup jsonb;
  v_status int;
  v_qty numeric;
begin
  if not pg_try_advisory_xact_lock(hashtext('mj_paper_submit')) then
    return jsonb_build_object('ok', false, 'blocked', true, 'reasons', jsonb_build_array('another submission is in progress'));
  end if;
  select * into t from public.paper_strategy_trades where id = p_trade_id for update;
  v := private.paper_validate_strategy_order(p_trade_id, p_limit_price, v_coid);
  if not coalesce((v->>'pass')::boolean, false) then
    return jsonb_build_object('ok', false, 'blocked', true, 'dry_run', coalesce(p_dry_run, true), 'reasons', v->'reasons', 'checks', v->'checks');
  end if;
  if coalesce(p_dry_run, true) then
    return jsonb_build_object('ok', true, 'dry_run', true, 'would_submit', v->'order', 'checks', v->'checks');
  end if;

  v_qty := (v->'order'->>'qty')::numeric;
  update public.paper_strategy_trades set entry_client_order_id = v_coid, updated_at = now() where id = t.id;

  perform set_config('mj.paper_validated_submit', v_coid, true);
  r := private.alpaca_paper_submit_order(v->'order'->>'symbol', v->'order'->>'side', v_qty, null, 'limit', 'day',
                                         p_limit_price, null, v_coid, false, false);
  perform set_config('mj.paper_validated_submit', '', true);
  v_status := (r->>'status')::int;

  if coalesce((r->>'uncertain')::boolean, false)
     or (not coalesce((r->>'ok')::boolean, false) and (v_status is null or v_status >= 500 or v_status = 408)) then
    v_lookup := private.alpaca_paper_read('/v2/orders:by_client_order_id?client_order_id=' || v_coid);
    if coalesce((v_lookup->>'ok')::boolean, false) then
      r := jsonb_build_object('ok', true, 'recovered_after_uncertain_response', true, 'order', v_lookup->'body');
    else
      begin
        update public.paper_strategy_trades set status = 'ORDERED', updated_at = now() where id = t.id;
        insert into public.paper_trade_events(trade_id, event_type, detail, metadata)
        values (t.id, 'REVIEW', 'UNCERTAIN submission ' || v_coid || ': no definite broker answer. Do not resubmit; reconcile resolves it or flags it after 15 min.',
                jsonb_build_object('client_order_id', v_coid, 'rule', 'UNCERTAIN_SUBMISSION', 'bridge_response', r));
      exception when others then null;
      end;
      return r || jsonb_build_object('uncertain', true, 'trade_status', 'ORDERED (pending broker confirmation)');
    end if;
  end if;

  if coalesce((r->>'ok')::boolean, false) then
    begin
      update public.paper_strategy_trades set status = 'ORDERED', entry_order_id = r->'order'->>'id', updated_at = now() where id = t.id;
      insert into public.paper_trade_events(trade_id, event_type, price_usd, qty, order_id, detail, metadata)
      values (t.id, 'ORDER_SUBMITTED', p_limit_price, v_qty, r->'order'->>'id',
              'Validated Alpaca PAPER limit ' || (v->'order'->>'side') || ' ' || t.symbol || ' via paper_submit_strategy_order; broker status ' || coalesce(r->'order'->>'status', '?'),
              jsonb_build_object('client_order_id', v_coid, 'checks', v->'checks'));
      perform private.paper_upsert_order(r->'order');
    exception when others then
      r := r || jsonb_build_object('bookkeeping_error', sqlerrm, 'next_step', 'Order was sent. Run select public.fn_reconcile_alpaca_orders();');
    end;
  else
    update public.paper_strategy_trades set entry_client_order_id = null, updated_at = now() where id = t.id;
    insert into public.paper_trade_events(trade_id, event_type, detail, metadata)
    values (t.id, 'REJECT', 'Broker rejected submission ' || v_coid || ' (HTTP ' || coalesce(v_status::text, '?') || '): ' || coalesce(r->'body'->>'message', ''),
            jsonb_build_object('client_order_id', v_coid, 'bridge_response', r));
  end if;
  return r;
end;
$function$
