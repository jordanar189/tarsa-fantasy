-- Taxi (practice) squad support.
--
-- Per-team taxi membership is a plain text[] column mirroring teams.ir: a subset
-- of the roster whose players never score and don't count against the active
-- roster size. Writes go through the same owner/commish team-update path as
-- starters/ir (setLineup), so no new RLS policy is required.
--
-- The taxi *configuration* (slot count + max-experience eligibility) lives
-- inside leagues.roster_config (JSONB) as the `taxi` / `taxiMaxExperience` keys,
-- so the leagues table needs no change.

alter table public.teams
    add column if not exists taxi text[] not null default '{}';
