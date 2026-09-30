CREATE OR REPLACE FUNCTION private.paper_validate_strategy_order(p_trade_id uuid, p_limit_price numeric, p_client_order_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c public.paper_system_config;
  t public.paper_strategy_trades;
  d record;
  p record;
  v_reasons text[] := '{}';
  v_checks jsonb := '{}'::jsonb;
  v_id jsonb; v_clock jsonb; v_asset jsonb; v_pos jsonb; v_open jsonb; v_quote jsonb; v_lookup jsonb; v_daily record;
  v_equity numeric; v_last_equity numeric; v_bp numeric; v_lmv numeric; v_smv numeric;
  v_open_notional numeric := 0;
  v_open_market int := 0;
  v_notional numeric; v_risk numeric; v_rr numeric;
  v_bid numeric; v_ask numeric; v_qts timestamptz; v_qage numeric;
  v_active int; v_n int;
  v_coid text := nullif(trim(p_client_order_id), '');
  v_side text;
begin
  select * into c from public.paper_system_config where system_key = 'MJ_PAPER_V1';
  select * into t from public.paper_strategy_trades where id = p_trade_id;

  if c.system_key is null then return jsonb_build_object('pass', false, 'reasons', jsonb_build_array('MJ_PAPER_V1 config row missing')); end if;
  if c.status is distinct from 'PAPER_VALIDATION' then v_reasons := v_reasons || ('desk status is ' || coalesce(c.status, 'MISSING') || ' (needs PAPER_VALIDATION)'); end if;
  if not coalesce(c.new_orders_enabled, false) then v_reasons := v_reasons || 'kill switch engaged (new_orders_enabled = false)'::text; end if;
  if c.permitted_strategy_tags is null or cardinality(c.permitted_strategy_tags) = 0 then v_reasons := v_reasons || 'DECISION NEEDED: permitted_strategy_tags not set'::text; end if;
  if c.permitted_asset_classes is null or cardinality(c.permitted_asset_classes) = 0 then v_reasons := v_reasons || 'DECISION NEEDED: permitted_asset_classes not set'::text; end if;
  if c.max_quote_age_seconds is null then v_reasons := v_reasons || 'DECISION NEEDED: max_quote_age_seconds (stale-data limit) not set'::text; end if;
  if c.min_reward_risk is null or c.market_data_feed is null or c.max_risk_per_trade_pct is null or c.max_single_position_pct is null
     or c.max_speculative_position_pct is null or c.max_concurrent_positions is null or c.max_gross_exposure_pct is null
     or c.max_short_gross_exposure_pct is null or c.daily_loss_circuit_breaker_pct is null or c.max_drawdown_limit_pct is null then
    v_reasons := v_reasons || 'one or more risk limits are NULL — refusing'::text;
  end if;

  if t.id is null then
    return jsonb_build_object('pass', false, 'reasons', jsonb_build_array('trade not found'));
  end if;
  if t.system_key is distinct from 'MJ_PAPER_V1' then v_reasons := v_reasons || 'trade is not MJ_PAPER_V1'::text; end if;
  if t.status is distinct from 'PLANNED' then v_reasons := v_reasons || ('trade status is ' || coalesce(t.status, 'NULL') || ' (needs PLANNED)'); end if;
  if t.entry_order_id is not null or t.entry_client_order_id is not null then v_reasons := v_reasons || 'trade already has an entry order or a pending submission'::text; end if;
  if t.side is null or t.side not in ('LONG','SHORT') then v_reasons := v_reasons || 'side must be LONG or SHORT'::text; end if;
  if c.permitted_strategy_tags is not null and not coalesce(t.strategy_tag = any(c.permitted_strategy_tags), false) then v_reasons := v_reasons || ('strategy tag ' || coalesce(t.strategy_tag, 'NULL') || ' is not permitted'); end if;
  if coalesce(t.qty, 0) <= 0 then v_reasons := v_reasons || 'qty missing'::text; end if;
  if t.side = 'SHORT' and t.qty <> trunc(t.qty) then v_reasons := v_reasons || 'short qty must be whole shares'::text; end if;
  if t.initial_stop_usd is null then v_reasons := v_reasons || 'initial stop missing'::text; end if;
  if t.target_1_usd is null then v_reasons := v_reasons || 'target_1 missing'::text; end if;
  if coalesce(trim(t.thesis), '') = '' then v_reasons := v_reasons || 'thesis missing'::text; end if;
  if coalesce(trim(t.catalyst), '') = '' then v_reasons := v_reasons || 'catalyst missing'::text; end if;
  if t.expected_holding_days_min is null or t.expected_holding_days_max is null then v_reasons := v_reasons || 'holding period missing'::text; end if;
  if t.is_speculative is null then v_reasons := v_reasons || 'is_speculative not declared (needed for the 2% speculative cap)'::text; end if;

  if t.decision_id is null or t.parent_plan_id is null then
    v_reasons := v_reasons || 'decision_id and parent_plan_id are required'::text;
  else
    select * into d from public.mj_decision_records where id = t.decision_id;
    select * into p from public.mj_decision_records where id = t.parent_plan_id;
    if d.id is null or d.approval_status is distinct from 'approved' then v_reasons := v_reasons || 'decision record missing or not approved'::text; end if;
    if d.id is not null and upper(coalesce(d.ticker, '')) is distinct from upper(coalesce(t.symbol, '?')) then v_reasons := v_reasons || 'decision ticker does not match trade symbol'::text; end if;
    if d.id is not null and coalesce(d.evidence->>'gate', '') <> 'PASS' then v_reasons := v_reasons || 'Trade Decision Gate PASS not recorded on decision'::text; end if;
    if d.id is not null and coalesce(d.evidence->>'parent_plan_id', '') <> t.parent_plan_id::text then v_reasons := v_reasons || 'decision does not cite the parent PLAN'::text; end if;
    if p.id is null or p.approval_status is distinct from 'approved' then v_reasons := v_reasons || 'parent PLAN missing or not approved'::text; end if;
  end if;

  if v_coid is null or v_coid !~ '^mj-[a-z0-9][a-z0-9-]{2,90}$' or v_coid like 'mj-diag-%' then
    v_reasons := v_reasons || 'client_order_id must match ^mj-[a-z0-9-]+$ and not use the mj-diag- prefix'::text;
    v_coid := null;
  elsif exists (select 1 from private.alpaca_paper_order_audit where client_order_id = v_coid and not dry_run)
     or exists (select 1 from public.paper_orders where client_order_id = v_coid) then
    v_reasons := v_reasons || 'client_order_id already used'::text;
  end if;
  select count(*) into v_n from public.paper_orders where origin = 'EXTERNAL_POST_BASELINE' and reviewed_at is null;
  if v_n > 0 then v_reasons := v_reasons || (v_n || ' unreviewed order(s) from outside the bridge — review before trading'); end if;
  select count(*) into v_n from public.paper_strategy_trades where status in ('ORDERED','PARTIAL') and entry_order_id is null;
  if v_n > 0 then v_reasons := v_reasons || (v_n || ' unresolved uncertain submission(s) — run fn_reconcile_alpaca_orders'); end if;

  if p_limit_price is null or p_limit_price <= 0 then v_reasons := v_reasons || 'limit price required (market orders are not allowed: executable-price guard)'::text; end if;

  if t.initial_stop_usd is null or t.target_1_usd is null or coalesce(t.qty, 0) <= 0 or p_limit_price is null or p_limit_price <= 0
     or t.side is null or t.side not in ('LONG','SHORT') or t.symbol is null or upper(t.symbol) !~ '^[A-Z0-9./-]{1,20}$' then
    return jsonb_build_object('pass', false, 'reasons', to_jsonb(v_reasons), 'checks', v_checks);
  end if;

  v_id := private.alpaca_paper_identity();
  v_checks := v_checks || jsonb_build_object('identity', v_id);
  if not coalesce((v_id->>'pass')::boolean, false) then v_reasons := v_reasons || ('paper identity failed: ' || coalesce(v_id->>'reasons', '')); end if;
  v_equity := (v_id->>'equity')::numeric; v_last_equity := (v_id->>'last_equity')::numeric; v_bp := (v_id->>'buying_power')::numeric;
  v_lmv := coalesce((v_id->>'long_market_value')::numeric, 0); v_smv := abs(coalesce((v_id->>'short_market_value')::numeric, 0));

  v_clock := private.alpaca_paper_read('/v2/clock');
  v_checks := v_checks || jsonb_build_object('clock', v_clock->'body');
  if not coalesce((v_clock->'body'->>'is_open')::boolean, false) then v_reasons := v_reasons || 'US regular session is not open'::text; end if;

  v_asset := private.alpaca_paper_read('/v2/assets/' || upper(t.symbol));
  v_checks := v_checks || jsonb_build_object('asset', jsonb_build_object('class', v_asset->'body'->'class', 'tradable', v_asset->'body'->'tradable',
                'shortable', v_asset->'body'->'shortable', 'easy_to_borrow', v_asset->'body'->'easy_to_borrow', 'status', v_asset->'body'->'status'));
  if not coalesce((v_asset->>'ok')::boolean, false) then v_reasons := v_reasons || 'asset lookup failed'::text;
  else
    if not coalesce((v_asset->'body'->>'tradable')::boolean, false) or coalesce(v_asset->'body'->>'status', '') <> 'active' then v_reasons := v_reasons || 'asset not tradable/active'::text; end if;
    if not coalesce((v_asset->'body'->>'class') = any(c.permitted_asset_classes), false) then v_reasons := v_reasons || ('asset class ' || coalesce(v_asset->'body'->>'class', '?') || ' not permitted'); end if;
    if t.side = 'SHORT' then
      if not coalesce((v_id->>'shorting_enabled')::boolean, false) then v_reasons := v_reasons || 'account shorting not enabled'::text; end if;
      if not coalesce((v_asset->'body'->>'shortable')::boolean, false) then v_reasons := v_reasons || 'asset not shortable'::text; end if;
      if not coalesce((v_asset->'body'->>'easy_to_borrow')::boolean, false) then v_reasons := v_reasons || 'asset not easy to borrow'::text; end if;
    end if;
  end if;

  v_pos := private.alpaca_paper_read('/v2/positions');
  if not coalesce((v_pos->>'ok')::boolean, false) then v_reasons := v_reasons || 'positions lookup failed'::text;
  elsif exists (select 1 from jsonb_array_elements(v_pos->'body') e where upper(e->>'symbol') = upper(t.symbol)) then
    v_reasons := v_reasons || ('a position in ' || t.symbol || ' already exists (legacy or MJ) — MJ trades must not touch it'); end if;
  v_open := private.alpaca_paper_read('/v2/orders?status=open&limit=500');
  if not coalesce((v_open->>'ok')::boolean, false) then v_reasons := v_reasons || 'open-orders lookup failed'::text;
  else
    if exists (select 1 from jsonb_array_elements(v_open->'body') e where upper(e->>'symbol') = upper(t.symbol)) then
      v_reasons := v_reasons || ('an open order in ' || t.symbol || ' already exists'); end if;
    select coalesce(sum(coalesce((e->>'qty')::numeric, 0) * coalesce((e->>'limit_price')::numeric, (e->>'stop_price')::numeric, 0) + coalesce((e->>'notional')::numeric, 0)), 0),
           count(*) filter (where e->>'type' = 'market' and e->>'notional' is null)
      into v_open_notional, v_open_market from jsonb_array_elements(v_open->'body') e;
    if v_open_market > 0 then v_reasons := v_reasons || 'an open market order exists (exposure cannot be sized) — resolve it first'::text; end if;
  end if;
  if v_coid is not null then
    v_lookup := private.alpaca_paper_read('/v2/orders:by_client_order_id?client_order_id=' || v_coid);
    if coalesce((v_lookup->>'status')::int, 0) <> 404 then v_reasons := v_reasons || ('broker lookup for client_order_id did not return 404 (got ' || coalesce(v_lookup->>'status', 'none') || ')'); end if;
  end if;

  v_quote := private.alpaca_data_read('/v2/stocks/quotes/latest?symbols=' || upper(t.symbol) || '&feed=' || coalesce(c.market_data_feed, 'iex'));
  v_bid := (v_quote->'body'->'quotes'->upper(t.symbol)->>'bp')::numeric;
  v_ask := (v_quote->'body'->'quotes'->upper(t.symbol)->>'ap')::numeric;
  v_qts := (v_quote->'body'->'quotes'->upper(t.symbol)->>'t')::timestamptz;
  v_qage := extract(epoch from clock_timestamp() - v_qts);
  v_checks := v_checks || jsonb_build_object('quote', jsonb_build_object('feed', c.market_data_feed, 'bid', v_bid, 'ask', v_ask, 'ts', v_qts, 'age_s', round(v_qage)));
  if not coalesce((v_quote->>'ok')::boolean, false) or v_qts is null then v_reasons := v_reasons || 'quote unavailable'::text;
  else
    if c.max_quote_age_seconds is null or v_qage > c.max_quote_age_seconds or v_qage < -5 then v_reasons := v_reasons || ('quote is stale or clock-skewed (' || round(v_qage) || 's)'); end if;
    if coalesce(v_bid, 0) <= 0 or coalesce(v_ask, 0) <= 0 or v_ask < v_bid then v_reasons := v_reasons || 'quote is not two-sided/valid'::text; end if;
  end if;

  if t.side = 'LONG' then
    if not (t.initial_stop_usd < p_limit_price and p_limit_price < t.target_1_usd) then v_reasons := v_reasons || 'LONG requires stop < limit < target_1'::text; end if;
    if v_bid is not null and v_bid <= t.initial_stop_usd then v_reasons := v_reasons || 'market is already at or below the stop'::text; end if;
    if v_ask is not null and v_ask >= t.target_1_usd then v_reasons := v_reasons || 'market is already at or above target_1'::text; end if;
    v_rr := case when p_limit_price - t.initial_stop_usd > 0 then (t.target_1_usd - p_limit_price) / (p_limit_price - t.initial_stop_usd) end;
    v_side := 'buy';
  else
    if not (t.target_1_usd < p_limit_price and p_limit_price < t.initial_stop_usd) then v_reasons := v_reasons || 'SHORT requires target_1 < limit < stop'::text; end if;
    if v_ask is not null and v_ask >= t.initial_stop_usd then v_reasons := v_reasons || 'market is already at or above the stop'::text; end if;
    if v_bid is not null and v_bid <= t.target_1_usd then v_reasons := v_reasons || 'market is already at or below target_1'::text; end if;
    v_rr := case when t.initial_stop_usd - p_limit_price > 0 then (p_limit_price - t.target_1_usd) / (t.initial_stop_usd - p_limit_price) end;
    v_side := 'sell';
  end if;
  if v_rr is null or c.min_reward_risk is null or v_rr < c.min_reward_risk then v_reasons := v_reasons || ('reward:risk at limit ' || coalesce(round(v_rr, 2)::text, 'n/a') || ' < ' || coalesce(c.min_reward_risk::text, '?')); end if;

  v_notional := t.qty * p_limit_price;
  v_risk := t.qty * abs(p_limit_price - t.initial_stop_usd);
  if v_equity is null or v_equity <= 0 or v_last_equity is null or v_last_equity <= 0 or v_bp is null then
    v_reasons := v_reasons || 'equity, last_equity or buying power unavailable'::text;
  else
    if v_risk > v_equity * c.max_risk_per_trade_pct / 100 then v_reasons := v_reasons || ('risk $' || round(v_risk, 2) || ' exceeds ' || c.max_risk_per_trade_pct || '% of equity'); end if;
    if v_notional > v_equity * c.max_single_position_pct / 100 then v_reasons := v_reasons || ('notional $' || round(v_notional, 2) || ' exceeds ' || c.max_single_position_pct || '% single-position cap'); end if;
    if coalesce(t.is_speculative, false) and v_notional > v_equity * c.max_speculative_position_pct / 100 then v_reasons := v_reasons || ('speculative notional exceeds ' || c.max_speculative_position_pct || '% cap'); end if;
    if v_lmv + v_smv + v_open_notional + v_notional > v_equity * c.max_gross_exposure_pct / 100 then v_reasons := v_reasons || ('gross exposure would exceed ' || c.max_gross_exposure_pct || '% of equity'); end if;
    if t.side = 'SHORT' and v_smv + v_notional > v_equity * c.max_short_gross_exposure_pct / 100 then v_reasons := v_reasons || ('short exposure would exceed ' || c.max_short_gross_exposure_pct || '% of equity'); end if;
    if v_notional > v_bp then v_reasons := v_reasons || 'insufficient buying power'::text; end if;
    if (v_equity - v_last_equity) / v_last_equity * 100 <= -c.daily_loss_circuit_breaker_pct then v_reasons := v_reasons || ('daily loss circuit breaker (' || c.daily_loss_circuit_breaker_pct || '%) tripped'); end if;
  end if;
  select count(*) into v_active from public.paper_strategy_trades where system_key = 'MJ_PAPER_V1' and status in ('ORDERED','PARTIAL','OPEN');
  if v_active >= c.max_concurrent_positions then v_reasons := v_reasons || ('max concurrent positions (' || c.max_concurrent_positions || ') reached'); end if;
  select * into v_daily from public.paper_system_daily where system_key = 'MJ_PAPER_V1' order by snapshot_date desc limit 1;
  if v_daily.snapshot_date is null or v_daily.snapshot_date < current_date - 4 then
    v_reasons := v_reasons || 'MJ drawdown snapshot (paper_system_daily) missing or older than 4 days'::text;
  elsif abs(coalesce(v_daily.drawdown_pct, 0)) >= c.max_drawdown_limit_pct then
    v_reasons := v_reasons || ('system drawdown limit (' || c.max_drawdown_limit_pct || '%) reached');
  end if;

  v_checks := v_checks || jsonb_build_object('sizing', jsonb_build_object('equity', v_equity, 'notional', round(v_notional, 2), 'risk', round(v_risk, 2),
                 'risk_pct', case when v_equity > 0 then round(v_risk / v_equity * 100, 3) end,
                 'notional_pct', case when v_equity > 0 then round(v_notional / v_equity * 100, 2) end,
                 'reward_risk_at_limit', round(v_rr, 2), 'open_order_notional', v_open_notional, 'active_mj_trades', v_active));

  return jsonb_build_object(
    'pass', cardinality(v_reasons) = 0,
    'reasons', to_jsonb(v_reasons),
    'checks', v_checks,
    'order', jsonb_build_object('symbol', upper(t.symbol), 'side', v_side, 'qty', t.qty, 'type', 'limit', 'time_in_force', 'day',
                                'limit_price', p_limit_price, 'extended_hours', false, 'client_order_id', v_coid));
end;
$function$
