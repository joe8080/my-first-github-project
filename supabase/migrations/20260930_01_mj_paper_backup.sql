-- MJ_PAPER_V1: server-side backup taken before the 30 Sep 2026 diagnostic-isolation change.
-- Applied as migration mj_paper_backup_20260930. Stores definitions only (no data, no secrets).
create table if not exists private.paper_config_backup (
  id bigserial primary key,
  backup_label text not null,
  backed_up_at timestamptz not null default now(),
  object_type text not null,
  object_name text not null,
  definition text not null,
  md5 text generated always as (md5(definition)) stored
);
revoke all on private.paper_config_backup from public, anon, authenticated, service_role;

insert into private.paper_config_backup(backup_label, object_type, object_name, definition)
select 'pre_diagnostic_isolation_20260930', 'function',
       n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')', pg_get_functiondef(p.oid)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname in ('public','private') and (p.prosrc ilike '%alpaca%' or p.proname ilike '%paper%');

insert into private.paper_config_backup(backup_label, object_type, object_name, definition)
select 'pre_diagnostic_isolation_20260930', 'view', 'public.'||c.relname, pg_get_viewdef(c.oid, true)
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='v' and c.relname like 'v_paper%';

insert into private.paper_config_backup(backup_label, object_type, object_name, definition)
select 'pre_diagnostic_isolation_20260930', 'config_row', 'public.paper_system_config', to_jsonb(c)::text
from public.paper_system_config c;
