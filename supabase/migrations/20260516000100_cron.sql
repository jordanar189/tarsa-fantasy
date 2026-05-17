-- Cron schedules for the sync Edge Functions. Requires pg_cron + pg_net,
-- which are pre-installed on Supabase but must be enabled per-project.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Helper: build the Edge Function invocation. SUPABASE_URL and the
-- service-role JWT live in vault.decrypted_secrets (set via dashboard):
--   project_url     – e.g. https://uxpfktjpmyhdlwfxnwri.supabase.co
--   service_role_key – the service role JWT (NOT the anon key)
-- See the deployment README for how to set them.

create or replace function public.invoke_edge_function(fn text, body jsonb default '{}')
returns void language plpgsql security definer as $$
declare
    base text;
    key  text;
begin
    select decrypted_secret into base from vault.decrypted_secrets where name = 'project_url';
    select decrypted_secret into key  from vault.decrypted_secrets where name = 'service_role_key';
    if base is null or key is null then
        raise warning 'invoke_edge_function(%): project_url or service_role_key vault secret missing', fn;
        return;
    end if;
    perform net.http_post(
        url     := base || '/functions/v1/' || fn,
        headers := jsonb_build_object(
            'Content-Type',  'application/json',
            'Authorization', 'Bearer ' || key
        ),
        body    := body
    );
end$$;

-- Schedule daily nflverse sync at 09:00 UTC (early morning ET, after any
-- overnight stat corrections have settled).
select cron.unschedule('sync_nflverse_daily') where exists (select 1 from cron.job where jobname = 'sync_nflverse_daily');
select cron.schedule(
    'sync_nflverse_daily',
    '0 9 * * *',
    $$select public.invoke_edge_function('sync_nflverse')$$
);

-- Schedule ESPN live sync every minute. The function itself is a no-op when
-- no games are in progress, so off-season this is essentially free.
select cron.unschedule('sync_espn_live_minute') where exists (select 1 from cron.job where jobname = 'sync_espn_live_minute');
select cron.schedule(
    'sync_espn_live_minute',
    '* * * * *',
    $$select public.invoke_edge_function('sync_espn_live')$$
);

-- Schedule play-by-play sync at 10:00 UTC, an hour after sync_nflverse so
-- nflverse has time to finish writing both releases. Only syncs current +
-- previous season; older years need manual backfill (per-season).
select cron.unschedule('sync_pbp_daily') where exists (select 1 from cron.job where jobname = 'sync_pbp_daily');
select cron.schedule(
    'sync_pbp_daily',
    '0 10 * * *',
    $$select public.invoke_edge_function('sync_pbp')$$
);
