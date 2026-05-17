-- Phase 1 of the stats overhaul. Brings in:
--   • Player bio columns (age, size, college, draft pick, jersey, status, bye)
--   • Full NFL schedule + final scores (nfl_schedules)
--   • Team metadata for logos/colors/divisions (nfl_teams, seeded once)
--   • Offensive snap counts per player per game (snap_counts)

-- 1. Player bio fields on players_cache.
alter table public.players_cache
    add column if not exists birth_date     date,
    add column if not exists height_in      int,
    add column if not exists weight_lb      int,
    add column if not exists college        text,
    add column if not exists jersey_number  int,
    add column if not exists draft_year     int,
    add column if not exists draft_round    int,
    add column if not exists draft_pick     int,
    add column if not exists years_exp      int,
    add column if not exists status         text,
    add column if not exists bye_week       int;

-- 2. NFL schedules + scores
create table if not exists public.nfl_schedules (
    game_id      text primary key,
    season       int  not null,
    week         int  not null,
    home_team    text not null,
    away_team    text not null,
    kickoff      timestamptz,
    home_score   int,
    away_score   int,
    status       text not null default 'scheduled',  -- 'scheduled' | 'in_progress' | 'final'
    updated_at   timestamptz not null default now()
);
create index if not exists nfl_schedules_season_week_idx on public.nfl_schedules (season, week);
create index if not exists nfl_schedules_home_idx        on public.nfl_schedules (season, home_team);
create index if not exists nfl_schedules_away_idx        on public.nfl_schedules (season, away_team);

alter table public.nfl_schedules enable row level security;
drop policy if exists "nfl_schedules_read" on public.nfl_schedules;
create policy "nfl_schedules_read" on public.nfl_schedules
    for select using (auth.role() = 'authenticated');

-- 3. NFL team metadata — seeded once from a static list, never re-synced.
create table if not exists public.nfl_teams (
    abbr             text primary key,
    full_name        text not null,
    conference       text not null,    -- 'AFC' | 'NFC'
    division         text not null,    -- 'East' | 'North' | 'South' | 'West'
    primary_color    text,             -- '#RRGGBB'
    secondary_color  text,
    logo_url         text
);
alter table public.nfl_teams enable row level security;
drop policy if exists "nfl_teams_read" on public.nfl_teams;
create policy "nfl_teams_read" on public.nfl_teams
    for select using (auth.role() = 'authenticated');

-- 32-team seed. Logos use ESPN's stable team-logo CDN.
insert into public.nfl_teams (abbr, full_name, conference, division, primary_color, secondary_color, logo_url) values
    ('ARI', 'Arizona Cardinals',     'NFC', 'West',  '#97233F', '#000000', 'https://a.espncdn.com/i/teamlogos/nfl/500/ari.png'),
    ('ATL', 'Atlanta Falcons',       'NFC', 'South', '#A71930', '#000000', 'https://a.espncdn.com/i/teamlogos/nfl/500/atl.png'),
    ('BAL', 'Baltimore Ravens',      'AFC', 'North', '#241773', '#000000', 'https://a.espncdn.com/i/teamlogos/nfl/500/bal.png'),
    ('BUF', 'Buffalo Bills',         'AFC', 'East',  '#00338D', '#C60C30', 'https://a.espncdn.com/i/teamlogos/nfl/500/buf.png'),
    ('CAR', 'Carolina Panthers',     'NFC', 'South', '#0085CA', '#101820', 'https://a.espncdn.com/i/teamlogos/nfl/500/car.png'),
    ('CHI', 'Chicago Bears',         'NFC', 'North', '#0B162A', '#C83803', 'https://a.espncdn.com/i/teamlogos/nfl/500/chi.png'),
    ('CIN', 'Cincinnati Bengals',    'AFC', 'North', '#FB4F14', '#000000', 'https://a.espncdn.com/i/teamlogos/nfl/500/cin.png'),
    ('CLE', 'Cleveland Browns',      'AFC', 'North', '#311D00', '#FF3C00', 'https://a.espncdn.com/i/teamlogos/nfl/500/cle.png'),
    ('DAL', 'Dallas Cowboys',        'NFC', 'East',  '#003594', '#869397', 'https://a.espncdn.com/i/teamlogos/nfl/500/dal.png'),
    ('DEN', 'Denver Broncos',        'AFC', 'West',  '#FB4F14', '#002244', 'https://a.espncdn.com/i/teamlogos/nfl/500/den.png'),
    ('DET', 'Detroit Lions',         'NFC', 'North', '#0076B6', '#B0B7BC', 'https://a.espncdn.com/i/teamlogos/nfl/500/det.png'),
    ('GB',  'Green Bay Packers',     'NFC', 'North', '#203731', '#FFB612', 'https://a.espncdn.com/i/teamlogos/nfl/500/gb.png'),
    ('HOU', 'Houston Texans',        'AFC', 'South', '#03202F', '#A71930', 'https://a.espncdn.com/i/teamlogos/nfl/500/hou.png'),
    ('IND', 'Indianapolis Colts',    'AFC', 'South', '#002C5F', '#A2AAAD', 'https://a.espncdn.com/i/teamlogos/nfl/500/ind.png'),
    ('JAX', 'Jacksonville Jaguars',  'AFC', 'South', '#101820', '#D7A22A', 'https://a.espncdn.com/i/teamlogos/nfl/500/jax.png'),
    ('KC',  'Kansas City Chiefs',    'AFC', 'West',  '#E31837', '#FFB81C', 'https://a.espncdn.com/i/teamlogos/nfl/500/kc.png'),
    ('LV',  'Las Vegas Raiders',     'AFC', 'West',  '#000000', '#A5ACAF', 'https://a.espncdn.com/i/teamlogos/nfl/500/lv.png'),
    ('LAC', 'Los Angeles Chargers',  'AFC', 'West',  '#0080C6', '#FFC20E', 'https://a.espncdn.com/i/teamlogos/nfl/500/lac.png'),
    ('LAR', 'Los Angeles Rams',      'NFC', 'West',  '#003594', '#FFA300', 'https://a.espncdn.com/i/teamlogos/nfl/500/lar.png'),
    ('MIA', 'Miami Dolphins',        'AFC', 'East',  '#008E97', '#FC4C02', 'https://a.espncdn.com/i/teamlogos/nfl/500/mia.png'),
    ('MIN', 'Minnesota Vikings',     'NFC', 'North', '#4F2683', '#FFC62F', 'https://a.espncdn.com/i/teamlogos/nfl/500/min.png'),
    ('NE',  'New England Patriots',  'AFC', 'East',  '#002244', '#C60C30', 'https://a.espncdn.com/i/teamlogos/nfl/500/ne.png'),
    ('NO',  'New Orleans Saints',    'NFC', 'South', '#D3BC8D', '#101820', 'https://a.espncdn.com/i/teamlogos/nfl/500/no.png'),
    ('NYG', 'New York Giants',       'NFC', 'East',  '#0B2265', '#A71930', 'https://a.espncdn.com/i/teamlogos/nfl/500/nyg.png'),
    ('NYJ', 'New York Jets',         'AFC', 'East',  '#125740', '#000000', 'https://a.espncdn.com/i/teamlogos/nfl/500/nyj.png'),
    ('PHI', 'Philadelphia Eagles',   'NFC', 'East',  '#004C54', '#A5ACAF', 'https://a.espncdn.com/i/teamlogos/nfl/500/phi.png'),
    ('PIT', 'Pittsburgh Steelers',   'AFC', 'North', '#FFB612', '#101820', 'https://a.espncdn.com/i/teamlogos/nfl/500/pit.png'),
    ('SF',  'San Francisco 49ers',   'NFC', 'West',  '#AA0000', '#B3995D', 'https://a.espncdn.com/i/teamlogos/nfl/500/sf.png'),
    ('SEA', 'Seattle Seahawks',      'NFC', 'West',  '#002244', '#69BE28', 'https://a.espncdn.com/i/teamlogos/nfl/500/sea.png'),
    ('TB',  'Tampa Bay Buccaneers',  'NFC', 'South', '#D50A0A', '#FF7900', 'https://a.espncdn.com/i/teamlogos/nfl/500/tb.png'),
    ('TEN', 'Tennessee Titans',      'AFC', 'South', '#0C2340', '#4B92DB', 'https://a.espncdn.com/i/teamlogos/nfl/500/ten.png'),
    ('WAS', 'Washington Commanders', 'NFC', 'East',  '#5A1414', '#FFB612', 'https://a.espncdn.com/i/teamlogos/nfl/500/wsh.png')
on conflict (abbr) do nothing;

-- 4. Per-player per-game snap counts.
create table if not exists public.snap_counts (
    player_id      text not null,
    season         int  not null,
    week           int  not null,
    offense_snaps  int  not null default 0,
    offense_pct    numeric(5,2) not null default 0,
    team           text,
    primary key (player_id, season, week)
);
create index if not exists snap_counts_season_week_idx on public.snap_counts (season, week);

alter table public.snap_counts enable row level security;
drop policy if exists "snap_counts_read" on public.snap_counts;
create policy "snap_counts_read" on public.snap_counts
    for select using (auth.role() = 'authenticated');
