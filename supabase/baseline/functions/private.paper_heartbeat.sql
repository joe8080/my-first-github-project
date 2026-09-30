CREATE OR REPLACE FUNCTION private.paper_heartbeat(p_component text, p_ok boolean, p_details jsonb, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into public.paper_system_heartbeat as h (component, ok, last_run_at, last_ok_at, last_error_at, last_error, details, updated_at)
  values (p_component, p_ok, now(), case when p_ok then now() end, case when not p_ok then now() end,
          case when not p_ok then left(p_error, 500) end, p_details, now())
  on conflict (component) do update set
    ok = excluded.ok,
    last_run_at = excluded.last_run_at,
    last_ok_at = coalesce(excluded.last_ok_at, h.last_ok_at),
    last_error_at = coalesce(excluded.last_error_at, h.last_error_at),
    last_error = case when excluded.ok then h.last_error else excluded.last_error end,
    details = excluded.details,
    updated_at = now();
$function$
