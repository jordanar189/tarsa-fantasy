-- App-wide trending players: aggregate completed transactions from the
-- given time window and return (player_id, adds, drops). Returned ordered
-- by total activity descending so callers can re-sort cheaply.

create or replace function public.trending_players(p_window_hours int)
returns table (player_id text, adds bigint, drops bigint)
language sql security definer set search_path = public as $$
    select
        pid                     as player_id,
        sum(case when added   then 1 else 0 end) as adds,
        sum(case when dropped then 1 else 0 end) as drops
    from (
        select add_player_id  as pid, true  as added, false as dropped
          from public.transactions
         where status = 'completed'
           and add_player_id is not null
           and created_at > now() - (p_window_hours || ' hours')::interval
        union all
        select drop_player_id as pid, false as added, true  as dropped
          from public.transactions
         where status = 'completed'
           and drop_player_id is not null
           and created_at > now() - (p_window_hours || ' hours')::interval
    ) t
    group by pid
    order by (sum(case when added then 1 else 0 end)
            + sum(case when dropped then 1 else 0 end)) desc
    limit 100;
$$;
