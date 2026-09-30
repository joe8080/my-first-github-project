CREATE OR REPLACE FUNCTION public.fn_paper_health_check()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.paper_system_config;
  v_id jsonb; v_clock jsonb; v_q jsonb; v_rec jsonb;
  v_open boolean;
  v_qts timestamptz; v_qage numeric; v_qlimit int;
  v_md_ok boolean;
  v_prev text;
  h record;
  v_overall text;
begin
  begin
    select * into c from public.paper_system_config where system_key = 'MJ_PAPER_V1';

    v_id := private.alpaca_paper_identity();
    perform private.paper_heartbeat('identity', coalesce((v_id->>'pass')::boolean, false), v_id, v_id->>'reasons');

    v_clock := private.alpaca_paper_read('/v2/clock');
    v_open := coalesce((v_clock->'body'->>'is_open')::boolean, false);
    perform private.paper_heartbeat('clock', coalesce((v_clock->>'ok')::boolean, false),
                                    coalesce(v_clock->'body', '{}'::jsonb) || jsonb_build_object('http_status', v_clock->'status'),
                                    coalesce(v_clock->>'error', 'clock request failed'));

    v_q := private.alpaca_data_read('/v2/stocks/quotes/latest?symbols=SPY&feed=' || coalesce(c.market_data_feed, 'iex'));
    v_qts := (v_q->'body'->'quotes'->'SPY'->>'t')::timestamptz;
    v_qage := extract(epoch from clock_timestamp() - v_qts);
    v_qlimit := coalesce(c.max_quote_age_seconds, 120);
    v_md_ok := coalesce((v_q->>'ok')::boolean, false) and v_qts is not null and (not v_open or v_qage <= v_qlimit);
    perform private.paper_heartbeat('market_data', v_md_ok,
      jsonb_build_object('feed', c.market_data_feed, 'symbol', 'SPY', 'http_status', v_q->'status', 'quote_ts', v_qts,
                         'quote_age_s', round(v_qage), 'session_open', v_open, 'freshness_limit_s', v_qlimit,
                         'delay', case when c.market_data_feed = 'iex' then 'real-time, IEX venue only (partial volume, not NBBO)' else 'real-time consolidated SIP' end,
                         'stale_expected', not v_open),
      case when not coalesce((v_q->>'ok')::boolean, false) then coalesce(v_q->>'error', v_q->'body'->>'message', 'quote request failed')
           when v_open and v_qage > v_qlimit then 'quote stale during open session (' || round(v_qage) || 's)' end);

    v_rec := public.fn_reconcile_alpaca_orders();

    select * into h from public.v_paper_system_health;
    v_overall := coalesce(h.overall_health, 'FAILING');

    select details->>'overall' into v_prev from public.paper_system_heartbeat where component = 'health_check';
    perform private.paper_heartbeat('health_check', v_overall = 'HEALTHY',
                                    jsonb_build_object('overall', v_overall, 'problems', h.health_problems, 'blocked', h.blocked_reasons),
                                    array_to_string(h.health_problems, '; '));

    insert into public.agent_ops_metrics(as_of_date, domain, metric_key, metric_value, metric_text, unit, direction, source_agent, notes)
    values
      (current_date, 'paper_trading', 'paper_health_ok', case when v_overall = 'HEALTHY' then 1 else 0 end, v_overall, 'bool', 'up_good', 'paper_health_check', array_to_string(h.health_problems, '; ')),
      (current_date, 'paper_trading', 'paper_new_orders_enabled', case when coalesce(c.new_orders_enabled, false) then 1 else 0 end, h.execution_state, 'bool', 'watch', 'paper_health_check', array_to_string(h.blocked_reasons, '; ')),
      (current_date, 'paper_trading', 'paper_open_orders', h.open_orders, null, 'count', 'watch', 'paper_health_check', null),
      (current_date, 'paper_trading', 'paper_minutes_since_account_sync', h.account_sync_age_minutes, to_char(h.last_account_sync_at at time zone 'Europe/London', 'YYYY-MM-DD HH24:MI "London"'), 'minutes', 'down_good', 'paper_health_check', null)
    on conflict (as_of_date, domain, metric_key) do update
      set metric_value = excluded.metric_value, metric_text = excluded.metric_text, notes = excluded.notes, created_at = now();

    if v_prev is distinct from v_overall then
      insert into public.agent_ops_runs(agent_key, run_type, checklist, result, summary, metrics)
      values ('paper_trading', 'paper_health_check', 'Alpaca PAPER health', case when v_overall = 'HEALTHY' then 'PASS' else 'FAIL' end,
              'Paper health changed ' || coalesce(v_prev, 'none') || ' -> ' || v_overall || '. ' || coalesce(array_to_string(h.health_problems, '; '), ''),
              jsonb_build_object('execution_state', h.execution_state, 'open_orders', h.open_orders));
    end if;

    if v_overall = 'FAILING' and not exists (
         select 1 from public.alerts_log where alert_type = 'PAPER_HEALTH' and acknowledged_at is null and alert_timestamp > now() - interval '24 hours') then
      insert into public.alerts_log(agent_source, alert_type, severity, headline, detail, action_required)
      values ('paper_health_check', 'PAPER_HEALTH', 'red', 'Alpaca PAPER system failing', left(coalesce(array_to_string(h.health_problems, '; '), 'unknown'), 900), true);
    end if;

    return jsonb_build_object('overall', v_overall, 'problems', h.health_problems, 'execution_state', h.execution_state,
                              'blocked', h.blocked_reasons, 'reconcile', v_rec);
  exception when others then
    perform private.paper_heartbeat('health_check', false, jsonb_build_object('overall', 'FAILING', 'error', left(sqlerrm, 300)),
                                    'health check crashed: ' || left(sqlerrm, 300));
    if not exists (select 1 from public.alerts_log where alert_type = 'PAPER_HEALTH' and acknowledged_at is null and alert_timestamp > now() - interval '24 hours') then
      insert into public.alerts_log(agent_source, alert_type, severity, headline, detail, action_required)
      values ('paper_health_check', 'PAPER_HEALTH', 'red', 'Alpaca PAPER health check crashed', left(sqlerrm, 900), true);
    end if;
    return jsonb_build_object('overall', 'FAILING', 'error', sqlerrm);
  end;
end;
$function$
