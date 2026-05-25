-- Push notifications: APNs device-token registry + admin-composed notifications
-- with targeting and scheduling, plus a per-minute cron that dispatches due
-- notifications through the `send_push` Edge Function.
--
-- Builds on:
--   • is_app_admin()                (feedback_and_testers migration)
--   • invoke_edge_function() + the project_url / service_role_key vault secrets
--     (cron migration)
--
-- The actual APNs delivery lives in supabase/functions/send_push. The sender
-- runs as service_role, so it bypasses RLS and can read every device token.

-- ---------------------------------------------------------------------------
-- 1. device_tokens
-- ---------------------------------------------------------------------------

create table if not exists public.device_tokens (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users(id) on delete cascade,
    token       text not null unique,
    platform    text not null default 'ios',
    -- A debug build's token is only valid against the APNs sandbox; a
    -- TestFlight/App Store build's token is production. The sender picks the
    -- host per token from this column.
    environment text not null default 'production'
                check (environment in ('sandbox', 'production')),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create index if not exists device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;

drop policy if exists "device_tokens_select" on public.device_tokens;
drop policy if exists "device_tokens_modify" on public.device_tokens;

-- Users can read their own tokens. Writes go through the security-definer RPCs
-- below (so re-registering a token previously owned by another account on a
-- shared device doesn't trip per-row RLS).
create policy "device_tokens_select"
    on public.device_tokens for select
    using (user_id = auth.uid());

-- register_device_token: upsert the caller's token for this device.
create or replace function public.register_device_token(
    p_token text, p_environment text default 'production'
)
returns void
language plpgsql security definer set search_path = public, auth
as $$
begin
    if auth.uid() is null then raise exception 'unauthenticated'; end if;
    insert into public.device_tokens (user_id, token, platform, environment, updated_at)
    values (
        auth.uid(), p_token, 'ios',
        case when p_environment in ('sandbox', 'production') then p_environment else 'production' end,
        now()
    )
    on conflict (token) do update
        set user_id     = excluded.user_id,
            environment = excluded.environment,
            updated_at  = now();
end$$;

grant execute on function public.register_device_token(text, text) to authenticated;

-- unregister_device_token: drop this device's token on sign-out. Scoped to the
-- caller's own row — even though it's security definer, a leaked token value
-- must not let one account delete another account's registration.
create or replace function public.unregister_device_token(p_token text)
returns void
language plpgsql security definer set search_path = public, auth
as $$
begin
    if auth.uid() is null then return; end if;
    delete from public.device_tokens
     where token = p_token and user_id = auth.uid();
end$$;

grant execute on function public.unregister_device_token(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. push_notifications (admin-composed; history + scheduling queue)
-- ---------------------------------------------------------------------------

create table if not exists public.push_notifications (
    id              uuid primary key default gen_random_uuid(),
    created_by      uuid references auth.users(id) on delete set null,
    title           text not null,
    body            text not null default '',
    image_url       text,
    deep_link       text,
    target          text not null default 'all' check (target in ('all', 'users')),
    target_user_ids uuid[] not null default '{}',
    -- null = send as soon as the sender next runs (immediately).
    scheduled_at    timestamptz,
    status          text not null default 'scheduled'
                    check (status in ('scheduled', 'sending', 'sent', 'failed', 'canceled')),
    -- When the sender claimed the row (status → 'sending'). Used as a lease so a
    -- row stranded in 'sending' (sender crash/timeout) is reclaimed and retried.
    sending_at      timestamptz,
    sent_at         timestamptz,
    sent_count      int not null default 0,
    fail_count      int not null default 0,
    error           text,
    created_at      timestamptz not null default now()
);

create index if not exists push_notifications_due_idx
    on public.push_notifications (status, scheduled_at);

alter table public.push_notifications enable row level security;

drop policy if exists "push_notifications_admin_all" on public.push_notifications;

-- Composing, listing, and canceling are admin-only. The sender uses
-- service_role and is unaffected by this policy.
create policy "push_notifications_admin_all"
    on public.push_notifications for all
    using (public.is_app_admin())
    with check (public.is_app_admin());

-- Stamp created_by from the authenticated caller so the client never has to
-- send it (and can't spoof it).
create or replace function public.push_notifications_set_creator()
returns trigger language plpgsql security definer set search_path = public, auth
as $$
begin
    new.created_by := auth.uid();
    return new;
end$$;

drop trigger if exists push_notifications_set_creator on public.push_notifications;
create trigger push_notifications_set_creator
    before insert on public.push_notifications
    for each row execute function public.push_notifications_set_creator();

-- Atomically claim sendable notifications and flip them to 'sending'. Claims:
--   • due rows (scheduled, scheduled_at null or past), and
--   • rows stuck in 'sending' past the lease — so a sender that died mid-flight
--     gets its work retried instead of stranding the notification forever.
-- `for update skip locked` keeps overlapping sender runs from double-claiming.
-- Pass p_id to claim one specific row (the app's "send now" path). Returns the
-- claimed rows so the sender works only on what it owns.
create or replace function public.claim_push_notifications(
    p_id uuid default null,
    p_limit int default 50,
    p_lease_seconds int default 300
)
returns setof public.push_notifications
language sql security definer set search_path = public, pg_temp
as $$
    update public.push_notifications n
       set status = 'sending', sending_at = now()
     where n.id in (
         select c.id from public.push_notifications c
          where case
                  when p_id is not null then c.id = p_id and c.status = 'scheduled'
                  else (c.status = 'scheduled' and (c.scheduled_at is null or c.scheduled_at <= now()))
                    or (c.status = 'sending'   and c.sending_at < now() - make_interval(secs => p_lease_seconds))
                end
          order by c.created_at
          limit p_limit
          for update skip locked
       )
    returning n.*;
$$;

grant execute on function public.claim_push_notifications(uuid, int, int) to service_role;

-- ---------------------------------------------------------------------------
-- 3. notification image storage
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
    values ('notification-images', 'notification-images', true)
    on conflict (id) do nothing;

drop policy if exists "notification_images_upload" on storage.objects;
create policy "notification_images_upload"
    on storage.objects for insert
    with check (
        bucket_id = 'notification-images'
        and auth.role() = 'authenticated'
        and public.is_app_admin()
    );

drop policy if exists "notification_images_read" on storage.objects;
create policy "notification_images_read"
    on storage.objects for select
    using (bucket_id = 'notification-images');

-- ---------------------------------------------------------------------------
-- 4. dispatch cron — every minute, send anything that's due
-- ---------------------------------------------------------------------------

select cron.unschedule('dispatch_push_minute')
    where exists (select 1 from cron.job where jobname = 'dispatch_push_minute');
select cron.schedule(
    'dispatch_push_minute',
    '* * * * *',
    $$select public.invoke_edge_function('send_push')$$
);
