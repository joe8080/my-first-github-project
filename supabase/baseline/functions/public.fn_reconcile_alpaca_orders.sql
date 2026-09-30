CREATE OR REPLACE FUNCTION public.fn_reconcile_alpaca_orders()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_after timestamptz;
  v_page int := 0;
  r jsonb;
  o jsonb;
  v_n int := 0;
  v_total int := 0;
  v_origins jsonb := '{}'::jsonb;
  v_origin text;
  v_trades jsonb;
  v_ext int;
  v_capped boolean := false;
  v_err text;
begin
  if not pg_try_advisory_xact_lock(hashtext('mj_paper_order_reconcile')) then
    return jsonb_build_object('ok', false, 'skipped', 'another reconcile is running');
  end if;

  select least(min(submitted_at) filter (where status not in ('filled','canceled','expired','rejected','replaced','done_for_day')),
               max(submitted_at) - interval '1 day',
               now() - interval '3 days')
    into v_after from public.paper_orders;
  if not exists (select 1 from public.paper_orders) then
    v_after := timestamptz '2026-05-01 00:00:00+00';
  end if;

  loop
    v_page := v_page + 1;
    if v_page > 20 then v_capped := true; exit; end if;
    r := private.alpaca_paper_read('/v2/orders?status=all&limit=500&direction=asc&nested=false&after='
                                   || to_char(v_after at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
    if coalesce((r->>'ok')::boolean, false) is false then
      v_err := coalesce(r->>'error', r->'body'->>'message', 'orders request failed');
      perform private.paper_heartbeat('order_reconcile', false, jsonb_build_object('page', v_page, 'http_status', r->'status'), v_err);
      return jsonb_build_object('ok', false, 'http_status', r->'status', 'error', v_err);
    end if;
    v_n := jsonb_array_length(r->'body');
    for o in select * from jsonb_array_elements(r->'body') loop
      begin
        v_origin := private.paper_upsert_order(o);
        v_origins := jsonb_set(v_origins, array[v_origin], to_jsonb(coalesce((v_origins->>v_origin)::int, 0) + 1));
      exception when others then
        v_origins := jsonb_set(v_origins, array['errors'], to_jsonb(coalesce((v_origins->>'errors')::int, 0) + 1));
      end;
      v_after := greatest(v_after, (o->>'submitted_at')::timestamptz);
    end loop;
    v_total := v_total + v_n;
    exit when v_n < 500;
    v_after := v_after - interval '1 millisecond';
  end loop;

  v_trades := private.paper_reconcile_strategy_trades();
  select count(*) into v_ext from public.paper_orders where origin = 'EXTERNAL_POST_BASELINE' and reviewed_at is null;

  perform private.paper_heartbeat('order_reconcile',
    coalesce((v_origins->>'errors')::int, 0) = 0 and not v_capped,
    jsonb_build_object('orders_seen', v_total, 'pages', v_page, 'by_origin', v_origins, 'page_cap_hit', v_capped,
                       'external_post_baseline_orders', v_ext, 'strategy', v_trades),
    case when v_capped then 'page cap reached before end of history'
         when coalesce((v_origins->>'errors')::int, 0) > 0 then 'some orders failed to upsert' end);

  return jsonb_build_object('ok', not v_capped and coalesce((v_origins->>'errors')::int, 0) = 0, 'orders_seen', v_total,
                            'by_origin', v_origins, 'external_post_baseline_orders', v_ext, 'strategy', v_trades);
end;
$function$
