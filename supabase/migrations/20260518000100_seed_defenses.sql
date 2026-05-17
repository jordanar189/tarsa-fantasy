-- Seed one synthetic "team defense" player per NFL team so the new DEF
-- roster slot can be filled by the auto-pick / commish picker / waivers.
-- These rows score 0 fantasy points for now — real DST scoring is a
-- follow-up (needs a sacks/ints/points-allowed source).
--
-- IDs follow the convention "DEF_<TEAM>" (e.g. "DEF_KC") so the rows are
-- easy to recognize and won't collide with nflverse GSIS player IDs
-- (which are formatted "00-XXXXXXX"). Headshots use the team logo from
-- the existing nfl_teams.logo_url column.

insert into public.players_cache (
    id, name, position, position_group, team, headshot_url
)
select
    'DEF_' || abbr,
    full_name || ' Defense',
    'DEF',
    'DEF',
    abbr,
    coalesce(logo_url, '')
from public.nfl_teams
on conflict (id) do nothing;
