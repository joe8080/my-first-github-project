CREATE OR REPLACE FUNCTION public.paper_kill_switch_engage(p_reason text, p_by text DEFAULT 'operator'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update public.paper_system_config
     set new_orders_enabled = false, kill_switch_reason = left(coalesce(p_reason, 'engaged'), 500),
         kill_switch_changed_at = now(), kill_switch_changed_by = left(coalesce(p_by, 'operator'), 80), updated_at = now()
   where system_key = 'MJ_PAPER_V1';
  return (select jsonb_build_object('new_orders_enabled', new_orders_enabled, 'reason', kill_switch_reason, 'at', kill_switch_changed_at)
            from public.paper_system_config where system_key = 'MJ_PAPER_V1');
end;
$function$
