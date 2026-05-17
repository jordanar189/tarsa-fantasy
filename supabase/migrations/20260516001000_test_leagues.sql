-- Test/Testing Environment leagues. is_test marks a league as a sandbox
-- created from the Admin menu; simulated_week is the league-local fantasy
-- week the admin has time-traveled to (0 = preseason, 1..N = regular
-- season, N+1 = postseason). Non-test leagues leave both at their defaults
-- and the simulated_week column is ignored.

alter table public.leagues
    add column if not exists is_test         boolean not null default false,
    add column if not exists simulated_week  int;

create index if not exists leagues_is_test_idx on public.leagues (is_test) where is_test = true;
