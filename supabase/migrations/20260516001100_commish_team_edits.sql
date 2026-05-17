-- Let the commissioner update any team in their league (roster, starters,
-- name). The pre-existing owner-only policy on public.teams stays in place
-- — RLS is permissive, so either policy granting access lets the row pass.

drop policy if exists "teams_commish_update" on public.teams;

create policy "teams_commish_update"
    on public.teams for update
    using (
        exists (
            select 1 from public.leagues l
            where l.id = teams.league_id and l.creator_id = auth.uid()
        )
    )
    with check (
        exists (
            select 1 from public.leagues l
            where l.id = teams.league_id and l.creator_id = auth.uid()
        )
    );
