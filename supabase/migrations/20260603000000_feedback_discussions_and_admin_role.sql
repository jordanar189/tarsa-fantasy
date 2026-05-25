-- Feedback discussions + admin role management.
--
-- Builds on the feedback/tester layer (20260526000000_feedback_and_testers):
--
-- 1. feedback_comments: a discussion thread attached to each feedback item so
--    the author and admins can go back and forth (repro steps, follow-ups,
--    "fixed in build 42"). Readable/writable by whoever can already read the
--    parent feedback row — its author or any admin.
--
-- 2. set_admin_role(): admin-only grant/revoke of the is_admin flag, mirroring
--    set_tester_role() so an admin can promote other users from their profile.

-- ---------------------------------------------------------------------------
-- 1. feedback_comments
-- ---------------------------------------------------------------------------

create table if not exists public.feedback_comments (
    id          uuid primary key default gen_random_uuid(),
    feedback_id uuid not null references public.feedback(id) on delete cascade,
    user_id     uuid not null references auth.users(id) on delete cascade,
    content     text not null,
    created_at  timestamptz not null default now(),
    check (char_length(btrim(content)) > 0)
);

create index if not exists feedback_comments_feedback_idx
    on public.feedback_comments (feedback_id, created_at);

alter table public.feedback_comments enable row level security;

-- Shared visibility check: can the caller see this feedback row at all?
-- Security definer so it can read feedback under RLS without recursion.
create or replace function public.can_access_feedback(p_feedback_id uuid)
returns boolean
language sql stable security definer set search_path = public, auth as $$
    select exists (
        select 1 from public.feedback f
         where f.id = p_feedback_id
           and (f.user_id = auth.uid() or public.is_app_admin())
    );
$$;

grant execute on function public.can_access_feedback(uuid) to authenticated;

drop policy if exists "feedback_comments_read"   on public.feedback_comments;
drop policy if exists "feedback_comments_insert" on public.feedback_comments;
drop policy if exists "feedback_comments_delete" on public.feedback_comments;

-- Author of the feedback + admins can read the discussion.
create policy "feedback_comments_read"
    on public.feedback_comments for select
    using (public.can_access_feedback(feedback_id));

-- Same set can post, and only as themselves.
create policy "feedback_comments_insert"
    on public.feedback_comments for insert
    with check (
        user_id = auth.uid()
        and public.can_access_feedback(feedback_id)
    );

create policy "feedback_comments_delete"
    on public.feedback_comments for delete
    using (user_id = auth.uid() or public.is_app_admin());

-- ---------------------------------------------------------------------------
-- 2. set_admin_role
-- ---------------------------------------------------------------------------

-- Admin-only grant/revoke of the is_admin flag on a profile. Re-checks the
-- caller server-side so a tampered client can't promote itself.
create or replace function public.set_admin_role(p_user uuid, p_is_admin boolean)
returns public.profiles
language plpgsql security definer set search_path = public, auth
as $$
declare
    row public.profiles;
begin
    if auth.uid() is null then raise exception 'unauthenticated'; end if;
    if not public.is_app_admin() then raise exception 'not authorized'; end if;

    update public.profiles
       set is_admin = p_is_admin
     where id = p_user
    returning * into row;

    if row.id is null then raise exception 'no such user'; end if;
    return row;
end$$;

grant execute on function public.set_admin_role(uuid, boolean) to authenticated;
