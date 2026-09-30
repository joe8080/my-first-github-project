CREATE OR REPLACE FUNCTION private.paper_reconcile_strategy_trades()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  t record;
  e record;
  x record;
  v_changes int := 0;
  v_discrepancies jsonb := '[]'::jsonb;
  v_pnl numeric;
begin
  for t in select * from public.paper_strategy_trades where system_key = 'MJ_PAPER_V1' loop
    select * into e from public.paper_orders
     where alpaca_order_id = t.entry_order_id
        or (t.entry_order_id is null and t.entry_client_order_id is not null and client_order_id = t.entry_client_order_id)
     limit 1;
    select * into x from public.paper_orders where alpaca_order_id = t.exit_order_id;

    if t.entry_order_id is null and e.alpaca_order_id is not null then
      update public.paper_strategy_trades set entry_order_id = e.alpaca_order_id, updated_at = now() where id = t.id;
      insert into public.paper_trade_events(trade_id, event_type, order_id, detail, metadata)
      values (t.id, 'REVIEW', e.alpaca_order_id, 'Uncertain submission resolved: broker order found by client_order_id.',
              jsonb_build_object('source', 'fn_reconcile_alpaca_orders', 'client_order_id', t.entry_client_order_id));
      v_changes := v_changes + 1;
    end if;

    if e.alpaca_order_id is not null and t.status in ('ORDERED','PARTIAL') then
      if e.status = 'filled' or (e.status in ('canceled','expired','done_for_day','rejected') and coalesce(e.filled_qty,0) > 0) then
        update public.paper_strategy_trades
           set status = 'OPEN', opened_at = coalesce(e.filled_at, now()), entry_price_usd = e.filled_avg_price,
               qty = e.filled_qty, updated_at = now()
         where id = t.id;
        insert into public.paper_trade_events(trade_id, event_type, price_usd, qty, order_id, detail, metadata)
        select t.id, 'FILL', e.filled_avg_price, e.filled_qty, e.alpaca_order_id,
               'Broker-reconciled entry fill (status ' || e.status || ').', jsonb_build_object('source','fn_reconcile_alpaca_orders')
        where not exists (select 1 from public.paper_trade_events where trade_id = t.id and event_type = 'FILL' and order_id = e.alpaca_order_id);
        v_changes := v_changes + 1;
      elsif e.status = 'partially_filled' and t.status = 'ORDERED' then
        update public.paper_strategy_trades set status = 'PARTIAL', updated_at = now() where id = t.id;
        v_changes := v_changes + 1;
      elsif e.status in ('canceled','expired','done_for_day') and coalesce(e.filled_qty,0) = 0 then
        update public.paper_strategy_trades set status = 'CANCELLED', closed_at = coalesce(e.canceled_at, e.expired_at, now()),
               exit_reason = coalesce(exit_reason, 'Broker: entry order ' || e.status || ' with zero fill'), updated_at = now()
         where id = t.id;
        insert into public.paper_trade_events(trade_id, event_type, order_id, detail, metadata)
        select t.id, 'CANCEL', e.alpaca_order_id, 'Broker-reconciled: entry order ' || e.status || ', zero fill.', jsonb_build_object('source','fn_reconcile_alpaca_orders')
        where not exists (select 1 from public.paper_trade_events where trade_id = t.id and event_type = 'CANCEL' and order_id = e.alpaca_order_id);
        v_changes := v_changes + 1;
      elsif e.status = 'rejected' then
        update public.paper_strategy_trades set status = 'REJECTED', closed_at = coalesce(e.failed_at, now()),
               exit_reason = coalesce(exit_reason, 'Broker rejected entry order'), updated_at = now()
         where id = t.id;
        insert into public.paper_trade_events(trade_id, event_type, order_id, detail, metadata)
        select t.id, 'REJECT', e.alpaca_order_id, 'Broker-reconciled: entry order rejected.', jsonb_build_object('source','fn_reconcile_alpaca_orders')
        where not exists (select 1 from public.paper_trade_events where trade_id = t.id and event_type = 'REJECT' and order_id = e.alpaca_order_id);
        v_changes := v_changes + 1;
      elsif e.status = 'replaced' then
        v_discrepancies := v_discrepancies || jsonb_build_object('trade_id', t.id, 'symbol', t.symbol, 'issue', 'entry order was replaced; link the replacement order manually');
      end if;
    end if;

    if x.alpaca_order_id is not null and t.status = 'OPEN' and t.entry_price_usd is not null then
      if x.status = 'filled' then
        v_pnl := case when t.side = 'LONG' then (x.filled_avg_price - t.entry_price_usd) * x.filled_qty
                      else (t.entry_price_usd - x.filled_avg_price) * x.filled_qty end;
        update public.paper_strategy_trades
           set status = case when x.filled_qty >= t.qty then 'CLOSED' else 'OPEN' end,
               closed_at = case when x.filled_qty >= t.qty then coalesce(x.filled_at, now()) end,
               exit_price_usd = x.filled_avg_price,
               realised_pnl_usd = v_pnl,
               realised_r_multiple = case when coalesce(t.initial_risk_usd,0) > 0 then round(v_pnl / t.initial_risk_usd, 2) end,
               updated_at = now()
         where id = t.id;
        insert into public.paper_trade_events(trade_id, event_type, price_usd, qty, order_id, detail, metadata)
        select t.id, 'CLOSE', x.filled_avg_price, x.filled_qty, x.alpaca_order_id, 'Broker-reconciled exit fill.', jsonb_build_object('source','fn_reconcile_alpaca_orders')
        where not exists (select 1 from public.paper_trade_events where trade_id = t.id and event_type = 'CLOSE' and order_id = x.alpaca_order_id);
        v_changes := v_changes + 1;
      elsif coalesce(x.filled_qty, 0) > 0 and x.filled_qty < t.qty then
        v_discrepancies := v_discrepancies || jsonb_build_object('trade_id', t.id, 'symbol', t.symbol, 'issue', 'partial exit (' || x.filled_qty || ' of ' || t.qty || ', order ' || x.status || ') needs manual review');
      end if;
    end if;

    if e.alpaca_order_id is not null and t.status in ('CANCELLED','REJECTED') and coalesce(e.filled_qty,0) > 0 then
      v_discrepancies := v_discrepancies || jsonb_build_object('trade_id', t.id, 'symbol', t.symbol, 'issue', 'DB says ' || t.status || ' but broker shows filled_qty ' || e.filled_qty);
    end if;
    if t.status in ('ORDERED','PARTIAL','OPEN') and e.alpaca_order_id is null then
      if t.entry_order_id is not null then
        v_discrepancies := v_discrepancies || jsonb_build_object('trade_id', t.id, 'symbol', t.symbol, 'issue', 'entry order id not found at broker');
      elsif t.updated_at < now() - interval '15 minutes' then
        v_discrepancies := v_discrepancies || jsonb_build_object('trade_id', t.id, 'symbol', t.symbol, 'issue', 'uncertain submission: no broker order for client_order_id ' || coalesce(t.entry_client_order_id, '?') || ' after 15 min');
      end if;
    end if;
  end loop;
  return jsonb_build_object('trade_updates', v_changes, 'discrepancies', v_discrepancies);
end;
$function$
