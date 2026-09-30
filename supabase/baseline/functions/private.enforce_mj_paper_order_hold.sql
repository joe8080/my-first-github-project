CREATE OR REPLACE FUNCTION private.enforce_mj_paper_order_hold()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_status text;
  v_enabled boolean;
begin
  if coalesce(new.dry_run, false) then
    return new;
  end if;

  select status, new_orders_enabled into v_status, v_enabled
    from public.paper_system_config where system_key = 'MJ_PAPER_V1';

  if not coalesce(v_enabled, false) then
    raise exception 'KILL SWITCH ENGAGED: new Alpaca paper orders are disabled (paper_system_config.new_orders_enabled = false)';
  end if;
  if new.client_order_id is null or length(trim(new.client_order_id)) = 0 then
    raise exception 'client_order_id is required for every non-dry-run paper order';
  end if;
  if coalesce(current_setting('mj.paper_validated_submit', true), '') <> new.client_order_id then
    raise exception 'Direct bridge call refused: submit through public.paper_submit_strategy_order or private.paper_run_diagnostic_order';
  end if;
  if new.client_order_id not like 'mj-diag-%' and coalesce(v_status, 'MISSING') <> 'PAPER_VALIDATION' then
    raise exception 'MJ_PAPER_V1 order submission blocked by system status: %', coalesce(v_status, 'MISSING');
  end if;
  return new;
end;
$function$
