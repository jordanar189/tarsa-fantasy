-- Player news: ESPN NFL headlines mirrored hourly by the sync_news edge
-- function. Articles are tagged with the local player ids resolved from
-- ESPN athlete ids (players_cache.espn_id), so the app can filter the feed
-- per player as well as show the league-wide stream.

create table if not exists public.player_news (
    id          text primary key,               -- ESPN article id
    headline    text not null,
    description text,
    published   timestamptz not null,
    url         text,
    image_url   text,
    player_ids  text[] not null default '{}',   -- local (gsis) ids of tagged athletes
    source      text not null default 'espn',
    created_at  timestamptz not null default now()
);
create index if not exists player_news_published_idx on public.player_news (published desc);
create index if not exists player_news_players_idx on public.player_news using gin (player_ids);

alter table public.player_news enable row level security;
drop policy if exists "player_news_read" on public.player_news;
create policy "player_news_read"
    on public.player_news for select using (auth.role() = 'authenticated');

-- Hourly: headlines move all day during the season, and the feed is cheap
-- (one JSON endpoint, upsert on article id).
select cron.unschedule('sync_news_hourly')
    where exists (select 1 from cron.job where jobname = 'sync_news_hourly');
select cron.schedule(
    'sync_news_hourly',
    '20 * * * *',
    $$select public.invoke_edge_function('sync_news')$$
);
