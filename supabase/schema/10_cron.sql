-- pg_cron jobs that touch the Alpaca PAPER desk (UTC). Exported 30 Sep 2026.
-- Trading 212 and Telegram jobs in the same database are listed in docs/mj-paper-operations.md
-- and are not part of the paper desk.
--
-- US regular session: 13:30-20:00 UTC while New York is on EDT (to 1 Nov 2026),
--                     14:30-21:00 UTC while New York is on EST (from 2 Nov 2026).

select cron.schedule('alpaca_paper_health_check',  '*/30 * * * *',  $$ select public.fn_paper_health_check(); $$);
select cron.schedule('paper_diag_window_expiry',   '*/5 * * * *',   $$ select private.paper_diag_expire(); $$);
select cron.schedule('alpaca_paper_sync_request',  '5 21 * * 1-5',  $$ SELECT public.fn_sync_alpaca_paper(); $$);
select cron.schedule('alpaca_paper_sync_process',  '15 21 * * 1-5', $$ SELECT public.fn_process_alpaca_responses(); $$);
select cron.schedule('price_fetch_request',        '20 21 * * 1-5', $$ SELECT public.fn_fetch_prices(); $$);
select cron.schedule('price_fetch_process',        '25 21 * * 1-5', $$ SELECT public.fn_process_prices(); $$);
select cron.schedule('tripwire_evaluation',        '30 21 * * 1-5', $$ SELECT public.fn_evaluate_tripwires(); $$);
select cron.schedule('price_fetch_request_pm',     '20 16 * * 1-5', $$ SELECT public.fn_fetch_prices(); $$);
select cron.schedule('price_fetch_process_pm',     '25 16 * * 1-5', $$ SELECT public.fn_process_prices(); $$);
select cron.schedule('tripwire_evaluation_pm',     '30 16 * * 1-5', $$ SELECT public.fn_evaluate_tripwires(); $$);
