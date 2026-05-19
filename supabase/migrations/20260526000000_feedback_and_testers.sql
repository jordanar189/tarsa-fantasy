-- Tester role + in-app feedback.
--
-- Adds a `tester` capability alongside the existing `is_admin` flag so a
-- small group of reviewers can reach the in-app feedback composer without
-- being full admins. Admins grant/revoke the role from another user's
-- profile via set_tester_role().
--
-- Feedback rows are written by testers/admins and read back by admins for
-- triage. Screenshot attachments live in the public `feedback-images`
-- bucket, namespaced by the author's user_id so the storage RLS can gate
-- writes to the author.

-- ---------------------------------------------------------------------------
-- 1. profiles.is_tester
-- ---------------------------------------------------------------------------

alter table public.profiles
    add column if not exists is_tester boolean not null default false;

-- Shared admin check, security definer so it can read profiles under RLS.
create or replace function public.is_app_admin()
returns boolean
language sql stable security definer set search_path = public, auth as $$
    select exists (
        select 1 from public.profiles p
         where p.id = auth.uid() and p.is_admin = true
    );
$$;

grant execute on function public.is_app_admin() to authenticated;

-- set_tester_role: admin-only grant/revoke of the tester flag on a profile.
create or replace function public.set_tester_role(p_user uuid, p_is_tester boolean)
returns public.profiles
language plpgsql security definer set search_path = public, auth
as $$
declare
    row public.profiles;
begin
    if auth.uid() is null then raise exception 'unauthenticated'; end if;
    if not public.is_app_admin() then raise exception 'not authorized'; end if;

    update public.profiles
       set is_tester = p_is_tester
     where id = p_user
    returning * into row;

    if row.id is null then raise exception 'no such user'; end if;
    return row;
end$$;

grant execute on function public.set_tester_role(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. feedback
-- ---------------------------------------------------------------------------

create table if not exists public.feedback (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users(id) on delete cascade,
    content     text not null default '',
    image_urls  text[] not null default '{}',
    status      text not null default 'open'
                check (status in ('open', 'resolved')),
    created_at  timestamptz not null default now(),
    -- coalesce so an empty array (array_length -> NULL) doesn't let a
    -- fully-empty row slip past the CHECK (NULL wouldn't evaluate to false).
    check (char_length(btrim(content)) > 0 or coalesce(array_length(image_urls, 1), 0) > 0)
);

create index if not exists feedback_created_idx on public.feedback (created_at desc);
create index if not exists feedback_user_idx    on public.feedback (user_id);

alter table public.feedback enable row level security;

drop policy if exists "feedback_read"   on public.feedback;
drop policy if exists "feedback_insert" on public.feedback;
drop policy if exists "feedback_update" on public.feedback;
drop policy if exists "feedback_delete" on public.feedback;

-- Authors can see their own; admins see everything.
create policy "feedback_read"
    on public.feedback for select
    using (user_id = auth.uid() or public.is_app_admin());

-- Only testers/admins may file feedback, and only as themselves.
create policy "feedback_insert"
    on public.feedback for insert
    with check (
        user_id = auth.uid()
        and exists (
            select 1 from public.profiles p
             where p.id = auth.uid()
               and (p.is_tester = true or p.is_admin = true)
        )
    );

-- Only admins triage (flip status).
create policy "feedback_update"
    on public.feedback for update
    using (public.is_app_admin())
    with check (public.is_app_admin());

create policy "feedback_delete"
    on public.feedback for delete
    using (user_id = auth.uid() or public.is_app_admin());

-- ---------------------------------------------------------------------------
-- 3. feedback image storage
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
    values ('feedback-images', 'feedback-images', true)
    on conflict (id) do nothing;

drop policy if exists "feedback_images_upload" on storage.objects;
create policy "feedback_images_upload"
    on storage.objects for insert
    with check (
        bucket_id = 'feedback-images'
        and auth.role() = 'authenticated'
        and (storage.foldername(name))[1] = auth.uid()::text
        and exists (
            select 1 from public.profiles p
             where p.id = auth.uid()
               and (p.is_tester = true or p.is_admin = true)
        )
    );

drop policy if exists "feedback_images_read" on storage.objects;
create policy "feedback_images_read"
    on storage.objects for select
    using (bucket_id = 'feedback-images');
