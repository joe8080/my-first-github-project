# MJ_PAPER_V1: database implementation (Alpaca PAPER desk)

This folder holds the implementation of Joe's Alpaca **paper** trading desk, which runs in the
Supabase project "finance chief" (Postgres 17 + pg_cron + Vault + the `http` extension).
It contains no credentials. Alpaca keys live only in Supabase Vault
(`ALPACA_PAPER_KEY_ID`, `ALPACA_PAPER_SECRET`) and must never be exported or committed.

## Layout

| Path | What it is |
|---|---|
| `schema/00_tables.sql` | Table definitions (snapshot of the live database, 30 Sep 2026) |
| `baseline/functions/*.sql` | Every paper-desk function **before** the 30 Sep diagnostic change, exported with `pg_get_functiondef`. Checksums in `baseline/functions.md5` match `md5(pg_get_functiondef(...))` in the database. |
| `baseline/views/*.sql` | Paper views before the change (body md5 matches `pg_get_viewdef`) |
| `migrations/20260930_01_mj_paper_backup.sql` | Server-side backup table `private.paper_config_backup` |
| `migrations/20260930_02_mj_paper_diagnostic_isolation.sql` | Diagnostic isolation, bridge hardening, strategy registry, dashboard views |
| `schema/10_cron.sql` | pg_cron jobs for the desk (UTC) |
| `functions/finance-chief-dashboard/` | Dashboard edge function v10 (token hashes redacted) |

## Rebuild or recover (in order)

1. Tables: run `schema/00_tables.sql`, then create the two triggers listed at the bottom of that file.
2. Functions and views: run every file in `baseline/functions/`, then `baseline/views/`.
3. Migrations: run `migrations/20260930_01_*.sql`, then `migrations/20260930_02_*.sql`.
   Migration 02 patches the validator and the health view by exact text match. It refuses to run
   (raises "anchor not found") if the baseline differs, so it cannot half-apply.
4. Cron: run `schema/10_cron.sql`.
5. Credentials: in the SQL editor, run
   `select private.configure_alpaca_paper('<PAPER key id>', '<PAPER secret>');`
   It only accepts `PK…` paper keys and the paper base URL, and writes to Vault.
   Never paste keys into chat, files or git.
6. Verify: `select private.alpaca_paper_identity();` must return `pass: true` and an account starting with `PA`.

### Roll back the 30 Sep change only

The exact pre-change definitions are stored in the database itself:

```sql
select object_name, md5 from private.paper_config_backup
 where backup_label = 'pre_diagnostic_isolation_20260930' order by 1;
-- to restore one function:
-- do $$ begin execute (select definition from private.paper_config_backup
--   where backup_label='pre_diagnostic_isolation_20260930'
--     and object_name like 'private.alpaca_http(%'); end $$;
```

### Check for drift between git and the database

```sql
select b.object_name, md5(pg_get_functiondef(p.oid)) = b.md5 as unchanged_since_baseline, p.oid is null as dropped
  from private.paper_config_backup b
  left join (pg_proc p join pg_namespace n on n.oid = p.pronamespace)
    on n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' = b.object_name
 where b.backup_label = 'pre_diagnostic_isolation_20260930' and b.object_type = 'function'
 order by 2, 1;
```

Expected result after migration 02 (checked 30 Sep 2026):
- Changed by design (7): `alpaca_http`, `alpaca_paper_cancel_order`, `alpaca_paper_get`,
  `enforce_mj_paper_order_hold`, `guard_paper_system_config`, `paper_validate_strategy_order`,
  `paper_kill_switch_engage`.
- Dropped (1): `paper_run_diagnostic_order`, replaced by `paper_diag_run`.
- The other 18 are unchanged.

### Restore the dashboard

`functions/finance-chief-dashboard/index.ts` has the two token hashes replaced with
`<REDACTED_SHA256_OF_DASHBOARD_TOKEN>`. To redeploy, put back the SHA-256 hashes of Joe's dashboard
tokens (hashes only, never the tokens) and deploy with `verify_jwt = false`, because the function
does its own token check.
