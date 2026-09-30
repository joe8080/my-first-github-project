-- MJ_PAPER_V1 table definitions: snapshot exported from the live database on 30 Sep 2026
-- (after migration 20260930_02). Column order, types, defaults, keys and RLS match the database.
-- Tables created by migration 20260930_02 (paper_strategy_registry, paper_diagnostic_runs)
-- are defined in that migration. Row data is not exported.

create table if not exists public.paper_system_config (
  system_key text not null,
  system_name text not null,
  baseline_at timestamp with time zone not null,
  baseline_equity_usd numeric,
  benchmark_spy_start numeric,
  benchmark_qqq_start numeric,
  target_closed_trades integer not null default 50,
  min_profit_factor numeric not null default 1.30,
  max_drawdown_limit_pct numeric not null default 8.0,
  max_risk_per_trade_pct numeric not null default 0.50,
  exceptional_risk_per_trade_pct numeric not null default 0.75,
  max_single_position_pct numeric not null default 8.0,
  max_speculative_position_pct numeric not null default 2.0,
  max_concurrent_positions integer not null default 8,
  max_gross_exposure_pct numeric not null default 125.0,
  max_short_gross_exposure_pct numeric not null default 35.0,
  daily_loss_circuit_breaker_pct numeric not null default 2.0,
  status text not null default 'PAPER_VALIDATION'::text,
  notes text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  new_orders_enabled boolean not null default false,
  kill_switch_reason text,
  kill_switch_changed_at timestamp with time zone,
  kill_switch_changed_by text,
  permitted_strategy_tags text[],
  permitted_asset_classes text[],
  min_reward_risk numeric,
  market_data_feed text,
  max_quote_age_seconds integer,
  diagnostic_max_notional_usd numeric,
  strategy_orders_enabled boolean not null default false,
  diagnostic_enabled boolean not null default false,
  diagnostic_expires_at timestamp with time zone,
  diagnostic_asset_classes text[],
  diagnostic_max_quote_age_seconds integer,
  diagnostic_max_qty integer,
  diagnostic_settings jsonb,
  CHECK (((market_data_feed IS NULL) OR (market_data_feed = ANY (ARRAY['iex'::text, 'sip'::text])))),
  PRIMARY KEY (system_key),
  CHECK ((status = ANY (ARRAY['PAPER_VALIDATION'::text, 'PAUSED_RISK'::text, 'GRADUATION_REVIEW'::text, 'RETIRED'::text])))
);
alter table public.paper_system_config enable row level security;

create table if not exists public.paper_strategy_trades (
  id uuid not null default gen_random_uuid(),
  system_key text not null,
  strategy_tag text not null,
  symbol text not null,
  side text not null,
  status text not null default 'PLANNED'::text,
  opened_at timestamp with time zone,
  closed_at timestamp with time zone,
  expected_holding_days_min integer,
  expected_holding_days_max integer,
  thesis text not null,
  catalyst text,
  entry_trigger text not null,
  invalidation text not null,
  entry_order_id text,
  exit_order_id text,
  qty numeric,
  entry_price_usd numeric,
  exit_price_usd numeric,
  initial_stop_usd numeric,
  current_stop_usd numeric,
  target_1_usd numeric,
  target_2_usd numeric,
  planned_reward_risk numeric,
  initial_risk_usd numeric,
  notional_usd numeric,
  realised_pnl_usd numeric,
  unrealised_pnl_usd numeric,
  realised_r_multiple numeric,
  max_favourable_excursion_pct numeric,
  max_adverse_excursion_pct numeric,
  rule_exception boolean not null default false,
  exception_reason text,
  exit_reason text,
  process_grade text,
  notes text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  parent_plan_id uuid,
  decision_id uuid,
  is_speculative boolean,
  entry_client_order_id text,
  CHECK (((process_grade IS NULL) OR (process_grade = ANY (ARRAY['A'::text, 'B'::text, 'C'::text, 'D'::text])))),
  CHECK ((side = ANY (ARRAY['LONG'::text, 'SHORT'::text]))),
  CHECK ((status = ANY (ARRAY['PLANNED'::text, 'ORDERED'::text, 'OPEN'::text, 'PARTIAL'::text, 'CLOSED'::text, 'CANCELLED'::text, 'REJECTED'::text]))),
  CHECK ((strategy_tag = ANY (ARRAY['LONG_MOMENTUM_BREAKOUT'::text, 'LONG_PULLBACK_CONTINUATION'::text, 'LONG_MEAN_REVERSION'::text, 'LONG_CATALYST'::text, 'SHORT_BREAKDOWN'::text, 'SHORT_FAILED_BREAKOUT'::text, 'SHORT_MEAN_REVERSION'::text, 'SHORT_CATALYST'::text, 'SQUEEZE_LONG'::text, 'EVENT_SWING'::text, 'SAMPLE_DAILY'::text]))),
  PRIMARY KEY (id),
  FOREIGN KEY (system_key) REFERENCES paper_system_config(system_key)
);
alter table public.paper_strategy_trades enable row level security;
CREATE INDEX idx_paper_strategy_trades_system_status ON public.paper_strategy_trades USING btree (system_key, status);
CREATE INDEX idx_paper_strategy_trades_opened_at ON public.paper_strategy_trades USING btree (opened_at);
CREATE INDEX idx_paper_strategy_trades_symbol ON public.paper_strategy_trades USING btree (symbol);

create table if not exists public.paper_trade_events (
  id uuid not null default gen_random_uuid(),
  trade_id uuid not null,
  event_at timestamp with time zone not null default now(),
  event_type text not null,
  price_usd numeric,
  qty numeric,
  stop_usd numeric,
  target_usd numeric,
  order_id text,
  rule_code text,
  detail text,
  metadata jsonb not null default '{}'::jsonb,
  CHECK ((event_type = ANY (ARRAY['PLAN'::text, 'ORDER_SUBMITTED'::text, 'FILL'::text, 'STOP_ADJUSTED'::text, 'TARGET_ADJUSTED'::text, 'PARTIAL_EXIT'::text, 'CLOSE'::text, 'CANCEL'::text, 'REJECT'::text, 'RULE_VIOLATION'::text, 'REVIEW'::text]))),
  PRIMARY KEY (id),
  FOREIGN KEY (trade_id) REFERENCES paper_strategy_trades(id) ON DELETE CASCADE
);
alter table public.paper_trade_events enable row level security;
CREATE INDEX idx_paper_trade_events_trade_time ON public.paper_trade_events USING btree (trade_id, event_at);

create table if not exists public.paper_orders (
  alpaca_order_id text not null,
  client_order_id text not null,
  origin text not null,
  is_diagnostic boolean not null default false,
  strategy_trade_id uuid,
  symbol text not null,
  asset_class text,
  side text,
  position_intent text,
  order_type text,
  order_class text,
  time_in_force text,
  qty numeric,
  notional numeric,
  limit_price numeric,
  stop_price numeric,
  extended_hours boolean,
  status text not null,
  filled_qty numeric,
  filled_avg_price numeric,
  submitted_at timestamp with time zone,
  filled_at timestamp with time zone,
  canceled_at timestamp with time zone,
  expired_at timestamp with time zone,
  failed_at timestamp with time zone,
  broker_updated_at timestamp with time zone,
  raw jsonb not null,
  first_seen_at timestamp with time zone not null default now(),
  last_synced_at timestamp with time zone not null default now(),
  review_note text,
  reviewed_at timestamp with time zone,
  UNIQUE (client_order_id),
  CHECK ((origin = ANY (ARRAY['MJ_BRIDGE'::text, 'DIAGNOSTIC'::text, 'LEGACY_PRE_BASELINE'::text, 'EXTERNAL_POST_BASELINE'::text]))),
  PRIMARY KEY (alpaca_order_id),
  FOREIGN KEY (strategy_trade_id) REFERENCES paper_strategy_trades(id) ON DELETE SET NULL
);
alter table public.paper_orders enable row level security;
CREATE INDEX paper_orders_status_idx ON public.paper_orders USING btree (status);
CREATE INDEX paper_orders_submitted_idx ON public.paper_orders USING btree (submitted_at);

create table if not exists public.paper_system_heartbeat (
  component text not null,
  ok boolean,
  last_run_at timestamp with time zone,
  last_ok_at timestamp with time zone,
  last_error_at timestamp with time zone,
  last_error text,
  details jsonb,
  updated_at timestamp with time zone not null default now(),
  PRIMARY KEY (component)
);
alter table public.paper_system_heartbeat enable row level security;

create table if not exists public.paper_system_daily (
  snapshot_date date not null,
  system_key text not null,
  account_equity_usd numeric,
  new_system_realised_pnl_usd numeric,
  new_system_unrealised_pnl_usd numeric,
  new_system_total_pnl_usd numeric,
  new_system_return_pct numeric,
  equity_high_watermark_usd numeric,
  drawdown_pct numeric,
  gross_exposure_usd numeric,
  long_exposure_usd numeric,
  short_exposure_usd numeric,
  spy_price numeric,
  qqq_price numeric,
  spy_return_since_baseline_pct numeric,
  qqq_return_since_baseline_pct numeric,
  closed_trades integer,
  open_trades integer,
  rule_violations integer,
  notes text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  PRIMARY KEY (snapshot_date),
  FOREIGN KEY (system_key) REFERENCES paper_system_config(system_key)
);
alter table public.paper_system_daily enable row level security;

create table if not exists public.paper_account_snapshots (
  snapshot_at timestamp with time zone not null default now(),
  snapshot_date date not null default CURRENT_DATE,
  equity_usd numeric,
  cash_usd numeric,
  buying_power_usd numeric,
  PRIMARY KEY (snapshot_date)
);
alter table public.paper_account_snapshots enable row level security;

create table if not exists public.paper_positions (
  snapshot_date date not null default CURRENT_DATE,
  symbol text not null,
  qty numeric,
  side text,
  avg_entry_price_usd numeric,
  current_price_usd numeric,
  market_value_usd numeric,
  unrealized_pl_usd numeric,
  unrealized_pl_pct numeric,
  PRIMARY KEY (snapshot_date, symbol)
);
alter table public.paper_positions enable row level security;

create table if not exists public.paper_fills (
  alpaca_id text not null,
  filled_at timestamp with time zone not null,
  symbol text not null,
  side text,
  qty numeric,
  price_usd numeric,
  order_id text,
  reviewed boolean not null default false,
  review_notes text,
  created_at timestamp with time zone default now(),
  PRIMARY KEY (alpaca_id)
);
alter table public.paper_fills enable row level security;

create table if not exists public.paper_sync_requests (
  request_id bigint not null,
  kind text not null,
  requested_at timestamp with time zone default now(),
  processed boolean not null default false,
  status_code integer,
  error text,
  CHECK ((kind = ANY (ARRAY['account'::text, 'positions'::text, 'fills'::text]))),
  PRIMARY KEY (request_id)
);
alter table public.paper_sync_requests enable row level security;

create table if not exists public.price_fetch_requests (
  request_id bigint not null,
  requested_at timestamp with time zone default now(),
  processed boolean not null default false,
  status_code integer,
  error text,
  PRIMARY KEY (request_id)
);
alter table public.price_fetch_requests enable row level security;

create table if not exists private.alpaca_paper_order_audit (
  id uuid not null default gen_random_uuid(),
  created_at timestamp with time zone not null default now(),
  symbol text not null,
  side text not null,
  qty numeric,
  notional numeric,
  order_type text not null,
  time_in_force text not null,
  limit_price numeric,
  stop_price numeric,
  client_order_id text,
  extended_hours boolean not null default false,
  dry_run boolean not null default true,
  http_status integer,
  alpaca_order_id text,
  request_payload jsonb not null,
  response_payload jsonb,
  PRIMARY KEY (id)
);
CREATE UNIQUE INDEX alpaca_paper_order_audit_coid_live_uq ON private.alpaca_paper_order_audit USING btree (client_order_id) WHERE ((NOT dry_run) AND (client_order_id IS NOT NULL));

-- Triggers (functions are in baseline/functions and migrations/)
-- create trigger trg_enforce_mj_paper_order_hold before insert on private.alpaca_paper_order_audit
--   for each row execute function private.enforce_mj_paper_order_hold();
-- create trigger trg_guard_paper_system_config before update on public.paper_system_config
--   for each row execute function private.guard_paper_system_config();
