CREATE OR REPLACE FUNCTION private.paper_kill_switch_release(p_confirm text, p_reason text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.paper_system_config;
  v_id jsonb;
  v_rec public.paper_system_heartbeat;
  v_n int;
  v_reasons text[] := '{}';
begin
  if p_confirm is distinct from 'I_APPROVE_NEW_PAPER_ORDERS' then
    raise exception 'Release refused: confirmation phrase missing';
  end if;
  select * into c from public.paper_system_config where system_key = 'MJ_PAPER_V1';
  if c.permitted_strategy_tags is null or cardinality(c.permitted_strategy_tags) = 0 then v_reasons := v_reasons || 'permitted_strategy_tags not set'::text; end if;
  if c.permitted_asset_classes is null or cardinality(c.permitted_asset_classes) = 0 then v_reasons := v_reasons || 'permitted_asset_classes not set'::text; end if;
  if c.max_quote_age_seconds is null then v_reasons := v_reasons || 'max_quote_age_seconds not set'::text; end if;
  if c.min_reward_risk is null then v_reasons := v_reasons || 'min_reward_risk not set'::text; end if;
  if c.market_data_feed is null then v_reasons := v_reasons || 'market_data_feed not set'::text; end if;
  v_id := private.alpaca_paper_identity();
  if not coalesce((v_id->>'pass')::boolean, false) then v_reasons := v_reasons || ('paper identity check failed: ' || coalesce(v_id->>'reasons', '')); end if;
  perform public.fn_reconcile_alpaca_orders();
  select * into v_rec from public.paper_system_heartbeat where component = 'order_reconcile';
  if not coalesce(v_rec.ok, false) or v_rec.last_ok_at < now() - interval '5 minutes' then v_reasons := v_reasons || 'order reconciliation not passing'::text; end if;
  if jsonb_array_length(coalesce(v_rec.details->'strategy'->'discrepancies', '[]'::jsonb)) > 0 then v_reasons := v_reasons || 'broker/DB discrepancies open'::text; end if;
  select count(*) into v_n from public.paper_orders where origin = 'EXTERNAL_POST_BASELINE' and reviewed_at is null;
  if v_n > 0 then v_reasons := v_reasons || (v_n || ' unreviewed post-baseline orders came from outside the bridge — resolve the other executor first'); end if;
  if cardinality(v_reasons) > 0 then
    return jsonb_build_object('released', false, 'reasons', to_jsonb(v_reasons));
  end if;
  update public.paper_system_config
     set new_orders_enabled = true, kill_switch_reason = left(coalesce(p_reason, 'released'), 500),
         kill_switch_changed_at = now(), kill_switch_changed_by = left(coalesce(p_by, 'Joe'), 80), updated_at = now()
   where system_key = 'MJ_PAPER_V1';
  return jsonb_build_object('released', true, 'note', 'Kill switch released. Strategy orders still also require status = PAPER_VALIDATION.');
end;
$function$
