-- Per-user theme preference. Drives whether the app renders light, dark,
-- or follows the device's system setting. Default is 'dark' so existing
-- users see no visual change after the migration runs.
--
-- Stored as text with a CHECK constraint rather than an enum so we can
-- grow the surface (e.g. "auto-night") without a schema migration.

alter table public.profiles
    add column if not exists theme text not null default 'dark'
        check (theme in ('system', 'light', 'dark'));

-- Read: any signed-in user can read their own theme (selects already use
-- "id = auth.uid()" in app code). Update: own row only.
drop policy if exists "profiles_update_theme_self" on public.profiles;
create policy "profiles_update_theme_self"
    on public.profiles for update
    using (id = auth.uid())
    with check (id = auth.uid());
