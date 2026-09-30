-- MJ_PAPER_V1: diagnostic isolation, execution hardening and strategy registry.
-- Applied 30 Sep 2026 to the "finance chief" Supabase project (migration name
-- mj_paper_diagnostic_isolation_20260930). Pre-change definitions are stored in
-- private.paper_config_backup (label pre_diagnostic_isolation_20260930).
-- No credentials appear here: Alpaca keys live only in Vault.

-- ---------------------------------------------------------------------------
-- 1. Configuration: separate strategy switch and a time-boxed diagnostic window
-- ---------------------------------------------------------------------------
alter table public.paper_system_config
  add column if not exists strategy_orders_enabled boolean not null default false,
  add column if not exists diagnostic_enabled boolean not null default false,
  add column if not exists diagnostic_expires_at timestamptz,
  add column if not exists diagnostic_asset_classes text[],
  add column if not exists diagnostic_max_quote_age_seconds integer,
  add column if not exists diagnostic_max_qty integer,
  add column if not exists diagnostic_settings jsonb;

create or replace function private.guard_paper_system_config()
 returns trigger
 language plpgsql
 set search_path to ''
as $function$
begin
  if current_user in ('postgres', 'supabase_admin') then
    return new;
  end if;
  if (coalesce(new.new_orders_enabled, false) and not coalesce(old.new_orders_enabled, false))
     or (coalesce(new.strategy_orders_enabled, false) and not coalesce(old.strategy_orders_enabled, false))
     or (coalesce(new.diagnostic_enabled, false) and not coalesce(old.diagnostic_enabled, false)) then
    raise exception 'Only the database owner can enable a paper order path (kill switch, strategy or diagnostic)';
  end if;
  if (new.permitted_strategy_tags, new.permitted_asset_classes, new.max_quote_age_seconds, new.diagnostic_max_notional_usd,
      new.min_reward_risk, new.market_data_feed, new.max_risk_per_trade_pct, new.exceptional_risk_per_trade_pct,
      new.max_single_position_pct, new.max_speculative_position_pct, new.max_concurrent_positions, new.max_gross_exposure_pct,
      new.max_short_gross_exposure_pct, new.daily_loss_circuit_breaker_pct, new.max_drawdown_limit_pct, new.baseline_at,
      new.status, new.diagnostic_expires_at, new.diagnostic_asset_classes, new.diagnostic_max_quote_age_seconds,
      new.diagnostic_max_qty, new.diagnostic_settings)
     is distinct from
     (old.permitted_strategy_tags, old.permitted_asset_classes, old.max_quote_age_seconds, old.diagnostic_max_notional_usd,
      old.min_reward_risk, old.market_data_feed, old.max_risk_per_trade_pct, old.exceptional_risk_per_trade_pct,
      old.max_single_position_pct, old.max_speculative_position_pct, old.max_concurrent_positions, old.max_gross_exposure_pct,
      old.max_short_gross_exposure_pct, old.daily_loss_circuit_breaker_pct, old.max_drawdown_limit_pct, old.baseline_at,
      old.status, old.diagnostic_expires_at, old.diagnostic_asset_classes, old.diagnostic_max_quote_age_seconds,
      old.diagnostic_max_qty, old.diagnostic_settings) then
    raise exception 'Risk limits, desk status and diagnostic settings can only be changed by the database owner';
  end if;
  return new;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. HTTP bridge: POST only to /v2/orders with a validated, audited client id;
--    DELETE only for one order id (no bulk cancel, no position close).
-- ---------------------------------------------------------------------------
create or replace function private.alpaca_http(p_method text, p_url text, p_body text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_key text;
  v_sec text;
  v_resp extensions.http_response;
  v_body jsonb;
  v_req jsonb;
  v_coid text;
  v_t0 timestamptz := clock_timestamp();
begin
  if p_url is null or p_url !~ '^https://(paper-api|data)\.alpaca\.markets/v2/' then
    raise exception 'REFUSED: only https://paper-api.alpaca.markets and https://data.alpaca.markets are permitted';
  end if;
  if p_method not in ('GET','POST','DELETE') then
    raise exception 'REFUSED: unsupported HTTP method %', p_method;
  end if;
  if p_method = 'POST' then
    if p_url <> 'https://paper-api.alpaca.markets/v2/orders' then
      raise exception 'REFUSED: POST is only allowed to the PAPER /v2/orders endpoint';
    end if;
    begin
      v_req := p_body::jsonb;
    exception when others then
      raise exception 'REFUSED: order body is not valid JSON';
    end;
    v_coid := v_req->>'client_order_id';
    if v_coid is null or v_coid <> coalesce(current_setting('mj.paper_validated_submit', true), '') then
      raise exception 'REFUSED: order POST without a validated client_order_id (use the strategy or diagnostic path)';
    end if;
    if not exists (select 1 from private.alpaca_paper_order_audit a where a.client_order_id = v_coid and not a.dry_run) then
      raise exception 'REFUSED: no audit row for client_order_id %', v_coid;
    end if;
  elsif p_method = 'DELETE' then
    if p_url !~ '^https://paper-api\.alpaca\.markets/v2/orders/[0-9a-f-]{36}$' then
      raise exception 'REFUSED: DELETE is only allowed for a single PAPER order id (no bulk cancel, no position close)';
    end if;
  end if;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'ALPACA_PAPER_KEY_ID' limit 1;
  select decrypted_secret into v_sec from vault.decrypted_secrets where name = 'ALPACA_PAPER_SECRET' limit 1;
  if v_key is null or v_sec is null then
    raise exception 'REFUSED: Alpaca PAPER credentials are not configured in Vault';
  end if;
  if left(v_key, 2) <> 'PK' then
    raise exception 'REFUSED: configured Alpaca key is not a PAPER key';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');

  begin
    select * into v_resp
    from extensions.http((
      p_method,
      p_url,
      array[
        ('APCA-API-KEY-ID', v_key)::extensions.http_header,
        ('APCA-API-SECRET-KEY', v_sec)::extensions.http_header,
        ('Accept', 'application/json')::extensions.http_header
      ],
      case when p_body is null then null else 'application/json' end,
      p_body
    )::extensions.http_request);
  exception when others then
    return jsonb_build_object('ok', false, 'transport_error', true, 'status', null,
                              'error', left(sqlerrm, 300), 'url', p_url,
                              'elapsed_ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000));
  end;

  begin
    v_body := case when v_resp.content is null or length(v_resp.content) = 0 then null else v_resp.content::jsonb end;
  exception when others then
    v_body := to_jsonb(left(coalesce(v_resp.content, ''), 1000));
  end;

  return jsonb_build_object('ok', v_resp.status between 200 and 299, 'transport_error', false,
                            'status', v_resp.status, 'body', v_body, 'url', p_url,
                            'elapsed_ms', round(extract(epoch from clock_timestamp() - v_t0) * 1000));
end;
$function$;

-- The two legacy helpers called the http extension directly; route them through
-- the bridge so every Alpaca call passes the same host/method/credential checks.
create or replace function private.alpaca_paper_cancel_order(p_order_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  r jsonb;
begin
  r := private.alpaca_http('DELETE', 'https://paper-api.alpaca.markets/v2/orders/' || p_order_id::text, null);
  return jsonb_build_object('ok', coalesce((r->>'ok')::boolean, false), 'paper_only', true, 'status', r->'status',
                            'transport_error', r->'transport_error', 'order_id', p_order_id,
                            'body', coalesce(r->'body', '{}'::jsonb));
end;
$function$;

create or replace function private.alpaca_paper_get(p_resource text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  r jsonb;
  v_ok boolean;
begin
  if p_resource not in ('account','positions','orders') then
    raise exception 'Unsupported Alpaca resource';
  end if;
  r := private.alpaca_http('GET', 'https://paper-api.alpaca.markets/v2/' || p_resource, null);
  v_ok := coalesce((r->>'ok')::boolean, false);
  return jsonb_build_object('ok', v_ok, 'paper_only', true, 'status', r->'status',
                            case when v_ok then 'data' else 'body' end, r->'body');
end;
$function$;

-- ---------------------------------------------------------------------------
-- 3. Strategy registry: a tag is not a policy. Nothing trades unless APPROVED.
-- ---------------------------------------------------------------------------
create table if not exists public.paper_strategy_registry (
  strategy_tag text primary key,
  side text,
  status text not null default 'PAUSED_UNVERIFIED'
    check (status in ('PAUSED_UNVERIFIED','PAUSED_INCOMPLETE','RETIRED','APPROVED')),
  entry_rule text,
  exit_rule text,
  sizing text,
  holding_period text,
  protective_orders text,
  monitoring text,
  failure_behaviour text,
  missing_decisions text[],
  evidence text,
  approved_by text,
  approved_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.paper_strategy_registry enable row level security;
revoke all on public.paper_strategy_registry from anon, authenticated;

create or replace function private.guard_paper_strategy_registry()
 returns trigger
 language plpgsql
 set search_path to ''
as $function$
begin
  if current_user in ('postgres', 'supabase_admin') then
    return new;
  end if;
  if new.status = 'APPROVED' and (tg_op = 'INSERT' or old.status is distinct from 'APPROVED') then
    raise exception 'Only the database owner can approve a paper strategy';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_guard_paper_strategy_registry on public.paper_strategy_registry;
create trigger trg_guard_paper_strategy_registry
  before insert or update on public.paper_strategy_registry
  for each row execute function private.guard_paper_strategy_registry();

-- Audit findings (30 Sep 2026). Recorded from paper_strategy_trades,
-- mj_decision_records and the validator code; nothing below is invented.
insert into public.paper_strategy_registry
  (strategy_tag, side, status, entry_rule, exit_rule, sizing, holding_period, protective_orders, monitoring, failure_behaviour, missing_decisions, evidence)
values
  ('LONG_MOMENTUM_BREAKOUT', 'LONG', 'PAUSED_INCOMPLETE',
   'NOT CODIFIED. Per-trade free text only ("Market buy on open/liquidity; accept fill near reference"). No signal job generates entries.',
   'NOT CODIFIED. Per-trade stop/target stored in paper_strategy_trades (e.g. BRZE stop 24.55 / T1 28.55). No exit order is ever placed.',
   'Validator caps only: risk <= 0.5% equity, notional <= 8%, gross <= 125%, R:R >= 2 at limit. Qty chosen manually per trade.',
   'Per-trade only (BRZE 24 Sep: 2-7 days). No rule.',
   'NONE. Entry is a plain DAY limit order; stop and target are database fields, not broker-held orders.',
   'None for exits. The 30-min health check reconciles order status only; nothing compares price to stop/target.',
   'If the operator is absent, an open position has no stop and no target execution: loss is unbounded until manual action.',
   array['entry signal definition','exit/stop execution method (broker bracket/OCO vs job)','position sizing rule','holding-period/time-stop rule','intraday monitoring cadence'],
   'paper_strategy_trades 24 Sep 2026 (BRZE, cancelled pre-fill); decision 706c9a8b'),
  ('LONG_PULLBACK_CONTINUATION', 'LONG', 'PAUSED_INCOMPLETE',
   'NOT CODIFIED. Per-trade free text only ("Market buy on open/liquidity"). No signal job.',
   'NOT CODIFIED. Per-trade stop/target only (CRM stop 231.80 / T1 249.20). No exit order is placed.',
   'Validator caps only (see LONG_MOMENTUM_BREAKOUT). The one sample (CRM 40 sh) breached the 8% single-position cap.',
   'Per-trade only (CRM: 2-8 days). No rule.',
   'NONE (no broker-held stop or target).',
   'None for exits.',
   'Unprotected position if unattended.',
   array['entry signal definition','exit/stop execution method','position sizing rule','holding-period rule','monitoring cadence'],
   'paper_strategy_trades 24 Sep 2026 (CRM, cancelled pre-fill); decision c05fe8de'),
  ('LONG_CATALYST', 'LONG', 'PAUSED_INCOMPLETE',
   'NOT CODIFIED. Only override-driven samples ("BUILD_SAMPLE OVERRIDE", "spec OVERRIDE").',
   'NOT CODIFIED. One sample used "close below entry x 0.92"; options sample used "premium -50%".',
   'Not defined.', 'Not defined.', 'NONE.', 'None.', 'Unprotected position if unattended.',
   array['entry rule','exit rule','sizing','holding period','protective orders','monitoring'],
   'paper_strategy_trades 10 Sep 2026 (all cancelled)'),
  ('SHORT_BREAKDOWN', 'SHORT', 'PAUSED_INCOMPLETE',
   'NOT CODIFIED. Per-trade free text only ("Market sell to open NEW short"). No signal job.',
   'NOT CODIFIED. Per-trade stop/target only (IWM stop 286.80 / T1 272.60). No buy-to-cover order is placed.',
   'Validator caps plus short checks (account shorting enabled, asset shortable and easy-to-borrow, whole shares, short gross <= 35%).',
   'Per-trade only (IWM: 1-5 days). No rule.',
   'NONE. A short with no broker-held stop has unlimited loss exposure.',
   'None for exits.',
   'Unprotected short if unattended.',
   array['entry signal definition','buy-to-cover stop execution method','sizing rule','holding-period rule','monitoring cadence','borrow/hard-to-borrow handling'],
   'paper_strategy_trades 24 Sep 2026 (IWM, cancelled pre-fill); decision 952df3d1'),
  ('SHORT_MEAN_REVERSION', 'SHORT', 'PAUSED_INCOMPLETE',
   'NOT CODIFIED. One override sample ("DEFENSIVE hedge OVERRIDE").', 'NOT CODIFIED ("rebuild if needed").',
   'Not defined.', 'Not defined.', 'NONE.', 'None.', 'Unprotected short if unattended.',
   array['entry rule','exit rule','sizing','holding period','protective orders','monitoring'],
   'paper_strategy_trades 10 Sep 2026 (cancelled)'),
  ('EVENT_SWING', 'LONG', 'PAUSED_INCOMPLETE',
   'NOT CODIFIED. Samples were a legacy trim and an options put ("DEFENSIVE OVERRIDE").', 'NOT CODIFIED ("premium -50 pct").',
   'Not defined.', 'Not defined.', 'NONE.', 'None.', 'Unprotected position if unattended.',
   array['entry rule','exit rule','sizing','holding period','protective orders','monitoring','whether options are in scope (currently equity-only)'],
   'paper_strategy_trades 10 Sep 2026 (cancelled)'),
  ('SAMPLE_DAILY', null, 'RETIRED',
   'Curriculum wrapper, not a strategy. Rejected under the MJ_PAPER_V1 mandate on 24 Sep 2026 (compliance hold).', null, null, null, null, null, null,
   array['not a strategy: do not re-enable'], 'paper_system_config notes 24 Sep 2026')
on conflict (strategy_tag) do nothing;

-- ---------------------------------------------------------------------------
-- 4. Diagnostic run log (kept separate from strategy performance)
-- ---------------------------------------------------------------------------
create table if not exists public.paper_diagnostic_runs (
  id bigserial primary key,
  phase text not null check (phase in ('rest','fill','close')),
  symbol text,
  client_order_id text,
  dry_run boolean not null,
  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  outcome text,
  ok boolean,
  reasons text[],
  steps jsonb not null default '[]'::jsonb,
  final_order jsonb,
  settings jsonb
);
alter table public.paper_diagnostic_runs enable row level security;
revoke all on public.paper_diagnostic_runs from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Order gate on the audit table (fires before any non-dry-run POST)
-- ---------------------------------------------------------------------------
create or replace function private.enforce_mj_paper_order_hold()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  c public.paper_system_config;
  t public.paper_strategy_trades;
begin
  if coalesce(new.dry_run, false) then
    return new;
  end if;

  select * into c from public.paper_system_config where system_key = 'MJ_PAPER_V1';

  if not coalesce(c.new_orders_enabled, false) then
    raise exception 'KILL SWITCH ENGAGED: new Alpaca paper orders are disabled (paper_system_config.new_orders_enabled = false)';
  end if;
  if new.client_order_id is null or length(trim(new.client_order_id)) = 0 then
    raise exception 'client_order_id is required for every non-dry-run paper order';
  end if;
  if coalesce(current_setting('mj.paper_validated_submit', true), '') <> new.client_order_id then
    raise exception 'Direct bridge call refused: submit through public.paper_submit_strategy_order or private.paper_diag_run';
  end if;
  if c.status is distinct from 'PAPER_VALIDATION' then
    raise exception 'MJ_PAPER_V1 order submission blocked by system status: %', coalesce(c.status, 'MISSING');
  end if;

  if new.client_order_id like 'mj-diag-%' then
    if coalesce(current_setting('mj.paper_diag_path', true), '') <> 'private.paper_diag_run' then
      raise exception 'Diagnostic client ids may only be submitted by private.paper_diag_run';
    end if;
    if not coalesce(c.diagnostic_enabled, false) or c.diagnostic_expires_at is null or c.diagnostic_expires_at <= now() then
      raise exception 'Diagnostic window is not armed or has expired (private.paper_diag_arm)';
    end if;
    if new.order_type <> 'limit' or new.time_in_force <> 'day' or coalesce(new.extended_hours, false) or new.notional is not null then
      raise exception 'Diagnostic orders must be whole-share DAY limit orders in the regular session';
    end if;
    if new.qty is null or new.qty > coalesce(c.diagnostic_max_qty, 0) then
      raise exception 'Diagnostic qty % exceeds diagnostic_max_qty %', new.qty, c.diagnostic_max_qty;
    end if;
    if new.side = 'buy' and new.qty * new.limit_price > coalesce(c.diagnostic_max_notional_usd, 0) then
      raise exception 'Diagnostic notional exceeds diagnostic_max_notional_usd';
    end if;
    return new;
  end if;

  if not coalesce(c.strategy_orders_enabled, false) then
    raise exception 'Strategy execution is disabled (strategy_orders_enabled = false); only the armed diagnostic path may submit';
  end if;
  select * into t from public.paper_strategy_trades where entry_client_order_id = new.client_order_id limit 1;
  if t.id is null then
    raise exception 'No MJ strategy trade owns client_order_id %', new.client_order_id;
  end if;
  if not exists (select 1 from public.paper_strategy_registry r where r.strategy_tag = t.strategy_tag and r.status = 'APPROVED') then
    raise exception 'Strategy % is not APPROVED in paper_strategy_registry', coalesce(t.strategy_tag, 'NULL');
  end if;
  return new;
end;
$function$;

-- Validator: report the same two strategy gates in dry runs.
do $do$
declare
  d text;
  v_anchor text := $a$  if c.permitted_strategy_tags is null or cardinality(c.permitted_strategy_tags) = 0 then v_reasons := v_reasons || 'DECISION NEEDED: permitted_strategy_tags not set'::text; end if;$a$;
begin
  d := pg_get_functiondef('private.paper_validate_strategy_order(uuid,numeric,text)'::regprocedure);
  if position('strategy_orders_enabled' in d) > 0 then
    return;
  end if;
  if position(v_anchor in d) = 0 then
    raise exception 'validator anchor not found; refusing to patch';
  end if;
  d := replace(d, v_anchor,
    $b$  if not coalesce(c.strategy_orders_enabled, false) then v_reasons := v_reasons || 'strategy execution disabled (strategy_orders_enabled = false; diagnostic-only validation phase)'::text; end if;
  if not exists (select 1 from public.paper_strategy_registry r where r.strategy_tag = t.strategy_tag and r.status = 'APPROVED') then v_reasons := v_reasons || ('strategy ' || coalesce(t.strategy_tag, 'NULL') || ' is not APPROVED in paper_strategy_registry'); end if;
$b$ || v_anchor);
  execute d;
end;
$do$;

-- ---------------------------------------------------------------------------
-- 6. Diagnostic path: arm / disarm / checks / run
-- ---------------------------------------------------------------------------
create or replace function public.paper_kill_switch_engage(p_reason text, p_by text default 'operator'::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  update public.paper_system_config
     set new_orders_enabled = false, diagnostic_enabled = false,
         kill_switch_reason = left(coalesce(p_reason, 'engaged'), 500),
         kill_switch_changed_at = now(), kill_switch_changed_by = left(coalesce(p_by, 'operator'), 80), updated_at = now()
   where system_key = 'MJ_PAPER_V1';
  return (select jsonb_build_object('new_orders_enabled', new_orders_enabled, 'diagnostic_enabled', diagnostic_enabled,
                                    'reason', kill_switch_reason, 'at', kill_switch_changed_at)
            from public.paper_system_config where system_key = 'MJ_PAPER_V1');
end;
$function$;

create or replace function private.paper_diag_arm(p_confirm text, p_minutes integer, p_by text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  c public.paper_system_config;
  v_until timestamptz;
begin
  if p_confirm is distinct from 'ARM_DIAGNOSTIC_ONLY' then raise exception 'confirmation phrase missing'; end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 120 then raise exception 'window must be 1-120 minutes'; end if;
  select * into c from public.paper_system_config where system_key = 'MJ_PAPER_V1' for update;
  if coalesce(c.strategy_orders_enabled, false) then
    raise exception 'refused: strategy execution is enabled; the diagnostic window only runs with strategies disabled';
  end if;
  if c.status is distinct from 'PAPER_VALIDATION' then raise exception 'refused: desk status is % (needs PAPER_VALIDATION)', c.status; end if;
  if c.diagnostic_max_notional_usd is null or c.diagnostic_max_quote_age_seconds is null
     or c.diagnostic_asset_classes is null or c.diagnostic_max_qty is null or c.diagnostic_settings is null then
    raise exception 'refused: diagnostic settings are incomplete';
  end if;
  v_until := now() + make_interval(mins => p_minutes);
  update public.paper_system_config
     set diagnostic_enabled = true, diagnostic_expires_at = v_until, new_orders_enabled = true,
         kill_switch_reason = 'Released for a DIAGNOSTIC-ONLY window until '
                              || to_char(v_until at time zone 'Europe/London', 'YYYY-MM-DD HH24:MI "London"')
                              || '; strategy_orders_enabled = false',
         kill_switch_changed_at = now(), kill_switch_changed_by = left(coalesce(p_by, 'operator'), 80), updated_at = now()
   where system_key = 'MJ_PAPER_V1';
  return jsonb_build_object('armed', true, 'expires_at_utc', v_until,
                            'expires_at_london', to_char(v_until at time zone 'Europe/London', 'YYYY-MM-DD HH24:MI:SS'));
end;
$function$;

create or replace function private.paper_diag_disarm(p_reason text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  update public.paper_system_config
     set diagnostic_enabled = false,
         diagnostic_expires_at = least(coalesce(diagnostic_expires_at, now()), now()),
         new_orders_enabled = case when coalesce(strategy_orders_enabled, false) then new_orders_enabled else false end,
         kill_switch_reason = 'Diagnostic window closed: ' || left(coalesce(p_reason, 'disarmed'), 400),
         kill_switch_changed_at = now(), kill_switch_changed_by = 'paper_diag_disarm', updated_at = now()
   where system_key = 'MJ_PAPER_V1';
  return (select jsonb_build_object('diagnostic_enabled', diagnostic_enabled, 'new_orders_enabled', new_orders_enabled,
                                    'reason', kill_switch_reason)
            from public.paper_system_config where system_key = 'MJ_PAPER_V1');
end;
$function$;

create or replace function private.paper_diag_expire()
 returns text
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if exists (select 1 from public.paper_system_config
              where system_key = 'MJ_PAPER_V1' and diagnostic_enabled and diagnostic_expires_at <= now()) then
    perform private.paper_diag_disarm('window expired');
    return 'disarmed';
  end if;
  return 'nothing to do';
end;
$function$;

create or replace function private.paper_diag_wait(p_coid text, p_until text, p_max_s integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  r jsonb;
  v_st text;
  i int := 0;
begin
  loop
    r := private.alpaca_paper_read('/v2/orders:by_client_order_id?client_order_id=' || p_coid);
    v_st := r->'body'->>'status';
    if coalesce((r->>'ok')::boolean, false) then
      if p_until = 'ack' and v_st is distinct from 'pending_new' then return r; end if;
      if v_st in ('filled','canceled','expired','rejected','done_for_day','replaced') then return r; end if;
    end if;
    i := i + 1;
    exit when i >= p_max_s;
    perform pg_sleep(1);
  end loop;
  return r;
end;
$function$;

create or replace function private.paper_diag_step(p_step text, r jsonb)
 returns jsonb
 language sql
 set search_path to ''
as $function$
  select jsonb_build_object(
    'step', p_step, 'at_utc', clock_timestamp(), 'http', r->'status', 'ok', r->'ok', 'transport_error', r->'transport_error',
    'order_id', r->'body'->>'id', 'broker_status', r->'body'->>'status', 'qty', r->'body'->>'qty',
    'filled_qty', r->'body'->>'filled_qty', 'filled_avg_price', r->'body'->>'filled_avg_price',
    'limit_price', r->'body'->>'limit_price', 'submitted_at', r->'body'->>'submitted_at',
    'filled_at', r->'body'->>'filled_at', 'canceled_at', r->'body'->>'canceled_at',
    'broker_updated_at', r->'body'->>'updated_at', 'message', r->'body'->>'message');
$function$;

create or replace function private.paper_diag_checks(p_symbol text, p_phase text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  c public.paper_system_config;
  v_sym text := upper(trim(p_symbol));
  v_reasons text[] := '{}';
  v_id jsonb; v_clock jsonb; v_asset jsonb; v_pos jsonb; v_open jsonb; v_q jsonb;
  v_bid numeric; v_ask numeric; v_qts timestamptz; v_qage numeric; v_spread_pct numeric;
  v_broker_qty numeric := 0; v_broker_side text;
  v_diag_net numeric; v_open_diag int := 0; v_open_sym int := 0; v_n int;
begin
  if v_sym is null or v_sym !~ '^[A-Z]{1,5}$' then raise exception 'invalid symbol (plain US equity ticker only)'; end if;
  if p_phase not in ('rest','fill','close') then raise exception 'unknown phase'; end if;
  select * into c from public.paper_system_config where system_key = 'MJ_PAPER_V1';

  if not coalesce(c.new_orders_enabled, false) then v_reasons := v_reasons || 'kill switch engaged'::text; end if;
  if c.status is distinct from 'PAPER_VALIDATION' then v_reasons := v_reasons || ('desk status ' || coalesce(c.status, 'MISSING')); end if;
  if coalesce(c.strategy_orders_enabled, false) then v_reasons := v_reasons || 'strategy execution is enabled (diagnostics run only with strategies disabled)'::text; end if;
  if not coalesce(c.diagnostic_enabled, false) or c.diagnostic_expires_at is null or c.diagnostic_expires_at <= now() then
    v_reasons := v_reasons || 'diagnostic window not armed or expired'::text;
  end if;
  if c.diagnostic_max_notional_usd is null or c.diagnostic_max_quote_age_seconds is null
     or c.diagnostic_asset_classes is null or c.diagnostic_max_qty is null then
    v_reasons := v_reasons || 'diagnostic settings incomplete'::text;
  end if;
  select count(*) into v_n from public.paper_orders where origin = 'EXTERNAL_POST_BASELINE' and reviewed_at is null;
  if v_n > 0 then v_reasons := v_reasons || 'unreviewed orders from outside the bridge'::text; end if;

  v_id := private.alpaca_paper_identity();
  if not coalesce((v_id->>'pass')::boolean, false) then v_reasons := v_reasons || ('paper identity failed: ' || coalesce(v_id->>'reasons', '')); end if;

  v_clock := private.alpaca_paper_read('/v2/clock');
  if not coalesce((v_clock->'body'->>'is_open')::boolean, false) then
    v_reasons := v_reasons || 'US regular session is not open (broker clock)'::text;
  end if;

  v_asset := private.alpaca_paper_read('/v2/assets/' || v_sym);
  if not coalesce((v_asset->>'ok')::boolean, false) then
    v_reasons := v_reasons || 'asset lookup failed'::text;
  else
    if not coalesce((v_asset->'body'->>'class') = any(c.diagnostic_asset_classes), false) then
      v_reasons := v_reasons || ('asset class ' || coalesce(v_asset->'body'->>'class', '?') || ' not permitted for diagnostics'); end if;
    if not coalesce((v_asset->'body'->>'tradable')::boolean, false) or coalesce(v_asset->'body'->>'status', '') <> 'active' then
      v_reasons := v_reasons || 'asset not tradable/active'::text; end if;
  end if;

  v_pos := private.alpaca_paper_read('/v2/positions');
  if not coalesce((v_pos->>'ok')::boolean, false) then
    v_reasons := v_reasons || 'positions lookup failed'::text;
  else
    select (e->>'qty')::numeric, e->>'side' into v_broker_qty, v_broker_side
      from jsonb_array_elements(v_pos->'body') e where upper(e->>'symbol') = v_sym;
    v_broker_qty := coalesce(v_broker_qty, 0);
  end if;

  v_open := private.alpaca_paper_read('/v2/orders?status=open&limit=500');
  if not coalesce((v_open->>'ok')::boolean, false) then
    v_reasons := v_reasons || 'open-orders lookup failed'::text;
  else
    select count(*) filter (where e->>'client_order_id' like 'mj-diag-%'), count(*) filter (where upper(e->>'symbol') = v_sym)
      into v_open_diag, v_open_sym from jsonb_array_elements(v_open->'body') e;
    if v_open_diag > 0 then v_reasons := v_reasons || 'another diagnostic order is still open (one at a time)'::text; end if;
    if v_open_sym > 0 then v_reasons := v_reasons || ('an open order already exists in ' || v_sym); end if;
  end if;

  v_diag_net := coalesce((select sum(case when side = 'buy' then coalesce(filled_qty, 0) else -coalesce(filled_qty, 0) end)
                            from public.paper_orders where origin = 'DIAGNOSTIC' and symbol = v_sym), 0);
  if p_phase in ('rest','fill') then
    if v_broker_qty <> 0 then v_reasons := v_reasons || ('a broker position in ' || v_sym || ' already exists (legacy or other): choose a symbol with none'); end if;
    if exists (select 1 from public.paper_orders where origin = 'DIAGNOSTIC' group by symbol
                having sum(case when side = 'buy' then coalesce(filled_qty, 0) else -coalesce(filled_qty, 0) end) <> 0) then
      v_reasons := v_reasons || 'a diagnostic position is still open: run the close phase first'::text;
    end if;
  else
    if v_diag_net <= 0 then v_reasons := v_reasons || 'no diagnostic-owned quantity to close'::text; end if;
    if v_broker_side is distinct from 'long' or v_broker_qty < v_diag_net then
      v_reasons := v_reasons || ('broker position (' || v_broker_qty || ') does not cover diagnostic qty ' || v_diag_net || ': manual review'); end if;
  end if;

  v_q := private.alpaca_data_read('/v2/stocks/quotes/latest?symbols=' || v_sym || '&feed=' || coalesce(c.market_data_feed, 'iex'));
  v_bid := (v_q->'body'->'quotes'->v_sym->>'bp')::numeric;
  v_ask := (v_q->'body'->'quotes'->v_sym->>'ap')::numeric;
  v_qts := (v_q->'body'->'quotes'->v_sym->>'t')::timestamptz;
  v_qage := extract(epoch from clock_timestamp() - v_qts);
  if not coalesce((v_q->>'ok')::boolean, false) or v_qts is null then
    v_reasons := v_reasons || 'quote unavailable'::text;
  else
    if v_qage > coalesce(c.diagnostic_max_quote_age_seconds, 0) or v_qage < -5 then
      v_reasons := v_reasons || ('quote stale or clock-skewed (' || round(v_qage) || 's; limit ' || coalesce(c.diagnostic_max_quote_age_seconds::text, '?') || 's)'); end if;
    if coalesce(v_bid, 0) <= 0 or coalesce(v_ask, 0) <= 0 or v_ask < v_bid then
      v_reasons := v_reasons || 'quote is not two-sided/valid'::text;
    else
      v_spread_pct := (v_ask - v_bid) / ((v_ask + v_bid) / 2) * 100;
      if v_spread_pct > 1.0 then v_reasons := v_reasons || ('spread ' || round(v_spread_pct, 2) || '% > 1%: not liquid enough for the diagnostic'); end if;
    end if;
  end if;

  return jsonb_build_object('pass', cardinality(v_reasons) = 0, 'reasons', to_jsonb(v_reasons), 'symbol', v_sym, 'phase', p_phase,
    'feed', c.market_data_feed, 'bid', v_bid, 'ask', v_ask, 'quote_ts', v_qts, 'quote_age_s', round(v_qage, 1),
    'spread_pct', round(v_spread_pct, 3), 'cash', (v_id->>'cash')::numeric, 'account', v_id->>'account_masked',
    'broker_qty', v_broker_qty, 'diag_net_qty', v_diag_net, 'session_open', v_clock->'body'->'is_open',
    'asset_class', v_asset->'body'->>'class', 'max_notional_usd', c.diagnostic_max_notional_usd, 'max_qty', c.diagnostic_max_qty,
    'max_quote_age_s', c.diagnostic_max_quote_age_seconds);
end;
$function$;

create or replace function private.paper_diag_run(p_phase text, p_symbol text, p_confirm text, p_dry_run boolean default true)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  c public.paper_system_config;
  chk jsonb;
  v_sym text := upper(trim(p_symbol));
  v_coid text;
  v_side text; v_qty numeric; v_limit numeric; v_bid numeric; v_ask numeric;
  v_run bigint;
  v_steps jsonb := '[]'::jsonb;
  v_reasons text[];
  r jsonb; v_final jsonb; v_outcome text; v_ok boolean; v_err text;
begin
  if p_confirm is distinct from 'RUN_ONE_PAPER_DIAGNOSTIC_ORDER' then raise exception 'confirmation phrase missing'; end if;
  if p_phase not in ('rest','fill','close') then raise exception 'phase must be rest, fill or close'; end if;
  if not pg_try_advisory_xact_lock(hashtext('mj_paper_diag')) then raise exception 'another diagnostic is running'; end if;

  select * into c from public.paper_system_config where system_key = 'MJ_PAPER_V1';
  chk := private.paper_diag_checks(v_sym, p_phase);
  v_reasons := array(select jsonb_array_elements_text(chk->'reasons'));
  v_bid := (chk->>'bid')::numeric;
  v_ask := (chk->>'ask')::numeric;
  v_coid := 'mj-diag-' || to_char(clock_timestamp() at time zone 'UTC', 'YYYYMMDD-HH24MISS') || '-' || p_phase;

  -- rest: 5% below bid so it rests unfilled; fill: marketable at ask + 0.2%; close: marketable at bid - 0.2%
  if p_phase = 'rest' then
    v_side := 'buy'; v_qty := 1; v_limit := round(v_bid * 0.95, 2);
  elsif p_phase = 'fill' then
    v_side := 'buy'; v_qty := 1; v_limit := round(v_ask * 1.002, 2);
  else
    v_side := 'sell'; v_qty := (chk->>'diag_net_qty')::numeric; v_limit := round(v_bid * 0.998, 2);
  end if;

  if v_limit is null or v_limit <= 0 then v_reasons := v_reasons || 'no valid limit price (quote missing)'::text; end if;
  if v_qty is null or v_qty <= 0 or v_qty <> trunc(v_qty) or v_qty > coalesce(c.diagnostic_max_qty, 0) then
    v_reasons := v_reasons || ('qty ' || coalesce(v_qty::text, 'null') || ' invalid or above diagnostic_max_qty'); end if;
  if v_side = 'buy' and v_limit * v_qty > coalesce(c.diagnostic_max_notional_usd, 0) then
    v_reasons := v_reasons || ('notional $' || round(v_limit * v_qty, 2) || ' exceeds the $' || coalesce(c.diagnostic_max_notional_usd::text, '?')
                               || ' diagnostic cap: choose a cheaper symbol (the cap is not raised)'); end if;
  if v_side = 'buy' and v_limit * v_qty > coalesce((chk->>'cash')::numeric, 0) then
    v_reasons := v_reasons || 'insufficient cash: diagnostic must not use margin'::text; end if;

  insert into public.paper_diagnostic_runs(phase, symbol, client_order_id, dry_run, settings)
  values (p_phase, v_sym, v_coid, coalesce(p_dry_run, true),
          jsonb_build_object('diagnostic_settings', c.diagnostic_settings, 'checks', chk,
                             'planned', jsonb_build_object('side', v_side, 'qty', v_qty, 'type', 'limit', 'time_in_force', 'day',
                                                           'limit_price', v_limit, 'notional', round(v_limit * v_qty, 2))))
  returning id into v_run;

  if cardinality(v_reasons) > 0 or coalesce(p_dry_run, true) then
    update public.paper_diagnostic_runs
       set finished_at = clock_timestamp(), reasons = v_reasons, ok = cardinality(v_reasons) = 0,
           outcome = case when cardinality(v_reasons) > 0 then 'BLOCKED' else 'DRY_RUN_PASS' end
     where id = v_run;
    return jsonb_build_object('run_id', v_run, 'dry_run', coalesce(p_dry_run, true), 'blocked', cardinality(v_reasons) > 0,
                              'reasons', to_jsonb(v_reasons), 'client_order_id', v_coid,
                              'would_submit', jsonb_build_object('symbol', v_sym, 'side', v_side, 'qty', v_qty, 'type', 'limit',
                                                                 'time_in_force', 'day', 'limit_price', v_limit),
                              'quote', jsonb_build_object('bid', v_bid, 'ask', v_ask, 'ts', chk->'quote_ts', 'age_s', chk->'quote_age_s'));
  end if;

  begin
    perform set_config('mj.paper_validated_submit', v_coid, true);
    perform set_config('mj.paper_diag_path', 'private.paper_diag_run', true);
    r := private.alpaca_paper_submit_order(v_sym, v_side, v_qty, null, 'limit', 'day', v_limit, null, v_coid, false, false);
    perform set_config('mj.paper_validated_submit', '', true);
    perform set_config('mj.paper_diag_path', '', true);
  exception when others then
    v_err := sqlerrm;
    perform set_config('mj.paper_validated_submit', '', true);
    perform set_config('mj.paper_diag_path', '', true);
    update public.paper_diagnostic_runs set finished_at = clock_timestamp(), outcome = 'REFUSED', ok = false, reasons = array[v_err]
     where id = v_run;
    return jsonb_build_object('run_id', v_run, 'refused', true, 'error', v_err);
  end;

  begin
    v_steps := v_steps || private.paper_diag_step('submit', jsonb_build_object('status', r->'status', 'ok', r->'ok',
                                                   'transport_error', r->'uncertain', 'body', coalesce(r->'order', r->'body')));
    r := private.paper_diag_wait(v_coid, 'ack', 5);
    v_steps := v_steps || private.paper_diag_step('broker_ack', r);
    if p_phase in ('fill','close') then
      r := private.paper_diag_wait(v_coid, 'final', 8);
      v_steps := v_steps || private.paper_diag_step('await_fill', r);
    end if;
    v_final := r->'body';
    if coalesce((r->>'ok')::boolean, false)
       and coalesce(v_final->>'status', '') not in ('filled','canceled','expired','rejected','done_for_day','replaced') then
      r := private.alpaca_paper_cancel_order((v_final->>'id')::uuid);
      v_steps := v_steps || private.paper_diag_step('cancel_request', r);
      r := private.paper_diag_wait(v_coid, 'final', 6);
      v_steps := v_steps || private.paper_diag_step('after_cancel', r);
      v_final := r->'body';
    end if;
    if v_final ? 'id' then perform private.paper_upsert_order(v_final); end if;
    r := private.alpaca_paper_read('/v2/positions');
    v_steps := v_steps || jsonb_build_object('step', 'broker_position_after', 'at_utc', clock_timestamp(), 'http', r->'status',
                 'qty', (select e->>'qty' from jsonb_array_elements(case when jsonb_typeof(r->'body') = 'array' then r->'body' else '[]'::jsonb end) e
                          where upper(e->>'symbol') = v_sym));
  exception when others then
    v_steps := v_steps || jsonb_build_object('step', 'bookkeeping_error', 'at_utc', clock_timestamp(), 'error', left(sqlerrm, 300));
  end;

  v_outcome := coalesce(v_final->>'status', 'UNKNOWN');
  v_ok := case p_phase
            when 'rest' then v_outcome = 'canceled' and coalesce((v_final->>'filled_qty')::numeric, 0) = 0
            when 'fill' then v_outcome in ('filled','canceled') and coalesce((v_final->>'filled_qty')::numeric, 0) > 0
            else v_outcome = 'filled' end;

  update public.paper_diagnostic_runs
     set finished_at = clock_timestamp(), outcome = v_outcome, ok = v_ok, steps = v_steps, final_order = v_final
   where id = v_run;

  begin
    perform private.paper_heartbeat('diagnostic_order', coalesce(v_ok, false),
      jsonb_build_object('run_id', v_run, 'phase', p_phase, 'client_order_id', v_coid, 'final_status', v_outcome,
                         'filled_qty', v_final->'filled_qty', 'filled_avg_price', v_final->'filled_avg_price'),
      case when not coalesce(v_ok, false) then 'diagnostic ' || p_phase || ' ended ' || v_outcome end);
    perform public.fn_reconcile_alpaca_orders();
  exception when others then
    null;
  end;

  return jsonb_build_object('run_id', v_run, 'phase', p_phase, 'ok', v_ok, 'client_order_id', v_coid, 'final_status', v_outcome,
                            'filled_qty', v_final->'filled_qty', 'filled_avg_price', v_final->'filled_avg_price', 'steps', v_steps);
end;
$function$;

-- The old single-shot diagnostic is superseded by paper_diag_run (definition kept in the backup table).
drop function if exists private.paper_run_diagnostic_order(text, text, boolean);

-- ---------------------------------------------------------------------------
-- 7. Views for the dashboard (legacy, diagnostic and strategy kept apart)
-- ---------------------------------------------------------------------------
create or replace view public.v_paper_diagnostic_results with (security_invoker = true) as
select id, phase, symbol, client_order_id, dry_run,
       started_at, to_char(started_at at time zone 'Europe/London', 'YYYY-MM-DD HH24:MI:SS') as started_at_london,
       finished_at, outcome, ok, reasons,
       final_order->>'status' as final_status,
       (final_order->>'filled_qty')::numeric as filled_qty,
       (final_order->>'filled_avg_price')::numeric as filled_avg_price,
       steps
  from public.paper_diagnostic_runs;

create or replace view public.v_paper_diagnostic_positions with (security_invoker = true) as
select symbol,
       sum(case when side = 'buy' then filled_qty else -filled_qty end) as diagnostic_net_qty,
       round(sum(case when side = 'sell' then filled_qty * filled_avg_price else 0 end)
             - sum(case when side = 'buy' then filled_qty * filled_avg_price else 0 end), 2) as diagnostic_cash_flow_usd,
       count(*) as filled_orders,
       max(filled_at) as last_fill_at
  from public.paper_orders
 where origin = 'DIAGNOSTIC' and coalesce(filled_qty, 0) > 0
 group by symbol;

create or replace view public.v_paper_strategy_status with (security_invoker = true) as
select r.strategy_tag, r.side, r.status, r.entry_rule, r.exit_rule, r.sizing, r.holding_period, r.protective_orders,
       r.monitoring, r.failure_behaviour, r.missing_decisions,
       count(t.id) as trades_logged,
       count(t.id) filter (where t.status = 'CLOSED') as closed_trades,
       count(t.id) filter (where t.status in ('ORDERED','PARTIAL','OPEN')) as active_trades,
       max(t.created_at) as last_trade_at,
       r.updated_at
  from public.paper_strategy_registry r
  left join public.paper_strategy_trades t on t.strategy_tag = r.strategy_tag and t.system_key = 'MJ_PAPER_V1'
 group by r.strategy_tag, r.side, r.status, r.entry_rule, r.exit_rule, r.sizing, r.holding_period, r.protective_orders,
          r.monitoring, r.failure_behaviour, r.missing_decisions, r.updated_at;

-- Health view: strategy/diagnostic gates, net diagnostic position, last diagnostic.
do $do$
declare
  d text;
  v_edits text[][] := array[
    array[$o$            paper_system_config.diagnostic_max_notional_usd
           FROM paper_system_config$o$,
          $n$            paper_system_config.diagnostic_max_notional_usd,
            paper_system_config.strategy_orders_enabled,
            paper_system_config.diagnostic_enabled,
            paper_system_config.diagnostic_expires_at
           FROM paper_system_config$n$],
    array[$o$count(*) FILTER (WHERE paper_orders.origin = 'DIAGNOSTIC'::text AND COALESCE(paper_orders.filled_qty, 0::numeric) > 0::numeric) AS diagnostic_filled$o$,
          $n$COALESCE(sum(CASE WHEN paper_orders.side = 'buy'::text THEN COALESCE(paper_orders.filled_qty, 0::numeric) ELSE - COALESCE(paper_orders.filled_qty, 0::numeric) END) FILTER (WHERE paper_orders.origin = 'DIAGNOSTIC'::text), 0::numeric) AS diagnostic_filled$n$],
    array[$o$'WARN: a diagnostic order filled — diagnostic position must be closed explicitly'::text$o$,
          $n$'WARN: a diagnostic-owned position is open: close it with private.paper_diag_run(''close'', ...)'::text$n$],
    array[$o$WHEN COALESCE(c.new_orders_enabled, false) AND c.status = 'PAPER_VALIDATION'::text THEN 'ORDERS_ENABLED'::text$o$,
          $n$WHEN COALESCE(c.new_orders_enabled, false) AND c.status = 'PAPER_VALIDATION'::text AND COALESCE(c.strategy_orders_enabled, false) THEN 'ORDERS_ENABLED'::text
            WHEN COALESCE(c.new_orders_enabled, false) AND c.status = 'PAPER_VALIDATION'::text AND COALESCE(c.diagnostic_enabled, false) AND c.diagnostic_expires_at > now() THEN 'DIAGNOSTIC_ONLY'::text$n$],
    array[$o$ || ' (strategy orders need PAPER_VALIDATION)'::text
                    ELSE NULL::text
                END,$o$,
          $n$ || ' (strategy orders need PAPER_VALIDATION)'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN NOT COALESCE(c_1.strategy_orders_enabled, false) THEN 'Strategy execution disabled (strategy_orders_enabled = false; no strategy is APPROVED)'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN COALESCE(c_1.diagnostic_enabled, false) AND c_1.diagnostic_expires_at > now() THEN ('Diagnostic-only window armed until '::text || to_char((c_1.diagnostic_expires_at AT TIME ZONE 'Europe/London'::text), 'HH24:MI "London"'::text))
                    ELSE NULL::text
                END,$n$],
    array[$o$    sig.latest AS latest_signal
   FROM ( SELECT 1 AS one) base$o$,
          $n$    sig.latest AS latest_signal,
    c.strategy_orders_enabled,
    c.diagnostic_enabled,
    c.diagnostic_expires_at,
    ord.diagnostic_filled AS diagnostic_open_qty,
    ( SELECT to_jsonb(d.*) AS to_jsonb
           FROM ( SELECT r.id, r.phase, r.symbol, r.client_order_id, r.outcome, r.ok, r.started_at
                   FROM paper_diagnostic_runs r
                  WHERE NOT r.dry_run
                  ORDER BY r.id DESC
                 LIMIT 1) d) AS last_diagnostic
   FROM ( SELECT 1 AS one) base$n$]
  ];
  i int;
begin
  d := pg_get_viewdef('public.v_paper_system_health'::regclass, true);
  if position('strategy_orders_enabled' in d) > 0 then
    return;
  end if;
  for i in 1 .. array_length(v_edits, 1) loop
    if position(v_edits[i][1] in d) = 0 then
      raise exception 'health view edit % anchor not found; refusing to patch', i;
    end if;
    d := replace(d, v_edits[i][1], v_edits[i][2]);
  end loop;
  execute 'create or replace view public.v_paper_system_health as ' || d;
end;
$do$;

-- ---------------------------------------------------------------------------
-- 8. Permissions: owner-only execution; read views for the dashboard (service_role)
-- ---------------------------------------------------------------------------
revoke all on function private.paper_diag_arm(text, integer, text) from public, anon, authenticated, service_role;
revoke all on function private.paper_diag_disarm(text) from public, anon, authenticated, service_role;
revoke all on function private.paper_diag_expire() from public, anon, authenticated, service_role;
revoke all on function private.paper_diag_wait(text, text, integer) from public, anon, authenticated, service_role;
revoke all on function private.paper_diag_step(text, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.paper_diag_checks(text, text) from public, anon, authenticated, service_role;
revoke all on function private.paper_diag_run(text, text, text, boolean) from public, anon, authenticated, service_role;
revoke all on function private.guard_paper_strategy_registry() from public, anon, authenticated, service_role;
revoke all on function private.alpaca_http(text, text, text) from public, anon, authenticated, service_role;
revoke all on function private.alpaca_paper_cancel_order(uuid) from public, anon, authenticated, service_role;
revoke all on function private.enforce_mj_paper_order_hold() from public, anon, authenticated, service_role;
revoke all on function private.guard_paper_system_config() from public, anon, authenticated, service_role;
revoke all on public.v_paper_diagnostic_results, public.v_paper_diagnostic_positions, public.v_paper_strategy_status from anon, authenticated;
grant select on public.v_paper_diagnostic_results, public.v_paper_diagnostic_positions, public.v_paper_strategy_status to service_role;
grant select on public.paper_diagnostic_runs, public.paper_strategy_registry to service_role;

-- ---------------------------------------------------------------------------
-- 9. Desk configuration for the diagnostic-only validation phase
-- ---------------------------------------------------------------------------
update public.paper_system_config
   set status = 'PAPER_VALIDATION',
       strategy_orders_enabled = false,
       diagnostic_enabled = false,
       diagnostic_expires_at = null,
       diagnostic_max_notional_usd = 100,
       diagnostic_max_quote_age_seconds = 60,
       diagnostic_asset_classes = array['us_equity'],
       diagnostic_max_qty = 1,
       diagnostic_settings = jsonb_build_object(
         'source', 'Joe, chat instruction in Claude Code session, 30 Sep 2026',
         'recorded_at_utc', now(),
         'scope', 'DIAGNOSTIC ONLY: test settings, not permission for strategy trading',
         'asset_scope', 'US equities only; no options',
         'max_exposure_usd', 100,
         'borrowing', 'none (cash only)',
         'max_quote_age_seconds', 60,
         'concurrency', 'one diagnostic order at a time',
         'legacy', 'preserve all legacy positions',
         'engineer_harness_choices', jsonb_build_object(
           'max_qty', 1, 'max_spread_pct', 1.0, 'order_type', 'whole-share DAY limit, regular session only',
           'rest_limit', 'bid - 5% (should not fill; cancelled)', 'fill_limit', 'ask + 0.2%', 'close_limit', 'bid - 0.2%',
           'window', 'armed per test, 1-120 minutes, auto-disarm on expiry')),
       notes = coalesce(notes, '') || E'\n[2026-09-30 Europe/London] DIAGNOSTIC ISOLATION: status PAPER_VALIDATION with strategy_orders_enabled=false; '
               || 'only private.paper_diag_run may submit, inside an armed window. Joe diagnostic settings recorded in diagnostic_settings. '
               || 'All strategy tags registered as PAUSED in paper_strategy_registry.',
       updated_at = now()
 where system_key = 'MJ_PAPER_V1';

-- Expire any diagnostic window that outlives its deadline.
select cron.schedule('paper_diag_window_expiry', '*/5 * * * *', $$ select private.paper_diag_expire(); $$);
