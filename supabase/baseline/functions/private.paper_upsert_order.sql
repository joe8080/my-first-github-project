CREATE OR REPLACE FUNCTION private.paper_upsert_order(p_o jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_baseline timestamptz;
  v_coid text := p_o->>'client_order_id';
  v_id text := p_o->>'id';
  v_origin text;
  v_trade uuid;
  v_has_audit boolean;
begin
  if v_id is null or v_coid is null then return 'skipped'; end if;
  select baseline_at into v_baseline from public.paper_system_config where system_key = 'MJ_PAPER_V1';
  v_has_audit := exists (select 1 from private.alpaca_paper_order_audit a where a.client_order_id = v_coid and not a.dry_run);
  v_origin := case
    when v_coid like 'mj-diag-%' and v_has_audit then 'DIAGNOSTIC'
    when v_coid like 'mj-%' and v_has_audit then 'MJ_BRIDGE'
    when v_baseline is not null and (p_o->>'submitted_at')::timestamptz < v_baseline then 'LEGACY_PRE_BASELINE'
    else 'EXTERNAL_POST_BASELINE' end;
  select t.id into v_trade from public.paper_strategy_trades t
   where t.entry_order_id = v_id or t.exit_order_id = v_id or t.entry_client_order_id = v_coid limit 1;

  insert into public.paper_orders as o (
    alpaca_order_id, client_order_id, origin, is_diagnostic, strategy_trade_id, symbol, asset_class, side, position_intent,
    order_type, order_class, time_in_force, qty, notional, limit_price, stop_price, extended_hours, status, filled_qty,
    filled_avg_price, submitted_at, filled_at, canceled_at, expired_at, failed_at, broker_updated_at, raw, last_synced_at)
  values (
    v_id, v_coid, v_origin, v_origin = 'DIAGNOSTIC', v_trade, p_o->>'symbol', p_o->>'asset_class', p_o->>'side', p_o->>'position_intent',
    p_o->>'type', nullif(p_o->>'order_class', ''), p_o->>'time_in_force', (p_o->>'qty')::numeric, (p_o->>'notional')::numeric,
    (p_o->>'limit_price')::numeric, (p_o->>'stop_price')::numeric, (p_o->>'extended_hours')::boolean, p_o->>'status',
    (p_o->>'filled_qty')::numeric, (p_o->>'filled_avg_price')::numeric, (p_o->>'submitted_at')::timestamptz,
    (p_o->>'filled_at')::timestamptz, (p_o->>'canceled_at')::timestamptz, (p_o->>'expired_at')::timestamptz,
    (p_o->>'failed_at')::timestamptz, (p_o->>'updated_at')::timestamptz, p_o, now())
  on conflict (alpaca_order_id) do update set
    origin = excluded.origin,
    is_diagnostic = excluded.is_diagnostic,
    strategy_trade_id = coalesce(excluded.strategy_trade_id, o.strategy_trade_id),
    status = excluded.status,
    filled_qty = excluded.filled_qty,
    filled_avg_price = excluded.filled_avg_price,
    filled_at = excluded.filled_at,
    canceled_at = excluded.canceled_at,
    expired_at = excluded.expired_at,
    failed_at = excluded.failed_at,
    broker_updated_at = excluded.broker_updated_at,
    raw = excluded.raw,
    last_synced_at = now()
  where o.broker_updated_at is null or excluded.broker_updated_at >= o.broker_updated_at;
  return v_origin;
end;
$function$
