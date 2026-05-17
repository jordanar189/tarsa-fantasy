-- Admin-controlled global settings. Single row per key; value is a JSON
-- blob so we can grow the surface without schema changes for each new flag.
--
-- Also formalizes the admin concept: profiles.is_admin replaces the
-- client-only AdminConfig allowlist for any server-side decisions. The
-- client allowlist still seeds is_admin on the migration and stays as the
-- UI fallback if the DB column hasn't been populated for someone yet.

-- 1. profiles.is_admin
alter table public.profiles
    add column if not exists is_admin boolean not null default false;

-- Seed from the hard-coded allowlist. Add new admins here OR flip is_admin
-- directly in the Supabase dashboard later.
update public.profiles
   set is_admin = true
 where lower(username) in ('jordanar189');

-- 2. app_settings table
create table if not exists public.app_settings (
    key         text primary key,
    value       jsonb not null,
    updated_at  timestamptz not null default now(),
    updated_by  uuid
);

-- Default flags. Insert idempotently so re-running the migration is a no-op.
insert into public.app_settings (key, value)
values ('testing_environment_enabled', to_jsonb(false))
on conflict (key) do nothing;

-- 3. RLS
alter table public.app_settings enable row level security;

drop policy if exists "app_settings_read"  on public.app_settings;
drop policy if exists "app_settings_write" on public.app_settings;

create policy "app_settings_read"
    on public.app_settings for select
    using (auth.role() = 'authenticated');

create policy "app_settings_write"
    on public.app_settings for all
    using (
        exists (
            select 1 from public.profiles p
            where p.id = auth.uid() and p.is_admin = true
        )
    )
    with check (
        exists (
            select 1 from public.profiles p
            where p.id = auth.uid() and p.is_admin = true
        )
    );

-- 4. Realtime: push app_settings changes so non-admin clients flip the
-- Testing Environment menu item immediately when an admin enables it.
do $$
begin
    if exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_settings'
    ) then
        alter publication supabase_realtime drop table public.app_settings;
    end if;
    alter publication supabase_realtime add table public.app_settings;
end$$;
