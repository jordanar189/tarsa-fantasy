-- Configurable playoff round length: 1 or 2 fantasy weeks per round.
--
-- A plain additive column on leagues. The playoff START week is derived from
-- regular_season_weeks (playoffs begin the week after), so no new column is
-- needed for it — the settings UI changes regular_season_weeks (and regenerates
-- the prefix-stable round-robin schedule) when the commissioner moves the start.
alter table public.leagues
    add column if not exists weeks_per_round int not null default 1;
