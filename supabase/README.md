# Supabase backend

Server-side data layer for the Fantasy Football app. Mirrors nflverse stats
into Postgres on a daily cron and overlays ESPN live in-game scores via a
per-minute cron + Supabase Realtime push.

## Layout

```
supabase/
  migrations/
    20260516000000_player_cache.sql   # players_cache + player_games + seasons + live_scores
    20260516000100_cron.sql           # pg_cron schedules + edge function helper
    20260516000200_plays.sql          # plays table (slim PBP, ~35 cols)
  functions/
    sync_nflverse/index.ts            # daily: mirror stats_player CSVs (roster-only fallback off-season)
    sync_espn_live/index.ts           # per-minute: live in-game scoring
    sync_pbp/index.ts                 # daily: mirror play-by-play (streamed gz)
    sync_schedules/index.ts           # daily: mirror nflverse master schedule CSV
    sync_schedules_espn/index.ts      # daily: mirror upcoming-season schedule from ESPN (earliest source)
```

The app's season picker reads the `available_seasons` view (union of the
`seasons` table and distinct seasons in `nfl_schedules`), so an upcoming season
becomes selectable for league/draft setup as soon as its schedule is synced —
before any games are played.

## One-time setup

### 1. Install the Supabase CLI

```bash
brew install supabase/tap/supabase
supabase login
```

### 2. Link this repo to your Supabase project

From the **repo root** (the directory containing `supabase/`):

```bash
cd "/Users/jordan/Documents/Fantasy Football App"
supabase link --project-ref uxpfktjpmyhdlwfxnwri
```

You'll be prompted for the database password you set when you created the
project. (Find/reset it under Supabase Dashboard → Project Settings →
Database → Connection string → Reset.)

### 3. Apply the schema

```bash
supabase db push
```

This runs both migrations. Verify in the dashboard's Table Editor that
`players_cache`, `player_games`, `seasons`, and `live_scores` exist.

### 4. Store the two vault secrets that pg_cron needs

The cron jobs invoke edge functions over HTTP, so they need the project URL
and the **service role** key (not the anon key). Run in **Dashboard → SQL Editor**:

```sql
select vault.create_secret('https://uxpfktjpmyhdlwfxnwri.supabase.co', 'project_url');
select vault.create_secret('PASTE_SERVICE_ROLE_KEY_HERE',              'service_role_key');
```

Get the service role key from **Dashboard → Project Settings → API → service_role**.
Treat it like a password — only ever lives in Supabase vault and edge function env.

### 5. Deploy the edge functions

```bash
supabase functions deploy sync_nflverse
supabase functions deploy sync_espn_live
supabase functions deploy sync_pbp
supabase functions deploy sync_schedules
supabase functions deploy sync_schedules_espn
```

Both functions read `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` from the
edge runtime environment, which Supabase injects automatically.

### 6. Backfill historical seasons (one-time)

The default cron only syncs the current + previous season. Backfill older
years one at a time — **`{"from": 2016}` will exceed the Edge Function CPU cap**.

```bash
# Player stats — fast, ~5-15 sec each
for y in 2016 2017 2018 2019 2020 2021 2022 2023 2024 2025; do
  echo "→ stats $y"
  curl -X POST "https://uxpfktjpmyhdlwfxnwri.supabase.co/functions/v1/sync_nflverse" \
    -H "Authorization: Bearer YOUR_SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"seasons\":[$y]}"
  echo ""
done

# Simulation historical data — injuries, depth charts, inactives,
# schedule extras (spread/total/weather/roof), and per-week team
# ranks. ~10-20 sec per season. Must run AFTER sync_nflverse so the
# player_games table has the rows team_ranks_at_week reads from.
for y in 2016 2017 2018 2019 2020 2021 2022 2023 2024 2025; do
  echo "→ sim history $y"
  curl -X POST "https://uxpfktjpmyhdlwfxnwri.supabase.co/functions/v1/sync_sim_history" \
    -H "Authorization: Bearer YOUR_SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"seasons\":[$y]}"
  echo ""
done

# Historical ADP (point-in-time, late-Aug anchor): backfilled per season
# via MFL. Re-runs are idempotent — they upsert into a new snapshot_date
# of YYYY-08-25 alongside any existing rows.
for y in 2016 2017 2018 2019 2020 2021 2022 2023 2024 2025; do
  echo "→ adp $y"
  curl -X POST "https://uxpfktjpmyhdlwfxnwri.supabase.co/functions/v1/sync_mfl" \
    -H "Authorization: Bearer YOUR_SERVICE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"seasons\":[$y],\"feeds\":[\"adp\"]}"
  echo ""
done

# Play-by-play — backfill happens LOCALLY, not via Edge Function. The
# 150 MB CSV parse exceeds the free-tier Edge Function CPU cap no matter
# how we chunk it. Local Deno script bypasses caps entirely (~30-60s/season).
brew install deno   # if you don't already have it
export SUPABASE_URL=https://uxpfktjpmyhdlwfxnwri.supabase.co
export SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_KEY
cd "/Users/jordan/Documents/Fantasy Football App"
deno run --allow-net --allow-env supabase/scripts/sync_pbp_local.ts 2024 2025
```

(The `sync_pbp` Edge Function is still useful for *current-week* updates
once data is backfilled — it only needs to process ~2.5k rows then, which
fits in the cap. Daily cron is fine.)

PBP per season ~75 MB on disk including indexes. Free tier (500 MB) fits
2–3 seasons comfortably; pick the recent ones you actually want.

## Daily operation

After step 5, the cron in `20260516000100_cron.sql` runs automatically:

- **`sync_nflverse_daily`** — every day at 09:00 UTC. Pulls
  `stats_player_week_{year}.csv` from nflverse for the prior, current, and
  upcoming season; upserts to `players_cache` and `player_games`; updates
  `seasons.last_synced_at`. For the upcoming season (no stats CSV yet) it
  falls back to a roster-only refresh of `players_cache` so teams/rookies
  are ready for off-season drafts.
- **`sync_schedules_espn_daily`** — every day at 09:20 UTC. Mirrors the
  upcoming (and current) season's regular-season matchups from ESPN into
  `nfl_schedules`, using nflverse-style `game_id`s so rows merge with
  `sync_schedules`. ESPN publishes the schedule the moment the NFL releases
  it, so this surfaces a new season for draft setup ahead of the nflverse
  CSV. No-ops until ESPN has published the target season.
- **`sync_espn_live_minute`** — every minute. No-op when no NFL games are
  in progress. When games are live, hits ESPN scoreboard + per-game box
  scores, cross-references ESPN athlete IDs to nflverse player IDs via
  `players_cache.espn_id`, and upserts fantasy points to `live_scores`.
  When a game goes final, persists the final score into `player_games`
  and deletes the row from `live_scores`.
- **`sync_pbp_daily`** — every day at 10:00 UTC (one hour after stats so
  nflverse has finished writing both releases). With an empty body, syncs
  the **current week** of the current season — ~2,500 plays, fits well
  under the Edge Function CPU cap. Streams the gzipped PBP CSV through
  `DecompressionStream` → line splitter; cheap per-row prefilter on the
  `week` column (just finds the Nth comma without parsing the whole line)
  skips non-matching rows; stream aborts once we move past the target
  week. For full-season backfill, invoke per-week (see the loop above).

## Querying play-by-play

The `plays` table is denormalized — every row stands alone and the player
ID columns are joinable to `players_cache.id`. Examples:

```sql
-- All touchdowns by a specific player in 2025
select week, posteam, defteam, description, yards_gained, epa
from plays
where season = 2025 and touchdown = true and td_player_id = '00-0036389'
order by week, play_id;

-- Top 10 most-targeted receivers in 2025
select p.name, p.team, count(*) as targets
from plays pl
join players_cache p on p.id = pl.receiver_player_id
where pl.season = 2025 and pl.pass_attempt = true
group by p.name, p.team
order by targets desc limit 10;

-- A player's average EPA per play, weeks 1-8
select avg(epa)::numeric(5,3) as epa_per_play, count(*) as plays
from plays
where season = 2025 and week between 1 and 8
  and (rusher_player_id = '00-0036223' or receiver_player_id = '00-0036223');
```

## Verify it's working

```sql
-- Should show 2024, 2025, and (when nflverse publishes 2026) 2026
select * from seasons order by season desc;

-- Should show recent timestamps after the next 09:00 UTC tick
select season, last_synced_at, games_count from seasons;

-- Should be empty outside of game windows
select count(*) from live_scores;

-- Watch a recent cron run
select jobname, last_run_time, last_run_status from cron.job_run_details
  order by last_run_time desc limit 10;
```

## Manual invocation while iterating

```bash
# Sync just 2025
curl -X POST "https://uxpfktjpmyhdlwfxnwri.supabase.co/functions/v1/sync_nflverse" \
  -H "Authorization: Bearer YOUR_SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"seasons":[2025]}'

# Force the live-score worker to run once
curl -X POST "https://uxpfktjpmyhdlwfxnwri.supabase.co/functions/v1/sync_espn_live" \
  -H "Authorization: Bearer YOUR_SERVICE_KEY"
```

## Storage budget

- `players_cache`: ~3K rows × ~200B = ~600 KB
- `player_games`: ~3K players × 18 weeks × 1 KB = ~54 MB per season
- `plays`: ~45K rows × 35 cols ≈ ~75 MB per season (with indexes)
- For two seasons of stats + two seasons of PBP: ~260 MB. Three seasons of
  PBP pushes you over the 500 MB free tier — rotate older PBP out or move
  to Pro ($25/mo, 8 GB).

If you need to keep many historical seasons, summarize older ones (drop
`player_games` rows older than 3 seasons; keep season aggregates only).

## Push notifications

The `send_push` Edge Function delivers admin-composed notifications via APNs
(token-based auth, HTTP/2). The `push_notifications` table is both the compose
queue and the history; the `dispatch_push_minute` cron runs it every minute for
anything that's due, and the app invokes it directly for "send now". Device
tokens live in `device_tokens` (one row per device, registered on launch).

One-time setup (in addition to `supabase db push`, which creates the tables and
the cron):

1. **Store the APNs secrets** in Dashboard → Edge Functions → Secrets:

   ```
   APNS_KEY        = <full contents of the .p8 file, incl. BEGIN/END lines>
   APNS_KEY_ID     = <10-char Key ID for that .p8>
   APNS_TEAM_ID    = <Apple Developer Team ID>
   APNS_BUNDLE_ID  = com.personal.Tarsa-Fantasy
   ```

2. **Deploy the function:**

   ```bash
   supabase functions deploy send_push
   ```

The cron uses the existing `project_url` / `service_role_key` vault secrets, so
no extra vault entries are needed. Verify with:

```sql
select jobname, last_run_time, last_run_status from cron.job_run_details
  where jobname = 'dispatch_push_minute' order by last_run_time desc limit 5;
```
