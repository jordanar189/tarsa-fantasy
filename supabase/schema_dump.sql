


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";





SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."friendships" (
    "user_a" "uuid" NOT NULL,
    "user_b" "uuid" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "accepted_at" timestamp with time zone,
    CONSTRAINT "friendships_check" CHECK (("user_a" < "user_b")),
    CONSTRAINT "friendships_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text"])))
);


ALTER TABLE "public"."friendships" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_friend_request"("p_other_user" "uuid") RETURNS "public"."friendships"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
declare
    me uuid := auth.uid();
    ua uuid;
    ub uuid;
    row public.friendships;
begin
    if me is null then raise exception 'unauthenticated'; end if;
    if me < p_other_user then
        ua := me; ub := p_other_user;
    else
        ua := p_other_user; ub := me;
    end if;

    update public.friendships
       set status = 'accepted', accepted_at = now()
     where user_a = ua and user_b = ub
       and status = 'pending'
       and requested_by <> me
    returning * into row;

    if row.user_a is null then raise exception 'no pending request to accept'; end if;
    return row;
end$$;


ALTER FUNCTION "public"."accept_friend_request"("p_other_user" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trades" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "proposer_team_id" "uuid" NOT NULL,
    "recipient_team_id" "uuid" NOT NULL,
    "proposer_player_ids" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "recipient_player_ids" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "note" "text",
    "parent_trade_id" "uuid",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "voting_ends_at" timestamp with time zone,
    "accepted_at" timestamp with time zone,
    "executed_at" timestamp with time zone,
    "resolved_at" timestamp with time zone,
    "failure_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "simulated_week" integer
);


ALTER TABLE "public"."trades" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_trade"("p_trade_id" "uuid") RETURNS "public"."trades"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    t  public.trades;
    lg public.leagues;
    recipient_team public.teams;
    next_status text;
    voting_ends timestamptz;
begin
    select * into t  from public.trades where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending' then raise exception 'trade is no longer pending'; end if;
    select * into lg from public.leagues where id = t.league_id;
    select * into recipient_team from public.teams where id = t.recipient_team_id;
    if recipient_team.owner_id <> auth.uid() then
        raise exception 'only the recipient owner can accept this trade';
    end if;

    case lg.trade_approval
    when 'none'         then next_status := 'pending_execution';
    when 'commissioner' then next_status := 'pending_approval';
    when 'league_vote'  then
        next_status := 'voting';
        voting_ends := now() + (lg.trade_vote_hours || ' hours')::interval;
    else                     next_status := 'pending_execution';
    end case;

    update public.trades
       set status = next_status,
           accepted_at = now(),
           voting_ends_at = voting_ends
     where id = p_trade_id
     returning * into t;

    -- If approvals are all bypassed, attempt to execute immediately. This is
    -- best-effort — if players are locked, status stays pending_execution
    -- and the cron picks it up later.
    if next_status = 'pending_execution' then
        perform public.attempt_execute_trade(p_trade_id);
        select * into t from public.trades where id = p_trade_id;
    end if;
    return t;
end$$;


ALTER FUNCTION "public"."accept_trade"("p_trade_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."append_poll_option"("p_message_id" "uuid", "p_option" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    v_league  uuid;
    v_type    text;
    v_payload jsonb;
    v_clean   text;
    v_count   int;
begin
    select league_id, message_type, payload
      into v_league, v_type, v_payload
      from public.league_messages
     where id = p_message_id;

    if v_league is null then
        raise exception 'message not found';
    end if;
    if not public.is_league_member(v_league) then
        raise exception 'not a league member';
    end if;
    if v_type <> 'poll' then
        raise exception 'message is not a poll';
    end if;
    if coalesce((v_payload->>'allowAddOptions')::boolean, false) is not true then
        raise exception 'this poll does not allow added options';
    end if;

    v_clean := btrim(coalesce(p_option, ''));
    if char_length(v_clean) = 0 or char_length(v_clean) > 80 then
        raise exception 'invalid option';
    end if;

    -- Drop silently on case-insensitive duplicates so a double-tap is a no-op.
    if exists (
        select 1
          from jsonb_array_elements_text(coalesce(v_payload->'options', '[]'::jsonb)) o
         where lower(o) = lower(v_clean)
    ) then
        return;
    end if;

    select jsonb_array_length(coalesce(v_payload->'options', '[]'::jsonb)) into v_count;
    if v_count >= 12 then
        raise exception 'poll already has the maximum number of options';
    end if;

    update public.league_messages
       set payload = jsonb_set(
               coalesce(payload, '{}'::jsonb),
               '{options}',
               coalesce(payload->'options', '[]'::jsonb) || to_jsonb(v_clean)
           )
     where id = p_message_id;
end;
$$;


ALTER FUNCTION "public"."append_poll_option"("p_message_id" "uuid", "p_option" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."attempt_execute_trade"("p_trade_id" "uuid") RETURNS "public"."trades"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    t public.trades;
    lg public.leagues;
    proposer public.teams;
    recipient public.teams;
    current_week int;
    locked_count int;
    new_proposer_roster text[];
    new_recipient_roster text[];
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found then return null; end if;
    if t.status <> 'pending_execution' then return t; end if;

    select * into lg        from public.leagues where id = t.league_id;
    select * into proposer  from public.teams   where id = t.proposer_team_id;
    select * into recipient from public.teams   where id = t.recipient_team_id;

    -- "Current week" = max week with any stats for this season. Players
    -- listed in the trade with a stat row for that week are considered
    -- locked (game in progress / final).
    select coalesce(max(week), 0) into current_week
        from public.player_games where season = lg.season;

    select count(*) into locked_count
        from public.player_games
       where season = lg.season and week = current_week
         and player_id = any (t.proposer_player_ids || t.recipient_player_ids);

    if locked_count > 0 then
        -- Stay in pending_execution; cron will retry after next week's data
        -- arrives and locked players become "past" rather than "current".
        return t;
    end if;

    -- Build the swapped rosters.
    new_proposer_roster := (
        select array_agg(p) from (
            select unnest(proposer.roster) as p
            except select unnest(t.proposer_player_ids)
        ) s
    );
    new_proposer_roster := coalesce(new_proposer_roster, '{}'::text[]) || t.recipient_player_ids;

    new_recipient_roster := (
        select array_agg(p) from (
            select unnest(recipient.roster) as p
            except select unnest(t.recipient_player_ids)
        ) s
    );
    new_recipient_roster := coalesce(new_recipient_roster, '{}'::text[]) || t.proposer_player_ids;

    update public.teams set roster = new_proposer_roster  where id = proposer.id;
    update public.teams set roster = new_recipient_roster where id = recipient.id;

    update public.trades
       set status = 'executed', executed_at = now(),
           resolved_at = coalesce(resolved_at, now())
     where id = p_trade_id
     returning * into t;

    -- Log a transaction row per side so the Activity feed reflects both
    -- ends of the swap with the player IDs that moved.
    insert into public.transactions (league_id, team_id, kind, add_player_id, drop_player_id, status, note)
        select t.league_id, proposer.id, 'trade', null, unnest(t.proposer_player_ids), 'completed', null
        from (select 1) x;
    insert into public.transactions (league_id, team_id, kind, add_player_id, drop_player_id, status, note)
        select t.league_id, proposer.id, 'trade', unnest(t.recipient_player_ids), null, 'completed', null
        from (select 1) x;
    insert into public.transactions (league_id, team_id, kind, add_player_id, drop_player_id, status, note)
        select t.league_id, recipient.id, 'trade', null, unnest(t.recipient_player_ids), 'completed', null
        from (select 1) x;
    insert into public.transactions (league_id, team_id, kind, add_player_id, drop_player_id, status, note)
        select t.league_id, recipient.id, 'trade', unnest(t.proposer_player_ids), null, 'completed', null
        from (select 1) x;

    return t;
end$$;


ALTER FUNCTION "public"."attempt_execute_trade"("p_trade_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_dm_thread_last_message"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
    update public.dm_threads
       set last_message_at = new.created_at
     where id = new.thread_id;
    return new;
end$$;


ALTER FUNCTION "public"."bump_dm_thread_last_message"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_access_feedback"("p_feedback_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
    select exists (
        select 1 from public.feedback f
         where f.id = p_feedback_id
           and (f.user_id = auth.uid() or public.is_app_admin())
    );
$$;


ALTER FUNCTION "public"."can_access_feedback"("p_feedback_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_trade"("p_trade_id" "uuid") RETURNS "public"."trades"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    t public.trades;
    proposer_team public.teams;
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending' then raise exception 'trade can only be cancelled while pending'; end if;
    select * into proposer_team from public.teams where id = t.proposer_team_id;
    if proposer_team.owner_id <> auth.uid() then
        raise exception 'only the proposer can cancel this trade';
    end if;
    update public.trades set status = 'cancelled', resolved_at = now()
     where id = p_trade_id returning * into t;
    return t;
end$$;


ALTER FUNCTION "public"."cancel_trade"("p_trade_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."push_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_by" "uuid",
    "title" "text" NOT NULL,
    "body" "text" DEFAULT ''::"text" NOT NULL,
    "image_url" "text",
    "deep_link" "text",
    "target" "text" DEFAULT 'all'::"text" NOT NULL,
    "target_user_ids" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "scheduled_at" timestamp with time zone,
    "status" "text" DEFAULT 'scheduled'::"text" NOT NULL,
    "sending_at" timestamp with time zone,
    "sent_at" timestamp with time zone,
    "sent_count" integer DEFAULT 0 NOT NULL,
    "fail_count" integer DEFAULT 0 NOT NULL,
    "error" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "push_notifications_status_check" CHECK (("status" = ANY (ARRAY['scheduled'::"text", 'sending'::"text", 'sent'::"text", 'failed'::"text", 'canceled'::"text"]))),
    CONSTRAINT "push_notifications_target_check" CHECK (("target" = ANY (ARRAY['all'::"text", 'users'::"text"])))
);


ALTER TABLE "public"."push_notifications" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_push_notifications"("p_id" "uuid" DEFAULT NULL::"uuid", "p_limit" integer DEFAULT 50, "p_lease_seconds" integer DEFAULT 300) RETURNS SETOF "public"."push_notifications"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
    update public.push_notifications n
       set status = 'sending', sending_at = now()
     where n.id in (
         select c.id from public.push_notifications c
          where case
                  when p_id is not null then c.id = p_id and c.status = 'scheduled'
                  else (c.status = 'scheduled' and (c.scheduled_at is null or c.scheduled_at <= now()))
                    or (c.status = 'sending'   and c.sending_at < now() - make_interval(secs => p_lease_seconds))
                end
          order by c.created_at
          limit p_limit
          for update skip locked
       )
    returning n.*;
$$;


ALTER FUNCTION "public"."claim_push_notifications"("p_id" "uuid", "p_limit" integer, "p_lease_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_dropped_nicknames"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
    if NEW.roster is distinct from OLD.roster then
        update public.player_nicknames
           set cleared_at = now()
         where team_id = NEW.id
           and cleared_at is null
           and not (player_id = any(NEW.roster));
    end if;
    return NEW;
end;
$$;


ALTER FUNCTION "public"."clear_dropped_nicknames"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_dropped_values"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
    if NEW.roster is distinct from OLD.roster then
        delete from public.player_values
         where team_id = NEW.id
           and not (player_id = any(NEW.roster));
    end if;
    return NEW;
end;
$$;


ALTER FUNCTION "public"."clear_dropped_values"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."commish_resolve_trade"("p_trade_id" "uuid", "p_approve" boolean, "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."trades"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    t  public.trades;
    lg public.leagues;
begin
    select * into t  from public.trades  where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending_approval' then
        raise exception 'trade is not awaiting commissioner approval';
    end if;
    select * into lg from public.leagues where id = t.league_id;
    if lg.creator_id <> auth.uid() then
        raise exception 'only the commissioner can resolve this trade';
    end if;
    if p_approve then
        update public.trades set status = 'pending_execution', resolved_at = now()
         where id = p_trade_id returning * into t;
        perform public.attempt_execute_trade(p_trade_id);
        select * into t from public.trades where id = p_trade_id;
    else
        update public.trades set status = 'vetoed', resolved_at = now(),
            failure_reason = coalesce(p_note, 'Rejected by commissioner.')
         where id = p_trade_id returning * into t;
    end if;
    return t;
end$$;


ALTER FUNCTION "public"."commish_resolve_trade"("p_trade_id" "uuid", "p_approve" boolean, "p_note" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."leagues" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "season" integer NOT NULL,
    "scoring" "text" NOT NULL,
    "roster_config" "jsonb" NOT NULL,
    "schedule" "jsonb" NOT NULL,
    "join_code" "text" NOT NULL,
    "creator_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "waiver_process_day" smallint DEFAULT 3 NOT NULL,
    "waiver_process_hour" smallint DEFAULT 8 NOT NULL,
    "waiver_period_hours" smallint DEFAULT 24 NOT NULL,
    "commissioner_approval" boolean DEFAULT false NOT NULL,
    "waiver_priority" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "last_waivers_run_at" timestamp with time zone,
    "trade_approval" "text" DEFAULT 'none'::"text" NOT NULL,
    "trade_deadline" timestamp with time zone,
    "trade_vote_hours" integer DEFAULT 24 NOT NULL,
    "is_test" boolean DEFAULT false NOT NULL,
    "simulated_week" integer,
    "parent_league_id" "uuid",
    "season_completed" boolean DEFAULT false NOT NULL,
    "season_completed_at" timestamp with time zone,
    "regular_season_weeks" integer,
    "playoff_teams" integer DEFAULT 6 NOT NULL,
    "playoff_reseed" boolean DEFAULT true NOT NULL,
    "scoring_settings" "jsonb",
    "division_names" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "champion_team_id" "uuid",
    "champion_team_name" "text",
    "is_dynasty" boolean DEFAULT false NOT NULL,
    "weeks_per_round" integer DEFAULT 1 NOT NULL
);


ALTER TABLE "public"."leagues" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_league_season"("p_league_id" "uuid", "p_champion_team_id" "uuid" DEFAULT NULL::"uuid", "p_champion_team_name" "text" DEFAULT NULL::"text") RETURNS "public"."leagues"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    lg          public.leagues;
    is_commish  boolean;
begin
    select * into lg from public.leagues where id = p_league_id for update;
    if not found then raise exception 'league not found'; end if;
    select (lg.creator_id = auth.uid()) into is_commish;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can complete the season';
    end if;

    update public.leagues
       set season_completed = true,
           season_completed_at = now(),
           champion_team_id = p_champion_team_id,
           champion_team_name = p_champion_team_name
     where id = p_league_id
     returning * into lg;
    return lg;
end$$;


ALTER FUNCTION "public"."complete_league_season"("p_league_id" "uuid", "p_champion_team_id" "uuid", "p_champion_team_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dvp_ranks"("p_season" integer, "p_position" "text", "p_scoring" "text" DEFAULT 'ppr'::"text", "p_up_to_week" integer DEFAULT NULL::integer) RETURNS TABLE("team" "text", "points_allowed" numeric, "rank" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    with totals as (
        select
            team,
            case p_scoring
                when 'ppr'  then sum(ppr_allowed)
                when 'half' then sum(half_allowed)
                else             sum(std_allowed)
            end as points_allowed
        from public.dvp_weekly
        where season = p_season
          and upper(position) = upper(p_position)
          and (p_up_to_week is null or week <= p_up_to_week)
        group by team
    )
    select
        team,
        round(points_allowed::numeric, 2) as points_allowed,
        (rank() over (order by points_allowed desc))::int as rank
    from totals
    order by rank;
$$;


ALTER FUNCTION "public"."dvp_ranks"("p_season" integer, "p_position" "text", "p_scoring" "text", "p_up_to_week" integer) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dm_threads" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_a" "uuid" NOT NULL,
    "user_b" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_message_at" timestamp with time zone,
    CONSTRAINT "dm_threads_check" CHECK (("user_a" < "user_b"))
);


ALTER TABLE "public"."dm_threads" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_or_create_dm_thread"("p_other_user" "uuid") RETURNS "public"."dm_threads"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
declare
    me uuid := auth.uid();
    ua uuid;
    ub uuid;
    row public.dm_threads;
begin
    if me is null then raise exception 'unauthenticated'; end if;
    if me = p_other_user then raise exception 'cannot DM self'; end if;

    if me < p_other_user then ua := me; ub := p_other_user;
    else                       ua := p_other_user; ub := me;
    end if;

    insert into public.dm_threads (user_a, user_b)
        values (ua, ub)
        on conflict (user_a, user_b) do nothing
        returning * into row;

    if row.id is null then
        select * into row from public.dm_threads where user_a = ua and user_b = ub;
    end if;
    return row;
end$$;


ALTER FUNCTION "public"."get_or_create_dm_thread"("p_other_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
    insert into public.profiles (id, username)
    values (new.id, coalesce(new.raw_user_meta_data->>'username', new.email));
    return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invoke_edge_function"("fn" "text", "body" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
    base text;
    key  text;
begin
    select decrypted_secret into base from vault.decrypted_secrets where name = 'project_url';
    select decrypted_secret into key  from vault.decrypted_secrets where name = 'service_role_key';
    if base is null or key is null then
        raise warning 'invoke_edge_function(%): project_url or service_role_key vault secret missing', fn;
        return;
    end if;
    perform net.http_post(
        url     := base || '/functions/v1/' || fn,
        headers := jsonb_build_object(
            'Content-Type',  'application/json',
            'Authorization', 'Bearer ' || key
        ),
        body    := body
    );
end$$;


ALTER FUNCTION "public"."invoke_edge_function"("fn" "text", "body" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_app_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
    select exists (
        select 1 from public.profiles p
         where p.id = auth.uid() and p.is_admin = true
    );
$$;


ALTER FUNCTION "public"."is_app_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_dm_participant"("p_thread_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
    select exists (
        select 1 from public.dm_threads t
         where t.id = p_thread_id
           and auth.uid() in (t.user_a, t.user_b)
    );
$$;


ALTER FUNCTION "public"."is_dm_participant"("p_thread_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_league_member"("p_league_id" "uuid") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
    select exists (
        select 1 from public.teams t
         where t.league_id = p_league_id and t.owner_id = auth.uid()
    ) or exists (
        select 1 from public.leagues l
         where l.id = p_league_id and l.creator_id = auth.uid()
    );
$$;


ALTER FUNCTION "public"."is_league_member"("p_league_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."drafts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "format" "text" DEFAULT 'snake'::"text" NOT NULL,
    "status" "text" DEFAULT 'scheduled'::"text" NOT NULL,
    "pick_seconds" integer DEFAULT 60 NOT NULL,
    "starts_at" timestamp with time zone NOT NULL,
    "started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "current_pick" integer DEFAULT 0 NOT NULL,
    "total_picks" integer DEFAULT 0 NOT NULL,
    "pick_deadline" timestamp with time zone,
    "pick_order" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "paused_at" timestamp with time zone,
    "paused_remaining" integer,
    "auto_pick_team_ids" "text"[] DEFAULT '{}'::"text"[] NOT NULL
);


ALTER TABLE "public"."drafts" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."make_pick"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text", "p_is_auto" boolean DEFAULT false) RETURNS "public"."drafts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    d            public.drafts;
    team_on_clock uuid;
    next_pick    int;
    new_deadline timestamptz;
    is_owner     boolean;
    is_commish   boolean;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found                   then raise exception 'draft not found'; end if;
    if d.status <> 'live'          then raise exception 'draft is not live'; end if;
    if d.current_pick < 1
       or d.current_pick > d.total_picks
    then raise exception 'no pick is currently active'; end if;

    team_on_clock := public.team_on_clock(d.id, d.current_pick);
    if team_on_clock is null
       or team_on_clock <> p_team_id
    then raise exception 'team is not on the clock'; end if;

    -- Auth: owner of the team, or the league commissioner, or auto-pick.
    select (t.owner_id = auth.uid()) into is_owner
        from public.teams t where t.id = p_team_id;
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = d.league_id;
    if not p_is_auto
       and coalesce(is_owner, false) is false
       and coalesce(is_commish, false) is false
    then raise exception 'not authorized to pick for this team'; end if;

    insert into public.draft_picks (draft_id, pick_number, team_id, player_id, auto_pick)
    values (p_draft_id, d.current_pick, p_team_id, p_player_id, p_is_auto);

    -- Append to the team's roster row.
    update public.teams
       set roster = array_append(roster, p_player_id)
     where id = p_team_id;

    next_pick    := d.current_pick + 1;
    new_deadline := now() + (d.pick_seconds || ' seconds')::interval;

    if next_pick > d.total_picks then
        update public.drafts
           set current_pick = next_pick,
               pick_deadline = null,
               status = 'complete',
               completed_at = now()
         where id = p_draft_id
         returning * into d;
    else
        update public.drafts
           set current_pick = next_pick,
               pick_deadline = new_deadline
         where id = p_draft_id
         returning * into d;
    end if;
    return d;
end$$;


ALTER FUNCTION "public"."make_pick"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text", "p_is_auto" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pause_draft"("p_draft_id" "uuid") RETURNS "public"."drafts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    d public.drafts;
    is_commish boolean;
    remaining int;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = d.league_id;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can pause the draft';
    end if;
    if d.status <> 'live' then return d; end if;
    remaining := greatest(0, extract(epoch from (d.pick_deadline - now()))::int);
    update public.drafts
       set status = 'paused', paused_at = now(),
           paused_remaining = remaining, pick_deadline = null
     where id = p_draft_id
     returning * into d;
    return d;
end$$;


ALTER FUNCTION "public"."pause_draft"("p_draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."player_career"("p_player_id" "text", "p_scoring" "text" DEFAULT 'ppr'::"text", "p_use_custom" boolean DEFAULT false, "p_pass_yards_per_point" numeric DEFAULT 25, "p_pass_td" numeric DEFAULT 4, "p_interception" numeric DEFAULT '-2'::integer, "p_rush_yards_per_point" numeric DEFAULT 10, "p_rush_td" numeric DEFAULT 6, "p_rec_yards_per_point" numeric DEFAULT 10, "p_rec_td" numeric DEFAULT 6, "p_reception" numeric DEFAULT 0, "p_fumble_lost" numeric DEFAULT '-2'::integer) RETURNS TABLE("season" integer, "position" "text", "teams" "text"[], "games_played" integer, "completions" numeric, "attempts" numeric, "passing_yards" numeric, "passing_tds" numeric, "passing_interceptions" numeric, "carries" numeric, "rushing_yards" numeric, "rushing_tds" numeric, "receptions" numeric, "targets" numeric, "receiving_yards" numeric, "receiving_tds" numeric, "fumbles_lost" numeric, "fantasy_points" numeric, "fantasy_points_ppr" numeric, "fantasy_points_half_ppr" numeric, "special_points" numeric, "points" numeric, "points_per_game" numeric, "rank" integer, "total_at_position" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    with target_seasons as (
        select season from public.player_season_totals where player_id = p_player_id
    ),
    -- Every player's pre-aggregated totals for the seasons the target played —
    -- the field we rank within. One row per player-season (cheap), not per game.
    scored as (
        select
            t.*,
            (
                case when p_use_custom then
                    (case when p_pass_yards_per_point > 0 then t.passing_yards / p_pass_yards_per_point else 0 end)
                    + t.passing_tds * p_pass_td
                    + t.passing_interceptions * p_interception
                    + (case when p_rush_yards_per_point > 0 then t.rushing_yards / p_rush_yards_per_point else 0 end)
                    + t.rushing_tds * p_rush_td
                    + (case when p_rec_yards_per_point > 0 then t.receiving_yards / p_rec_yards_per_point else 0 end)
                    + t.receiving_tds * p_rec_td
                    + t.receptions * p_reception
                    + t.fumbles_lost * p_fumble_lost
                else
                    case p_scoring
                        when 'ppr'  then t.fantasy_points_ppr
                        when 'half' then t.fantasy_points_half_ppr
                        else             t.fantasy_points
                    end
                end
                + t.special_points
            ) as points
        from public.player_season_totals t
        where t.season in (select season from target_seasons)
    ),
    -- Rank within (season, position). row_number() (not rank/dense_rank)
    -- mirrors the client's sorted+enumerated ranking: tied players get distinct
    -- consecutive ranks (1, 2 — not 1, 1). player_id breaks ties deterministically.
    ranked as (
        select
            s.player_id,
            s.season,
            (row_number() over (partition by s.season, s.position order by s.points desc, s.player_id))::int as rank,
            (count(*) over (partition by s.season, s.position))::int as total_at_position
        from scored s
        where coalesce(s.position, '') <> ''
    ),
    target_teams as (
        select season, array_agg(team order by first_week) as teams
        from (
            select season, team, min(week) as first_week
            from public.player_games
            where player_id = p_player_id and team <> ''
            group by season, team
        ) q
        group by season
    )
    select
        s.season,
        coalesce(s.position, '') as position,
        coalesce(tt.teams, array[]::text[]) as teams,
        s.games_played,
        s.completions, s.attempts,
        s.passing_yards, s.passing_tds, s.passing_interceptions,
        s.carries, s.rushing_yards, s.rushing_tds,
        s.receptions, s.targets, s.receiving_yards, s.receiving_tds,
        s.fumbles_lost,
        s.fantasy_points, s.fantasy_points_ppr, s.fantasy_points_half_ppr,
        s.special_points,
        round(s.points::numeric, 2) as points,
        round((s.points / greatest(s.games_played, 1))::numeric, 2) as points_per_game,
        r.rank,
        r.total_at_position
    from scored s
    left join ranked r on r.player_id = s.player_id and r.season = s.season
    left join target_teams tt on tt.season = s.season
    where s.player_id = p_player_id
    order by s.season desc;
$$;


ALTER FUNCTION "public"."player_career"("p_player_id" "text", "p_scoring" "text", "p_use_custom" boolean, "p_pass_yards_per_point" numeric, "p_pass_td" numeric, "p_interception" numeric, "p_rush_yards_per_point" numeric, "p_rush_td" numeric, "p_rec_yards_per_point" numeric, "p_rec_td" numeric, "p_reception" numeric, "p_fumble_lost" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."player_nickname_history"("p_player_id" "text") RETURNS TABLE("nickname" "text", "team_name" "text", "league_name" "text", "created_at" timestamp with time zone, "cleared_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    select pn.nickname, t.name, l.name, pn.created_at, pn.cleared_at
      from public.player_nicknames pn
      join public.teams   t on t.id = pn.team_id
      join public.leagues l on l.id = pn.league_id
     where pn.player_id = p_player_id
       -- Scope to the caller's leagues so cross-league nickname/team/league
       -- text isn't exposed outside league membership.
       and public.is_league_member(pn.league_id)
     order by pn.created_at desc;
$$;


ALTER FUNCTION "public"."player_nickname_history"("p_player_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."propose_trade"("p_league_id" "uuid", "p_proposer_team_id" "uuid", "p_recipient_team_id" "uuid", "p_proposer_player_ids" "text"[], "p_recipient_player_ids" "text"[], "p_note" "text" DEFAULT NULL::"text", "p_parent_trade_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."trades"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    lg            public.leagues;
    proposer_team public.teams;
    recipient_team public.teams;
    is_proposer_owner boolean;
    new_trade     public.trades;
begin
    select * into lg from public.leagues where id = p_league_id;
    if not found then raise exception 'league not found'; end if;
    if lg.trade_deadline is not null and lg.trade_deadline < now() then
        raise exception 'trade deadline has passed';
    end if;

    select * into proposer_team from public.teams
        where id = p_proposer_team_id and league_id = p_league_id;
    if not found then raise exception 'proposer team not in league'; end if;
    select * into recipient_team from public.teams
        where id = p_recipient_team_id and league_id = p_league_id;
    if not found then raise exception 'recipient team not in league'; end if;

    is_proposer_owner := proposer_team.owner_id = auth.uid();
    if not is_proposer_owner then
        raise exception 'you can only propose trades from your own team';
    end if;
    if recipient_team.owner_id is null then
        raise exception 'cannot trade with an unowned team';
    end if;
    if p_proposer_team_id = p_recipient_team_id then
        raise exception 'cannot trade with yourself';
    end if;
    if coalesce(array_length(p_proposer_player_ids, 1), 0) = 0
       and coalesce(array_length(p_recipient_player_ids, 1), 0) = 0 then
        raise exception 'a trade needs at least one player on one side';
    end if;
    -- Validate roster membership.
    if not (proposer_team.roster @> p_proposer_player_ids) then
        raise exception 'one or more offered players are not on your roster';
    end if;
    if not (recipient_team.roster @> p_recipient_player_ids) then
        raise exception 'one or more requested players are not on the recipient roster';
    end if;

    insert into public.trades (
        league_id, proposer_team_id, recipient_team_id,
        proposer_player_ids, recipient_player_ids, note, parent_trade_id, status
    ) values (
        p_league_id, p_proposer_team_id, p_recipient_team_id,
        p_proposer_player_ids, p_recipient_player_ids, p_note, p_parent_trade_id, 'pending'
    ) returning * into new_trade;

    -- If this proposal is a counter, mark the parent as 'countered' so it
    -- drops out of the recipient's pending queue.
    if p_parent_trade_id is not null then
        update public.trades
           set status = 'countered', resolved_at = now()
         where id = p_parent_trade_id
           and status = 'pending';
    end if;
    return new_trade;
end$$;


ALTER FUNCTION "public"."propose_trade"("p_league_id" "uuid", "p_proposer_team_id" "uuid", "p_recipient_team_id" "uuid", "p_proposer_player_ids" "text"[], "p_recipient_player_ids" "text"[], "p_note" "text", "p_parent_trade_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."push_notifications_set_creator"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
begin
    new.created_by := auth.uid();
    return new;
end$$;


ALTER FUNCTION "public"."push_notifications_set_creator"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_add"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    is_owner   boolean;
    next_pos   int;
begin
    select (t.owner_id = auth.uid()) into is_owner
        from public.teams t where t.id = p_team_id;
    if coalesce(is_owner, false) is false then
        raise exception 'not authorized to manage this team''s queue';
    end if;

    if exists (
        select 1 from public.draft_queues
         where draft_id = p_draft_id and team_id = p_team_id
           and player_id = p_player_id
    ) then
        return null;
    end if;

    select coalesce(max(position), 0) + 1 into next_pos
      from public.draft_queues
     where draft_id = p_draft_id and team_id = p_team_id;

    insert into public.draft_queues (draft_id, team_id, position, player_id)
    values (p_draft_id, p_team_id, next_pos, p_player_id);
    return next_pos;
end$$;


ALTER FUNCTION "public"."queue_add"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_remove"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    is_owner boolean;
    removed_pos int;
begin
    select (t.owner_id = auth.uid()) into is_owner
        from public.teams t where t.id = p_team_id;
    if coalesce(is_owner, false) is false then
        raise exception 'not authorized to manage this team''s queue';
    end if;

    delete from public.draft_queues
     where draft_id = p_draft_id and team_id = p_team_id
       and player_id = p_player_id
     returning position into removed_pos;

    if removed_pos is not null then
        update public.draft_queues
           set position = position - 1
         where draft_id = p_draft_id and team_id = p_team_id
           and position > removed_pos;
    end if;
end$$;


ALTER FUNCTION "public"."queue_remove"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_reorder"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_ids" "text"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    is_owner boolean;
    i        int;
begin
    select (t.owner_id = auth.uid()) into is_owner
        from public.teams t where t.id = p_team_id;
    if coalesce(is_owner, false) is false then
        raise exception 'not authorized to manage this team''s queue';
    end if;

    delete from public.draft_queues
     where draft_id = p_draft_id and team_id = p_team_id;

    if p_player_ids is null or array_length(p_player_ids, 1) is null then
        return;
    end if;
    for i in 1 .. array_length(p_player_ids, 1) loop
        insert into public.draft_queues (draft_id, team_id, position, player_id)
        values (p_draft_id, p_team_id, i, p_player_ids[i]);
    end loop;
end$$;


ALTER FUNCTION "public"."queue_reorder"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_ids" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_device_token"("p_token" "text", "p_environment" "text" DEFAULT 'production'::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
begin
    if auth.uid() is null then raise exception 'unauthenticated'; end if;
    insert into public.device_tokens (user_id, token, platform, environment, updated_at)
    values (
        auth.uid(), p_token, 'ios',
        case when p_environment in ('sandbox', 'production') then p_environment else 'production' end,
        now()
    )
    on conflict (token) do update
        set user_id     = excluded.user_id,
            environment = excluded.environment,
            updated_at  = now();
end$$;


ALTER FUNCTION "public"."register_device_token"("p_token" "text", "p_environment" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_trade"("p_trade_id" "uuid") RETURNS "public"."trades"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    t public.trades;
    recipient_team public.teams;
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'pending' then raise exception 'trade is no longer pending'; end if;
    select * into recipient_team from public.teams where id = t.recipient_team_id;
    if recipient_team.owner_id <> auth.uid() then
        raise exception 'only the recipient owner can reject this trade';
    end if;
    update public.trades set status = 'rejected', resolved_at = now()
     where id = p_trade_id returning * into t;
    return t;
end$$;


ALTER FUNCTION "public"."reject_trade"("p_trade_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_all"("p_league_id" "uuid") RETURNS "public"."leagues"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    lg public.leagues;
begin
    select * into lg from public.leagues where id = p_league_id for update;
    if not found or not coalesce(lg.is_test, false) then
        raise exception 'not a test league';
    end if;
    if lg.creator_id <> auth.uid() then
        raise exception 'only the league creator can reset';
    end if;

    delete from public.transactions    where league_id = p_league_id;
    delete from public.trades          where league_id = p_league_id;
    delete from public.waiver_claims   where league_id = p_league_id;
    delete from public.dropped_players where league_id = p_league_id;

    update public.teams t
       set roster = s.roster, starters = s.starters
      from public.team_snapshots s
     where s.team_id = t.id
       and s.simulated_week = 0
       and t.league_id = p_league_id;

    delete from public.team_snapshots
     where league_id = p_league_id and simulated_week > 0;

    update public.leagues set simulated_week = 0 where id = p_league_id;

    perform public.reset_draft(p_league_id);

    select * into lg from public.leagues where id = p_league_id;
    return lg;
end$$;


ALTER FUNCTION "public"."reset_all"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_draft"("p_league_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    d public.drafts;
begin
    select * into d from public.drafts where league_id = p_league_id;
    if not found then return; end if;

    delete from public.draft_picks where draft_id = d.id;

    update public.drafts
       set status           = 'scheduled',
           current_pick     = 0,
           started_at       = null,
           completed_at     = null,
           pick_deadline    = null,
           paused_at        = null,
           paused_remaining = null,
           starts_at        = now() + interval '5 seconds'
     where id = d.id;
end$$;


ALTER FUNCTION "public"."reset_draft"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reset_period"("p_league_id" "uuid") RETURNS "public"."leagues"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    lg public.leagues;
    current_week int;
begin
    select * into lg from public.leagues where id = p_league_id for update;
    if not found or not coalesce(lg.is_test, false) then
        raise exception 'not a test league';
    end if;
    if lg.creator_id <> auth.uid() then
        raise exception 'only the league creator can reset';
    end if;
    current_week := coalesce(lg.simulated_week, 0);

    delete from public.transactions    where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;
    delete from public.trades          where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;
    delete from public.waiver_claims   where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;
    delete from public.dropped_players where league_id = p_league_id and coalesce(simulated_week, 0) >= current_week;

    update public.teams t
       set roster = s.roster, starters = s.starters
      from public.team_snapshots s
     where s.team_id = t.id
       and s.simulated_week = current_week
       and t.league_id = p_league_id;

    delete from public.team_snapshots
     where league_id = p_league_id and simulated_week > current_week;

    -- Preseason owns the draft — only reset it there.
    if current_week = 0 then
        perform public.reset_draft(p_league_id);
    end if;

    return lg;
end$$;


ALTER FUNCTION "public"."reset_period"("p_league_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resume_draft"("p_draft_id" "uuid") RETURNS "public"."drafts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    d public.drafts;
    is_commish boolean;
    seconds int;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = d.league_id;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can resume the draft';
    end if;
    if d.status <> 'paused' then return d; end if;
    seconds := coalesce(d.paused_remaining, d.pick_seconds);
    update public.drafts
       set status = 'live', pick_deadline = now() + (seconds || ' seconds')::interval,
           paused_at = null, paused_remaining = null
     where id = p_draft_id
     returning * into d;
    return d;
end$$;


ALTER FUNCTION "public"."resume_draft"("p_draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rollover_league"("p_parent_id" "uuid", "p_new_season" integer, "p_new_name" "text", "p_schedule" "jsonb" DEFAULT '[]'::"jsonb", "p_waiver_priority" "text"[] DEFAULT '{}'::"text"[], "p_teams" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "public"."leagues"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    parent     public.leagues;
    is_commish boolean;
    child      public.leagues;
    new_code   text;
begin
    select * into parent from public.leagues where id = p_parent_id;
    if not found then raise exception 'parent league not found'; end if;
    select (parent.creator_id = auth.uid()) into is_commish;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can roll over the league';
    end if;

    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));

    insert into public.leagues (
        name, season, scoring, creator_id, roster_config, schedule, join_code,
        waiver_process_day, waiver_process_hour, waiver_period_hours,
        commissioner_approval, waiver_priority,
        trade_approval, trade_deadline, trade_vote_hours,
        parent_league_id,
        regular_season_weeks, playoff_teams, playoff_reseed, weeks_per_round,
        scoring_settings, division_names, is_dynasty
    ) values (
        coalesce(nullif(p_new_name, ''), parent.name),
        p_new_season,
        parent.scoring,
        parent.creator_id,
        parent.roster_config,
        coalesce(p_schedule, '[]'::jsonb),
        new_code,
        parent.waiver_process_day,
        parent.waiver_process_hour,
        parent.waiver_period_hours,
        parent.commissioner_approval,
        coalesce(p_waiver_priority, '{}'::text[]),
        parent.trade_approval,
        null,
        parent.trade_vote_hours,
        parent.id,
        parent.regular_season_weeks,
        parent.playoff_teams,
        parent.playoff_reseed,
        parent.weeks_per_round,
        parent.scoring_settings,
        parent.division_names,
        parent.is_dynasty
    )
    returning * into child;

    if jsonb_typeof(p_teams) = 'array' and jsonb_array_length(p_teams) > 0 then
        insert into public.teams (
            id, league_id, name, owner_id, sort_index, division,
            roster, starters, ir, taxi, logo_url, color_hex, abbreviation
        )
        select
            x.id, child.id, x.name, x.owner_id, x.sort_index, x.division,
            coalesce(x.roster, '{}'), coalesce(x.starters, '{}'),
            coalesce(x.ir, '{}'), coalesce(x.taxi, '{}'),
            x.logo_url, x.color_hex, x.abbreviation
        from jsonb_to_recordset(p_teams) as x(
            id uuid, name text, owner_id uuid, sort_index int, division int,
            roster text[], starters text[], ir text[], taxi text[],
            logo_url text, color_hex text, abbreviation text
        );
    end if;

    return child;
end$$;


ALTER FUNCTION "public"."rollover_league"("p_parent_id" "uuid", "p_new_season" integer, "p_new_name" "text", "p_schedule" "jsonb", "p_waiver_priority" "text"[], "p_teams" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_friend_request"("p_other_user" "uuid") RETURNS "public"."friendships"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
declare
    me uuid := auth.uid();
    ua uuid;
    ub uuid;
    row public.friendships;
begin
    if me is null then raise exception 'unauthenticated'; end if;
    if me = p_other_user then raise exception 'cannot friend self'; end if;

    if me < p_other_user then
        ua := me; ub := p_other_user;
    else
        ua := p_other_user; ub := me;
    end if;

    insert into public.friendships (user_a, user_b, requested_by, status)
        values (ua, ub, me, 'pending')
        on conflict (user_a, user_b) do nothing
        returning * into row;

    if row.user_a is null then
        select * into row from public.friendships
         where user_a = ua and user_b = ub;
    end if;
    return row;
end$$;


ALTER FUNCTION "public"."send_friend_request"("p_other_user" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "username" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_admin" boolean DEFAULT false NOT NULL,
    "theme" "text" DEFAULT 'dark'::"text" NOT NULL,
    "is_tester" boolean DEFAULT false NOT NULL,
    CONSTRAINT "profiles_theme_check" CHECK (("theme" = ANY (ARRAY['system'::"text", 'light'::"text", 'dark'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_admin_role"("p_user" "uuid", "p_is_admin" boolean) RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
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


ALTER FUNCTION "public"."set_admin_role"("p_user" "uuid", "p_is_admin" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_auto_pick"("p_draft_id" "uuid", "p_team_id" "uuid", "p_enabled" boolean) RETURNS "public"."drafts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    d public.drafts;
    team_owner uuid;
    league_creator uuid;
    new_list text[];
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;

    select t.owner_id into team_owner from public.teams t where t.id = p_team_id;
    select l.creator_id into league_creator
        from public.leagues l where l.id = d.league_id;

    -- auth.uid() IS NULL means the service role is calling (edge function).
    -- An authenticated user must be the team owner or the league commish.
    if auth.uid() is not null
       and coalesce(team_owner = auth.uid(), false) is false
       and coalesce(league_creator = auth.uid(), false) is false then
        raise exception 'not authorized to toggle auto-pick for this team';
    end if;

    if p_enabled then
        if not (d.auto_pick_team_ids @> array[p_team_id::text]) then
            new_list := d.auto_pick_team_ids || array[p_team_id::text];
        else
            new_list := d.auto_pick_team_ids;
        end if;
    else
        select array_agg(x) into new_list
          from unnest(d.auto_pick_team_ids) x
         where x <> p_team_id::text;
        new_list := coalesce(new_list, '{}'::text[]);
    end if;

    update public.drafts set auto_pick_team_ids = new_list
     where id = p_draft_id returning * into d;
    return d;
end$$;


ALTER FUNCTION "public"."set_auto_pick"("p_draft_id" "uuid", "p_team_id" "uuid", "p_enabled" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_player_nickname"("p_team_id" "uuid", "p_player_id" "text", "p_nickname" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    v_league_id uuid;
    v_owner     uuid;
    v_creator   uuid;
    v_clean     text;
    v_on_roster boolean;
begin
    select t.league_id, t.owner_id into v_league_id, v_owner
      from public.teams t where t.id = p_team_id;
    if v_league_id is null then
        raise exception 'team not found';
    end if;

    select l.creator_id into v_creator
      from public.leagues l where l.id = v_league_id;

    if auth.uid() is distinct from v_owner and auth.uid() is distinct from v_creator then
        raise exception 'not authorized to nickname players on this team';
    end if;

    select exists (
        select 1 from public.teams t
         where t.id = p_team_id and p_player_id = any(t.roster)
    ) into v_on_roster;
    if not v_on_roster then
        raise exception 'player is not on this team''s roster';
    end if;

    v_clean := nullif(btrim(coalesce(p_nickname, '')), '');

    if v_clean is null then
        update public.player_nicknames
           set cleared_at = now()
         where team_id = p_team_id and player_id = p_player_id and cleared_at is null;
    else
        update public.player_nicknames
           set nickname = v_clean
         where team_id = p_team_id and player_id = p_player_id and cleared_at is null;
        if not found then
            insert into public.player_nicknames (league_id, team_id, player_id, nickname)
            values (v_league_id, p_team_id, p_player_id, v_clean);
        end if;
    end if;
end;
$$;


ALTER FUNCTION "public"."set_player_nickname"("p_team_id" "uuid", "p_player_id" "text", "p_nickname" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_player_value"("p_team_id" "uuid", "p_player_id" "text", "p_value" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    v_league_id uuid;
    v_owner     uuid;
    v_creator   uuid;
    v_clean     text;
    v_on_roster boolean;
begin
    select t.league_id, t.owner_id into v_league_id, v_owner
      from public.teams t where t.id = p_team_id;
    if v_league_id is null then
        raise exception 'team not found';
    end if;

    select l.creator_id into v_creator
      from public.leagues l where l.id = v_league_id;

    if auth.uid() is distinct from v_owner and auth.uid() is distinct from v_creator then
        raise exception 'not authorized to set values on this team';
    end if;

    select exists (
        select 1 from public.teams t
         where t.id = p_team_id and p_player_id = any(t.roster)
    ) into v_on_roster;

    v_clean := nullif(btrim(lower(coalesce(p_value, ''))), '');

    if v_clean is null then
        -- Clears are always safe: if the row exists (e.g. the player was
        -- just dropped and the trigger already pruned it, or it never
        -- existed) the delete is a no-op. Skipping the roster check here
        -- keeps stale-roster save paths from blowing up.
        delete from public.player_values
         where team_id = p_team_id and player_id = p_player_id;
    else
        if not v_on_roster then
            raise exception 'player is not on this team''s roster';
        end if;
        if v_clean not in ('high', 'medium', 'low') then
            raise exception 'value must be one of high, medium, low';
        end if;
        insert into public.player_values (league_id, team_id, player_id, value, updated_at, updated_by)
        values (v_league_id, p_team_id, p_player_id, v_clean, now(), auth.uid())
        on conflict (team_id, player_id) do update
            set value      = excluded.value,
                updated_at = now(),
                updated_by = auth.uid();
    end if;
end;
$$;


ALTER FUNCTION "public"."set_player_value"("p_team_id" "uuid", "p_player_id" "text", "p_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_tester_role"("p_user" "uuid", "p_is_tester" boolean) RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
declare
    row public.profiles;
begin
    if auth.uid() is null then raise exception 'unauthenticated'; end if;
    if not public.is_app_admin() then raise exception 'not authorized'; end if;

    update public.profiles
       set is_tester = p_is_tester
     where id = p_user
    returning * into row;

    if row.id is null then raise exception 'no such user'; end if;
    return row;
end$$;


ALTER FUNCTION "public"."set_tester_role"("p_user" "uuid", "p_is_tester" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."snapshot_teams"("p_league_id" "uuid", "p_week" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    lg public.leagues;
begin
    select * into lg from public.leagues where id = p_league_id;
    if not found or not coalesce(lg.is_test, false) then return; end if;
    if lg.creator_id <> auth.uid() then
        raise exception 'only the league creator can snapshot';
    end if;

    insert into public.team_snapshots (league_id, team_id, simulated_week, roster, starters)
    select t.league_id, t.id, p_week, t.roster, t.starters
      from public.teams t
     where t.league_id = p_league_id
    on conflict (team_id, simulated_week) do nothing;
end$$;


ALTER FUNCTION "public"."snapshot_teams"("p_league_id" "uuid", "p_week" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."start_draft"("p_draft_id" "uuid") RETURNS "public"."drafts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    d public.drafts;
    is_commish boolean;
begin
    select * into d from public.drafts where id = p_draft_id for update;
    if not found then raise exception 'draft not found'; end if;
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = d.league_id;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can start the draft';
    end if;
    if d.status = 'live' then return d; end if;
    if d.status = 'complete' then raise exception 'draft is already complete'; end if;

    update public.drafts
       set status = 'live',
           started_at = coalesce(started_at, now()),
           current_pick = 1,
           pick_deadline = now() + (d.pick_seconds || ' seconds')::interval,
           paused_at = null,
           paused_remaining = null
     where id = p_draft_id
     returning * into d;
    return d;
end$$;


ALTER FUNCTION "public"."start_draft"("p_draft_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tag_with_simulated_week"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
    lg public.leagues;
begin
    select * into lg from public.leagues where id = NEW.league_id;
    if coalesce(lg.is_test, false) then
        NEW.simulated_week := coalesce(lg.simulated_week, 0);
    end if;
    return NEW;
end$$;


ALTER FUNCTION "public"."tag_with_simulated_week"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tally_trade_vote"("p_trade_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    t public.trades;
    other_owner_count int;
    veto_count int;
begin
    select * into t from public.trades where id = p_trade_id for update;
    if not found or t.status <> 'voting' then return; end if;

    -- "Other owners" = owned teams in the league minus proposer & recipient.
    select count(*) into other_owner_count
        from public.teams
       where league_id = t.league_id
         and owner_id is not null
         and id not in (t.proposer_team_id, t.recipient_team_id);
    select count(*) into veto_count
        from public.trade_votes
       where trade_id = p_trade_id and vote = 'veto';

    if other_owner_count > 0 and veto_count > (other_owner_count / 2) then
        update public.trades
           set status = 'vetoed',
               resolved_at = now(),
               failure_reason = 'Vetoed by league vote.'
         where id = p_trade_id;
    end if;
end$$;


ALTER FUNCTION "public"."tally_trade_vote"("p_trade_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."team_on_clock"("p_draft_id" "uuid", "p_pick" integer) RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE
    AS $$
declare
    d         public.drafts;
    team_count int;
    round_idx  int;     -- 0-indexed
    pos_in_round int;   -- 0-indexed
    team_id_text text;
begin
    select * into d from public.drafts where id = p_draft_id;
    if not found or p_pick < 1 then return null; end if;
    team_count := array_length(d.pick_order, 1);
    if team_count is null or team_count = 0 then return null; end if;

    round_idx    := (p_pick - 1) / team_count;
    pos_in_round := (p_pick - 1) % team_count;

    if d.format = 'snake' and (round_idx % 2 = 1) then
        pos_in_round := team_count - 1 - pos_in_round;
    end if;

    team_id_text := d.pick_order[pos_in_round + 1];   -- 1-indexed
    return team_id_text::uuid;
exception when others then
    return null;
end$$;


ALTER FUNCTION "public"."team_on_clock"("p_draft_id" "uuid", "p_pick" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."team_ranks_at_week"("p_season" integer, "p_up_to_week" integer) RETURNS TABLE("team" "text", "pass_offense" integer, "rush_offense" integer, "pass_defense" integer, "rush_defense" integer)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
    with off as (
        select
            pg.team,
            sum(pg.passing_yards)  as pass_yds_for,
            sum(pg.rushing_yards)  as rush_yds_for
        from public.player_games pg
        where pg.season = p_season and pg.week <= p_up_to_week
        group by pg.team
    ), def as (
        select
            pg.opponent as team,
            sum(pg.passing_yards) as pass_yds_against,
            sum(pg.rushing_yards) as rush_yds_against
        from public.player_games pg
        where pg.season = p_season and pg.week <= p_up_to_week
          and pg.opponent is not null and pg.opponent <> ''
        group by pg.opponent
    ), joined as (
        select
            coalesce(off.team, def.team) as team,
            off.pass_yds_for, off.rush_yds_for,
            def.pass_yds_against, def.rush_yds_against
        from off full outer join def on off.team = def.team
    )
    select
        team,
        (rank() over (order by pass_yds_for     desc nulls last))::int as pass_offense,
        (rank() over (order by rush_yds_for     desc nulls last))::int as rush_offense,
        (rank() over (order by pass_yds_against asc  nulls last))::int as pass_defense,
        (rank() over (order by rush_yds_against asc  nulls last))::int as rush_defense
    from joined
    where team is not null and team <> '';
$$;


ALTER FUNCTION "public"."team_ranks_at_week"("p_season" integer, "p_up_to_week" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unregister_device_token"("p_token" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
begin
    if auth.uid() is null then return; end if;
    delete from public.device_tokens
     where token = p_token and user_id = auth.uid();
end$$;


ALTER FUNCTION "public"."unregister_device_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."vote_trade"("p_trade_id" "uuid", "p_vote" "text") RETURNS "public"."trades"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    t public.trades;
    voter_team public.teams;
begin
    if p_vote not in ('approve', 'veto') then raise exception 'invalid vote'; end if;
    select * into t from public.trades where id = p_trade_id;
    if not found then raise exception 'trade not found'; end if;
    if t.status <> 'voting' then raise exception 'trade is not in the voting window'; end if;

    select * into voter_team from public.teams
        where league_id = t.league_id and owner_id = auth.uid()
        limit 1;
    if not found then raise exception 'you are not in this league'; end if;
    if voter_team.id in (t.proposer_team_id, t.recipient_team_id) then
        raise exception 'parties to the trade cannot vote';
    end if;

    insert into public.trade_votes (trade_id, team_id, vote)
        values (p_trade_id, voter_team.id, p_vote)
    on conflict (trade_id, team_id) do update
        set vote = excluded.vote, voted_at = now();

    -- Early-finalize if a veto majority is already reached.
    perform public.tally_trade_vote(p_trade_id);
    select * into t from public.trades where id = p_trade_id;
    return t;
end$$;


ALTER FUNCTION "public"."vote_trade"("p_trade_id" "uuid", "p_vote" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."write_league_matchups"("p_league_id" "uuid", "p_season" integer, "p_matchups" "jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    is_commish boolean;
    inserted   int := 0;
    m          jsonb;
begin
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = p_league_id;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can write matchup history';
    end if;

    -- Replace anything we already wrote for this league/season.
    delete from public.league_matchups
     where league_id = p_league_id and season = p_season;

    for m in select * from jsonb_array_elements(p_matchups) loop
        insert into public.league_matchups (
            league_id, season, week,
            home_team_id, away_team_id,
            home_user_id, away_user_id,
            home_points, away_points
        ) values (
            p_league_id, p_season,
            (m->>'week')::int,
            (m->>'home_team_id')::uuid,
            (m->>'away_team_id')::uuid,
            nullif(m->>'home_user_id', '')::uuid,
            nullif(m->>'away_user_id', '')::uuid,
            coalesce((m->>'home_points')::numeric, 0),
            coalesce((m->>'away_points')::numeric, 0)
        );
        inserted := inserted + 1;
    end loop;
    return inserted;
end$$;


ALTER FUNCTION "public"."write_league_matchups"("p_league_id" "uuid", "p_season" integer, "p_matchups" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."write_league_season_archive"("p_league_id" "uuid", "p_season" integer, "p_standings" "jsonb", "p_scoring_leader_team_id" "uuid", "p_scoring_leader_name" "text", "p_champion_team_id" "uuid" DEFAULT NULL::"uuid", "p_champion_team_name" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    is_commish boolean;
begin
    select (l.creator_id = auth.uid()) into is_commish
        from public.leagues l where l.id = p_league_id;
    if coalesce(is_commish, false) is false then
        raise exception 'only the commissioner can write the archive';
    end if;

    insert into public.league_seasons (
        league_id, season, standings,
        scoring_leader_team_id, scoring_leader_team_name,
        champion_team_id, champion_team_name, archived_at
    ) values (
        p_league_id, p_season, p_standings,
        p_scoring_leader_team_id, p_scoring_leader_name,
        p_champion_team_id, p_champion_team_name, now()
    )
    on conflict (league_id, season) do update
       set standings = excluded.standings,
           scoring_leader_team_id = excluded.scoring_leader_team_id,
           scoring_leader_team_name = excluded.scoring_leader_team_name,
           champion_team_id = excluded.champion_team_id,
           champion_team_name = excluded.champion_team_name,
           archived_at = excluded.archived_at;
end$$;


ALTER FUNCTION "public"."write_league_season_archive"("p_league_id" "uuid", "p_season" integer, "p_standings" "jsonb", "p_scoring_leader_team_id" "uuid", "p_scoring_leader_name" "text", "p_champion_team_id" "uuid", "p_champion_team_name" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."adp" (
    "season" integer NOT NULL,
    "scoring" "text" NOT NULL,
    "player_id" "text" NOT NULL,
    "adp" numeric NOT NULL,
    "times_drafted" integer,
    "high" integer,
    "low" integer,
    "stdev" numeric,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "snapshot_date" "date" NOT NULL
);


ALTER TABLE "public"."adp" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_settings" (
    "key" "text" NOT NULL,
    "value" "jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid"
);


ALTER TABLE "public"."app_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nfl_schedules" (
    "game_id" "text" NOT NULL,
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "home_team" "text" NOT NULL,
    "away_team" "text" NOT NULL,
    "kickoff" timestamp with time zone,
    "home_score" integer,
    "away_score" integer,
    "status" "text" DEFAULT 'scheduled'::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "home_spread" numeric,
    "total" numeric,
    "temp_f" integer,
    "wind_mph" integer,
    "precipitation" "text",
    "roof" "text",
    "surface" "text"
);


ALTER TABLE "public"."nfl_schedules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."seasons" (
    "season" integer NOT NULL,
    "games_count" integer DEFAULT 0 NOT NULL,
    "last_synced_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."seasons" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."available_seasons" WITH ("security_invoker"='on') AS
 SELECT "seasons"."season"
   FROM "public"."seasons"
UNION
 SELECT DISTINCT "nfl_schedules"."season"
   FROM "public"."nfl_schedules"
  WHERE ("nfl_schedules"."season" > ( SELECT COALESCE("max"("seasons"."season"), 0) AS "coalesce"
           FROM "public"."seasons"));


ALTER VIEW "public"."available_seasons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."depth_charts" (
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "team" "text" NOT NULL,
    "player_id" "text" NOT NULL,
    "position" "text" NOT NULL,
    "depth" integer DEFAULT 1 NOT NULL
);


ALTER TABLE "public"."depth_charts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."device_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "platform" "text" DEFAULT 'ios'::"text" NOT NULL,
    "environment" "text" DEFAULT 'production'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "device_tokens_environment_check" CHECK (("environment" = ANY (ARRAY['sandbox'::"text", 'production'::"text"])))
);


ALTER TABLE "public"."device_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dm_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "thread_id" "uuid" NOT NULL,
    "sender_id" "uuid" NOT NULL,
    "content" "text" DEFAULT ''::"text" NOT NULL,
    "image_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "dm_messages_check" CHECK ((("image_url" IS NOT NULL) OR (("char_length"("btrim"("content")) >= 1) AND ("char_length"("btrim"("content")) <= 2000))))
);


ALTER TABLE "public"."dm_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."draft_picks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "draft_id" "uuid" NOT NULL,
    "pick_number" integer NOT NULL,
    "team_id" "uuid" NOT NULL,
    "player_id" "text" NOT NULL,
    "auto_pick" boolean DEFAULT false NOT NULL,
    "picked_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."draft_picks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."draft_queues" (
    "draft_id" "uuid" NOT NULL,
    "team_id" "uuid" NOT NULL,
    "position" integer NOT NULL,
    "player_id" "text" NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."draft_queues" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dropped_players" (
    "league_id" "uuid" NOT NULL,
    "player_id" "text" NOT NULL,
    "dropped_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "waiver_until" timestamp with time zone NOT NULL,
    "simulated_week" integer
);


ALTER TABLE "public"."dropped_players" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_games" (
    "player_id" "text" NOT NULL,
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "team" "text" DEFAULT ''::"text" NOT NULL,
    "opponent" "text" DEFAULT ''::"text" NOT NULL,
    "completions" numeric DEFAULT 0 NOT NULL,
    "attempts" numeric DEFAULT 0 NOT NULL,
    "passing_yards" numeric DEFAULT 0 NOT NULL,
    "passing_tds" numeric DEFAULT 0 NOT NULL,
    "passing_interceptions" numeric DEFAULT 0 NOT NULL,
    "carries" numeric DEFAULT 0 NOT NULL,
    "rushing_yards" numeric DEFAULT 0 NOT NULL,
    "rushing_tds" numeric DEFAULT 0 NOT NULL,
    "receptions" numeric DEFAULT 0 NOT NULL,
    "targets" numeric DEFAULT 0 NOT NULL,
    "receiving_yards" numeric DEFAULT 0 NOT NULL,
    "receiving_tds" numeric DEFAULT 0 NOT NULL,
    "fumbles_lost" numeric DEFAULT 0 NOT NULL,
    "fantasy_points" numeric DEFAULT 0 NOT NULL,
    "fantasy_points_ppr" numeric DEFAULT 0 NOT NULL,
    "fantasy_points_half_ppr" numeric DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fg_made_0_19" numeric DEFAULT 0 NOT NULL,
    "fg_made_20_29" numeric DEFAULT 0 NOT NULL,
    "fg_made_30_39" numeric DEFAULT 0 NOT NULL,
    "fg_made_40_49" numeric DEFAULT 0 NOT NULL,
    "fg_made_50_59" numeric DEFAULT 0 NOT NULL,
    "fg_made_60" numeric DEFAULT 0 NOT NULL,
    "fg_missed" numeric DEFAULT 0 NOT NULL,
    "pat_made" numeric DEFAULT 0 NOT NULL,
    "pat_missed" numeric DEFAULT 0 NOT NULL,
    "def_sacks" numeric DEFAULT 0 NOT NULL,
    "def_interceptions" numeric DEFAULT 0 NOT NULL,
    "def_fumble_recoveries" numeric DEFAULT 0 NOT NULL,
    "def_tds" numeric DEFAULT 0 NOT NULL,
    "def_safeties" numeric DEFAULT 0 NOT NULL,
    "def_points_allowed" numeric
);


ALTER TABLE "public"."player_games" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."players_cache" (
    "id" "text" NOT NULL,
    "espn_id" "text",
    "name" "text" NOT NULL,
    "position" "text" DEFAULT ''::"text" NOT NULL,
    "position_group" "text" DEFAULT ''::"text" NOT NULL,
    "team" "text" DEFAULT ''::"text" NOT NULL,
    "headshot_url" "text" DEFAULT ''::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "birth_date" "date",
    "height_in" integer,
    "weight_lb" integer,
    "college" "text",
    "jersey_number" integer,
    "draft_year" integer,
    "draft_round" integer,
    "draft_pick" integer,
    "years_exp" integer,
    "status" "text",
    "bye_week" integer
);


ALTER TABLE "public"."players_cache" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."dvp_weekly" AS
 SELECT "pg"."season",
    "pg"."week",
    "pg"."opponent" AS "team",
    "pc"."position",
    "sum"("pg"."fantasy_points_ppr") AS "ppr_allowed",
    "sum"("pg"."fantasy_points") AS "std_allowed",
    "sum"("pg"."fantasy_points_half_ppr") AS "half_allowed",
    "count"(*) AS "players_faced"
   FROM ("public"."player_games" "pg"
     JOIN "public"."players_cache" "pc" ON (("pc"."id" = "pg"."player_id")))
  WHERE ((COALESCE("pc"."position", ''::"text") <> ''::"text") AND ("pg"."opponent" IS NOT NULL) AND ("pg"."opponent" <> ''::"text"))
  GROUP BY "pg"."season", "pg"."week", "pg"."opponent", "pc"."position";


ALTER VIEW "public"."dvp_weekly" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."feedback" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "content" "text" DEFAULT ''::"text" NOT NULL,
    "image_urls" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "feedback_check" CHECK ((("char_length"("btrim"("content")) > 0) OR (COALESCE("array_length"("image_urls", 1), 0) > 0))),
    CONSTRAINT "feedback_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'resolved'::"text"])))
);


ALTER TABLE "public"."feedback" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."feedback_comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "feedback_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "feedback_comments_content_check" CHECK (("char_length"("btrim"("content")) > 0))
);


ALTER TABLE "public"."feedback_comments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inactives" (
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "player_id" "text" NOT NULL,
    "status" "text" NOT NULL,
    "reason" "text"
);


ALTER TABLE "public"."inactives" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."injuries" (
    "player_id" "text" NOT NULL,
    "status" "text" NOT NULL,
    "details" "text",
    "expected_return" "date",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."injuries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."injury_history" (
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "player_id" "text" NOT NULL,
    "status" "text" NOT NULL,
    "details" "text",
    "practice_status" "text",
    "expected_return" "date"
);


ALTER TABLE "public"."injury_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_matchups" (
    "league_id" "uuid" NOT NULL,
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "home_team_id" "uuid" NOT NULL,
    "away_team_id" "uuid" NOT NULL,
    "home_user_id" "uuid",
    "away_user_id" "uuid",
    "home_points" numeric DEFAULT 0 NOT NULL,
    "away_points" numeric DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."league_matchups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_message_reactions" (
    "message_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "emoji" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "league_message_reactions_emoji_check" CHECK ((("char_length"("emoji") >= 1) AND ("char_length"("emoji") <= 16)))
);


ALTER TABLE "public"."league_message_reactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "content" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "image_url" "text",
    "message_type" "text" DEFAULT 'text'::"text" NOT NULL,
    "payload" "jsonb",
    CONSTRAINT "league_messages_content_check" CHECK ((("message_type" <> 'text'::"text") OR ("image_url" IS NOT NULL) OR (("char_length"("btrim"("content")) >= 1) AND ("char_length"("btrim"("content")) <= 2000)))),
    CONSTRAINT "league_messages_payload_check" CHECK ((("message_type" = 'text'::"text") OR ("payload" IS NOT NULL))),
    CONSTRAINT "league_messages_type_check" CHECK (("message_type" = ANY (ARRAY['text'::"text", 'poll'::"text", 'pickem'::"text", 'tradeblock'::"text"])))
);


ALTER TABLE "public"."league_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."league_seasons" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "season" integer NOT NULL,
    "standings" "jsonb" NOT NULL,
    "scoring_leader_team_id" "uuid",
    "scoring_leader_team_name" "text",
    "archived_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "champion_team_id" "uuid",
    "champion_team_name" "text"
);


ALTER TABLE "public"."league_seasons" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."live_scores" (
    "player_id" "text" NOT NULL,
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "fantasy_points" numeric DEFAULT 0 NOT NULL,
    "fantasy_points_ppr" numeric DEFAULT 0 NOT NULL,
    "fantasy_points_half_ppr" numeric DEFAULT 0 NOT NULL,
    "is_final" boolean DEFAULT false NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."live_scores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."message_responses" (
    "message_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "choice" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "slot" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."message_responses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."most_started" (
    "player_id" "text" NOT NULL,
    "started_pct" numeric NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."most_started" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."most_started_history" (
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "player_id" "text" NOT NULL,
    "started_pct" numeric DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."most_started_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nfl_team_ranks" (
    "team" "text" NOT NULL,
    "pass_offense" integer,
    "rush_offense" integer,
    "pass_defense" integer,
    "rush_defense" integer,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."nfl_team_ranks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nfl_team_ranks_history" (
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "team" "text" NOT NULL,
    "pass_offense" integer,
    "rush_offense" integer,
    "pass_defense" integer,
    "rush_defense" integer
);


ALTER TABLE "public"."nfl_team_ranks_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nfl_teams" (
    "abbr" "text" NOT NULL,
    "full_name" "text" NOT NULL,
    "conference" "text" NOT NULL,
    "division" "text" NOT NULL,
    "primary_color" "text",
    "secondary_color" "text",
    "logo_url" "text"
);


ALTER TABLE "public"."nfl_teams" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_nicknames" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "team_id" "uuid" NOT NULL,
    "player_id" "text" NOT NULL,
    "nickname" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cleared_at" timestamp with time zone,
    "created_by" "uuid" DEFAULT "auth"."uid"()
);


ALTER TABLE "public"."player_nicknames" OWNER TO "postgres";


CREATE MATERIALIZED VIEW "public"."player_season_totals" AS
 SELECT "pg"."player_id",
    "pg"."season",
    "upper"("pc"."position") AS "position",
    ("count"(*))::integer AS "games_played",
    "sum"("pg"."completions") AS "completions",
    "sum"("pg"."attempts") AS "attempts",
    "sum"("pg"."passing_yards") AS "passing_yards",
    "sum"("pg"."passing_tds") AS "passing_tds",
    "sum"("pg"."passing_interceptions") AS "passing_interceptions",
    "sum"("pg"."carries") AS "carries",
    "sum"("pg"."rushing_yards") AS "rushing_yards",
    "sum"("pg"."rushing_tds") AS "rushing_tds",
    "sum"("pg"."receptions") AS "receptions",
    "sum"("pg"."targets") AS "targets",
    "sum"("pg"."receiving_yards") AS "receiving_yards",
    "sum"("pg"."receiving_tds") AS "receiving_tds",
    "sum"("pg"."fumbles_lost") AS "fumbles_lost",
    "sum"("pg"."fantasy_points") AS "fantasy_points",
    "sum"("pg"."fantasy_points_ppr") AS "fantasy_points_ppr",
    "sum"("pg"."fantasy_points_half_ppr") AS "fantasy_points_half_ppr",
    "sum"(((((((((("pg"."fg_made_0_19" + "pg"."fg_made_20_29") + "pg"."fg_made_30_39") * (3)::numeric) + ("pg"."fg_made_40_49" * (4)::numeric)) + (("pg"."fg_made_50_59" + "pg"."fg_made_60") * (5)::numeric)) + "pg"."pat_made") - "pg"."fg_missed") - "pg"."pat_missed") +
        CASE
            WHEN ("pg"."def_points_allowed" IS NOT NULL) THEN ((((("pg"."def_sacks" + ("pg"."def_interceptions" * (2)::numeric)) + ("pg"."def_fumble_recoveries" * (2)::numeric)) + ("pg"."def_tds" * (6)::numeric)) + ("pg"."def_safeties" * (2)::numeric)) + (
            CASE
                WHEN ("pg"."def_points_allowed" < (1)::numeric) THEN 10
                WHEN ("pg"."def_points_allowed" < (7)::numeric) THEN 7
                WHEN ("pg"."def_points_allowed" < (14)::numeric) THEN 4
                WHEN ("pg"."def_points_allowed" < (21)::numeric) THEN 1
                WHEN ("pg"."def_points_allowed" < (28)::numeric) THEN 0
                WHEN ("pg"."def_points_allowed" < (35)::numeric) THEN '-1'::integer
                ELSE '-4'::integer
            END)::numeric)
            ELSE (0)::numeric
        END)) AS "special_points"
   FROM ("public"."player_games" "pg"
     JOIN "public"."players_cache" "pc" ON (("pc"."id" = "pg"."player_id")))
  GROUP BY "pg"."player_id", "pg"."season", ("upper"("pc"."position"))
  WITH NO DATA;


ALTER MATERIALIZED VIEW "public"."player_season_totals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."player_values" (
    "league_id" "uuid" NOT NULL,
    "team_id" "uuid" NOT NULL,
    "player_id" "text" NOT NULL,
    "value" "text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid" DEFAULT "auth"."uid"(),
    CONSTRAINT "player_values_value_check" CHECK (("value" = ANY (ARRAY['high'::"text", 'medium'::"text", 'low'::"text"])))
);


ALTER TABLE "public"."player_values" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plays" (
    "game_id" "text" NOT NULL,
    "play_id" integer NOT NULL,
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "posteam" "text",
    "defteam" "text",
    "play_type" "text",
    "description" "text",
    "passer_player_id" "text",
    "receiver_player_id" "text",
    "rusher_player_id" "text",
    "td_player_id" "text",
    "yards_gained" numeric,
    "touchdown" boolean,
    "epa" numeric,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "qtr" integer,
    "down" integer,
    "ydstogo" integer,
    "yardline_100" integer,
    "posteam_score" integer,
    "defteam_score" integer,
    "game_seconds_remaining" integer,
    "drive" integer,
    "complete_pass" boolean,
    "pass_attempt" boolean,
    "rush_attempt" boolean,
    "field_goal_attempt" boolean,
    "field_goal_result" "text",
    "extra_point_attempt" boolean,
    "extra_point_result" "text",
    "two_point_attempt" boolean,
    "interception" boolean,
    "fumble" boolean,
    "fumble_lost" boolean,
    "first_down" boolean,
    "sack" boolean,
    "penalty" boolean,
    "penalty_yards" integer,
    "air_yards" numeric,
    "yards_after_catch" numeric,
    "pass_location" "text",
    "run_location" "text",
    "run_gap" "text"
);


ALTER TABLE "public"."plays" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."snap_counts" (
    "player_id" "text" NOT NULL,
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "offense_snaps" integer DEFAULT 0 NOT NULL,
    "offense_pct" numeric(5,2) DEFAULT 0 NOT NULL,
    "team" "text"
);


ALTER TABLE "public"."snap_counts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."team_snapshots" (
    "league_id" "uuid" NOT NULL,
    "team_id" "uuid" NOT NULL,
    "simulated_week" integer NOT NULL,
    "roster" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "starters" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "captured_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."team_snapshots" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."teams" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "owner_id" "uuid",
    "roster" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "starters" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "sort_index" integer NOT NULL,
    "ir" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "weekly_lineups" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "division" integer,
    "logo_url" "text",
    "color_hex" "text",
    "abbreviation" "text",
    "taxi" "text"[] DEFAULT '{}'::"text"[] NOT NULL
);


ALTER TABLE "public"."teams" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trade_votes" (
    "trade_id" "uuid" NOT NULL,
    "team_id" "uuid" NOT NULL,
    "vote" "text" NOT NULL,
    "voted_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."trade_votes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "team_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "add_player_id" "text",
    "drop_player_id" "text",
    "status" "text" DEFAULT 'completed'::"text" NOT NULL,
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid",
    "simulated_week" integer
);


ALTER TABLE "public"."transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trending_history" (
    "season" integer NOT NULL,
    "week" integer NOT NULL,
    "player_id" "text" NOT NULL,
    "adds_pct" numeric DEFAULT 0 NOT NULL,
    "drops_pct" numeric DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."trending_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trending_players" (
    "player_id" "text" NOT NULL,
    "adds_pct" numeric DEFAULT 0 NOT NULL,
    "drops_pct" numeric DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."trending_players" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."waiver_claims" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "league_id" "uuid" NOT NULL,
    "team_id" "uuid" NOT NULL,
    "add_player_id" "text" NOT NULL,
    "drop_player_id" "text",
    "team_priority" integer DEFAULT 1 NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "failure_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "processed_at" timestamp with time zone,
    "simulated_week" integer
);


ALTER TABLE "public"."waiver_claims" OWNER TO "postgres";


ALTER TABLE ONLY "public"."adp"
    ADD CONSTRAINT "adp_pkey" PRIMARY KEY ("season", "scoring", "snapshot_date", "player_id");



ALTER TABLE ONLY "public"."app_settings"
    ADD CONSTRAINT "app_settings_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."depth_charts"
    ADD CONSTRAINT "depth_charts_pkey" PRIMARY KEY ("season", "week", "team", "position", "player_id");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."dm_messages"
    ADD CONSTRAINT "dm_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dm_threads"
    ADD CONSTRAINT "dm_threads_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dm_threads"
    ADD CONSTRAINT "dm_threads_user_a_user_b_key" UNIQUE ("user_a", "user_b");



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_draft_id_pick_number_key" UNIQUE ("draft_id", "pick_number");



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_draft_id_player_id_key" UNIQUE ("draft_id", "player_id");



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."draft_queues"
    ADD CONSTRAINT "draft_queues_draft_id_team_id_player_id_key" UNIQUE ("draft_id", "team_id", "player_id");



ALTER TABLE ONLY "public"."draft_queues"
    ADD CONSTRAINT "draft_queues_pkey" PRIMARY KEY ("draft_id", "team_id", "position");



ALTER TABLE ONLY "public"."drafts"
    ADD CONSTRAINT "drafts_league_id_key" UNIQUE ("league_id");



ALTER TABLE ONLY "public"."drafts"
    ADD CONSTRAINT "drafts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dropped_players"
    ADD CONSTRAINT "dropped_players_pkey" PRIMARY KEY ("league_id", "player_id");



ALTER TABLE ONLY "public"."feedback_comments"
    ADD CONSTRAINT "feedback_comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."friendships"
    ADD CONSTRAINT "friendships_pkey" PRIMARY KEY ("user_a", "user_b");



ALTER TABLE ONLY "public"."inactives"
    ADD CONSTRAINT "inactives_pkey" PRIMARY KEY ("season", "week", "player_id");



ALTER TABLE ONLY "public"."injuries"
    ADD CONSTRAINT "injuries_pkey" PRIMARY KEY ("player_id");



ALTER TABLE ONLY "public"."injury_history"
    ADD CONSTRAINT "injury_history_pkey" PRIMARY KEY ("season", "week", "player_id");



ALTER TABLE ONLY "public"."league_matchups"
    ADD CONSTRAINT "league_matchups_pkey" PRIMARY KEY ("league_id", "season", "week", "home_team_id");



ALTER TABLE ONLY "public"."league_message_reactions"
    ADD CONSTRAINT "league_message_reactions_pkey" PRIMARY KEY ("message_id", "user_id", "emoji");



ALTER TABLE ONLY "public"."league_messages"
    ADD CONSTRAINT "league_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."league_seasons"
    ADD CONSTRAINT "league_seasons_league_id_season_key" UNIQUE ("league_id", "season");



ALTER TABLE ONLY "public"."league_seasons"
    ADD CONSTRAINT "league_seasons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."leagues"
    ADD CONSTRAINT "leagues_join_code_key" UNIQUE ("join_code");



ALTER TABLE ONLY "public"."leagues"
    ADD CONSTRAINT "leagues_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."live_scores"
    ADD CONSTRAINT "live_scores_pkey" PRIMARY KEY ("player_id", "season", "week");



ALTER TABLE ONLY "public"."message_responses"
    ADD CONSTRAINT "message_responses_pkey" PRIMARY KEY ("message_id", "user_id", "slot");



ALTER TABLE ONLY "public"."most_started_history"
    ADD CONSTRAINT "most_started_history_pkey" PRIMARY KEY ("season", "week", "player_id");



ALTER TABLE ONLY "public"."most_started"
    ADD CONSTRAINT "most_started_pkey" PRIMARY KEY ("player_id");



ALTER TABLE ONLY "public"."nfl_schedules"
    ADD CONSTRAINT "nfl_schedules_pkey" PRIMARY KEY ("game_id");



ALTER TABLE ONLY "public"."nfl_team_ranks_history"
    ADD CONSTRAINT "nfl_team_ranks_history_pkey" PRIMARY KEY ("season", "week", "team");



ALTER TABLE ONLY "public"."nfl_team_ranks"
    ADD CONSTRAINT "nfl_team_ranks_pkey" PRIMARY KEY ("team");



ALTER TABLE ONLY "public"."nfl_teams"
    ADD CONSTRAINT "nfl_teams_pkey" PRIMARY KEY ("abbr");



ALTER TABLE ONLY "public"."player_games"
    ADD CONSTRAINT "player_games_pkey" PRIMARY KEY ("player_id", "season", "week");



ALTER TABLE ONLY "public"."player_nicknames"
    ADD CONSTRAINT "player_nicknames_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."player_values"
    ADD CONSTRAINT "player_values_pkey" PRIMARY KEY ("team_id", "player_id");



ALTER TABLE ONLY "public"."players_cache"
    ADD CONSTRAINT "players_cache_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plays"
    ADD CONSTRAINT "plays_pkey" PRIMARY KEY ("game_id", "play_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_username_key" UNIQUE ("username");



ALTER TABLE ONLY "public"."push_notifications"
    ADD CONSTRAINT "push_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."seasons"
    ADD CONSTRAINT "seasons_pkey" PRIMARY KEY ("season");



ALTER TABLE ONLY "public"."snap_counts"
    ADD CONSTRAINT "snap_counts_pkey" PRIMARY KEY ("player_id", "season", "week");



ALTER TABLE ONLY "public"."team_snapshots"
    ADD CONSTRAINT "team_snapshots_pkey" PRIMARY KEY ("team_id", "simulated_week");



ALTER TABLE ONLY "public"."teams"
    ADD CONSTRAINT "teams_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trade_votes"
    ADD CONSTRAINT "trade_votes_pkey" PRIMARY KEY ("trade_id", "team_id");



ALTER TABLE ONLY "public"."trades"
    ADD CONSTRAINT "trades_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trending_history"
    ADD CONSTRAINT "trending_history_pkey" PRIMARY KEY ("season", "week", "player_id");



ALTER TABLE ONLY "public"."trending_players"
    ADD CONSTRAINT "trending_players_pkey" PRIMARY KEY ("player_id");



ALTER TABLE ONLY "public"."waiver_claims"
    ADD CONSTRAINT "waiver_claims_pkey" PRIMARY KEY ("id");



CREATE INDEX "adp_season_scoring_date_idx" ON "public"."adp" USING "btree" ("season", "scoring", "snapshot_date" DESC);



CREATE INDEX "adp_season_scoring_idx" ON "public"."adp" USING "btree" ("season", "scoring", "adp");



CREATE INDEX "depth_charts_player_idx" ON "public"."depth_charts" USING "btree" ("player_id", "season", "week");



CREATE INDEX "depth_charts_team_idx" ON "public"."depth_charts" USING "btree" ("season", "week", "team");



CREATE INDEX "device_tokens_user_idx" ON "public"."device_tokens" USING "btree" ("user_id");



CREATE INDEX "dm_messages_thread_time_idx" ON "public"."dm_messages" USING "btree" ("thread_id", "created_at");



CREATE INDEX "dm_threads_user_a_idx" ON "public"."dm_threads" USING "btree" ("user_a");



CREATE INDEX "dm_threads_user_b_idx" ON "public"."dm_threads" USING "btree" ("user_b");



CREATE INDEX "draft_picks_draft_idx" ON "public"."draft_picks" USING "btree" ("draft_id", "pick_number");



CREATE INDEX "draft_queues_team_idx" ON "public"."draft_queues" USING "btree" ("draft_id", "team_id", "position");



CREATE INDEX "drafts_status_idx" ON "public"."drafts" USING "btree" ("status");



CREATE INDEX "dropped_players_until_idx" ON "public"."dropped_players" USING "btree" ("waiver_until");



CREATE INDEX "feedback_comments_feedback_idx" ON "public"."feedback_comments" USING "btree" ("feedback_id", "created_at");



CREATE INDEX "feedback_created_idx" ON "public"."feedback" USING "btree" ("created_at" DESC);



CREATE INDEX "feedback_user_idx" ON "public"."feedback" USING "btree" ("user_id");



CREATE INDEX "friendships_user_a_idx" ON "public"."friendships" USING "btree" ("user_a");



CREATE INDEX "friendships_user_b_idx" ON "public"."friendships" USING "btree" ("user_b");



CREATE INDEX "inactives_player_idx" ON "public"."inactives" USING "btree" ("player_id", "season");



CREATE INDEX "inactives_season_week_idx" ON "public"."inactives" USING "btree" ("season", "week");



CREATE INDEX "injuries_status_idx" ON "public"."injuries" USING "btree" ("status");



CREATE INDEX "injury_history_player_idx" ON "public"."injury_history" USING "btree" ("player_id", "season");



CREATE INDEX "injury_history_season_week_idx" ON "public"."injury_history" USING "btree" ("season", "week");



CREATE INDEX "league_matchups_league_season_idx" ON "public"."league_matchups" USING "btree" ("league_id", "season");



CREATE INDEX "league_matchups_users_idx" ON "public"."league_matchups" USING "btree" ("home_user_id", "away_user_id");



CREATE INDEX "league_message_reactions_message_idx" ON "public"."league_message_reactions" USING "btree" ("message_id");



CREATE INDEX "league_messages_league_time_idx" ON "public"."league_messages" USING "btree" ("league_id", "created_at");



CREATE INDEX "league_seasons_league_idx" ON "public"."league_seasons" USING "btree" ("league_id");



CREATE INDEX "leagues_is_test_idx" ON "public"."leagues" USING "btree" ("is_test") WHERE ("is_test" = true);



CREATE INDEX "leagues_join_code_idx" ON "public"."leagues" USING "btree" ("join_code");



CREATE INDEX "leagues_parent_idx" ON "public"."leagues" USING "btree" ("parent_league_id");



CREATE INDEX "live_scores_season_week_idx" ON "public"."live_scores" USING "btree" ("season", "week");



CREATE INDEX "message_responses_message_idx" ON "public"."message_responses" USING "btree" ("message_id");



CREATE INDEX "most_started_history_season_week_idx" ON "public"."most_started_history" USING "btree" ("season", "week");



CREATE INDEX "most_started_pct_idx" ON "public"."most_started" USING "btree" ("started_pct" DESC);



CREATE INDEX "nfl_schedules_away_idx" ON "public"."nfl_schedules" USING "btree" ("season", "away_team");



CREATE INDEX "nfl_schedules_home_idx" ON "public"."nfl_schedules" USING "btree" ("season", "home_team");



CREATE INDEX "nfl_schedules_season_week_idx" ON "public"."nfl_schedules" USING "btree" ("season", "week");



CREATE INDEX "nfl_team_ranks_history_season_week_idx" ON "public"."nfl_team_ranks_history" USING "btree" ("season", "week");



CREATE INDEX "player_games_season_idx" ON "public"."player_games" USING "btree" ("season");



CREATE INDEX "player_games_season_week_idx" ON "public"."player_games" USING "btree" ("season", "week");



CREATE UNIQUE INDEX "player_nicknames_active_uq" ON "public"."player_nicknames" USING "btree" ("team_id", "player_id") WHERE ("cleared_at" IS NULL);



CREATE INDEX "player_nicknames_league_idx" ON "public"."player_nicknames" USING "btree" ("league_id") WHERE ("cleared_at" IS NULL);



CREATE INDEX "player_nicknames_player_idx" ON "public"."player_nicknames" USING "btree" ("player_id");



CREATE UNIQUE INDEX "player_season_totals_pk" ON "public"."player_season_totals" USING "btree" ("player_id", "season");



CREATE INDEX "player_season_totals_season_pos_idx" ON "public"."player_season_totals" USING "btree" ("season", "position");



CREATE INDEX "player_values_league_idx" ON "public"."player_values" USING "btree" ("league_id");



CREATE INDEX "player_values_player_idx" ON "public"."player_values" USING "btree" ("player_id");



CREATE INDEX "players_cache_espn_idx" ON "public"."players_cache" USING "btree" ("espn_id");



CREATE INDEX "players_cache_position_idx" ON "public"."players_cache" USING "btree" ("position");



CREATE INDEX "plays_game_play_idx" ON "public"."plays" USING "btree" ("game_id", "play_id");



CREATE INDEX "plays_passer_idx" ON "public"."plays" USING "btree" ("passer_player_id") WHERE ("passer_player_id" IS NOT NULL);



CREATE INDEX "plays_play_type_idx" ON "public"."plays" USING "btree" ("season", "play_type");



CREATE INDEX "plays_receiver_idx" ON "public"."plays" USING "btree" ("receiver_player_id") WHERE ("receiver_player_id" IS NOT NULL);



CREATE INDEX "plays_rusher_idx" ON "public"."plays" USING "btree" ("rusher_player_id") WHERE ("rusher_player_id" IS NOT NULL);



CREATE INDEX "plays_season_idx" ON "public"."plays" USING "btree" ("season");



CREATE INDEX "plays_season_week_idx" ON "public"."plays" USING "btree" ("season", "week");



CREATE INDEX "plays_td_idx" ON "public"."plays" USING "btree" ("td_player_id") WHERE ("td_player_id" IS NOT NULL);



CREATE INDEX "push_notifications_due_idx" ON "public"."push_notifications" USING "btree" ("status", "scheduled_at");



CREATE INDEX "snap_counts_season_week_idx" ON "public"."snap_counts" USING "btree" ("season", "week");



CREATE INDEX "team_snapshots_league_idx" ON "public"."team_snapshots" USING "btree" ("league_id", "simulated_week");



CREATE INDEX "teams_league_id_idx" ON "public"."teams" USING "btree" ("league_id");



CREATE INDEX "teams_owner_id_idx" ON "public"."teams" USING "btree" ("owner_id");



CREATE INDEX "trade_votes_trade_idx" ON "public"."trade_votes" USING "btree" ("trade_id");



CREATE INDEX "trades_league_status_idx" ON "public"."trades" USING "btree" ("league_id", "status");



CREATE INDEX "trades_pending_exec_idx" ON "public"."trades" USING "btree" ("status") WHERE ("status" = 'pending_execution'::"text");



CREATE INDEX "trades_proposer_idx" ON "public"."trades" USING "btree" ("proposer_team_id");



CREATE INDEX "trades_recipient_idx" ON "public"."trades" USING "btree" ("recipient_team_id");



CREATE INDEX "trades_voting_ends_idx" ON "public"."trades" USING "btree" ("voting_ends_at") WHERE ("status" = 'voting'::"text");



CREATE INDEX "transactions_league_created_idx" ON "public"."transactions" USING "btree" ("league_id", "created_at" DESC);



CREATE INDEX "transactions_league_status_idx" ON "public"."transactions" USING "btree" ("league_id", "status");



CREATE INDEX "trending_adds_idx" ON "public"."trending_players" USING "btree" ("adds_pct" DESC);



CREATE INDEX "trending_drops_idx" ON "public"."trending_players" USING "btree" ("drops_pct" DESC);



CREATE INDEX "trending_history_adds_idx" ON "public"."trending_history" USING "btree" ("season", "week", "adds_pct" DESC);



CREATE INDEX "trending_history_season_week_idx" ON "public"."trending_history" USING "btree" ("season", "week");



CREATE INDEX "waiver_claims_league_status_idx" ON "public"."waiver_claims" USING "btree" ("league_id", "status");



CREATE INDEX "waiver_claims_team_idx" ON "public"."waiver_claims" USING "btree" ("team_id");



CREATE OR REPLACE TRIGGER "dm_messages_bump_thread" AFTER INSERT ON "public"."dm_messages" FOR EACH ROW EXECUTE FUNCTION "public"."bump_dm_thread_last_message"();



CREATE OR REPLACE TRIGGER "dropped_players_tag_simulated_week" BEFORE INSERT ON "public"."dropped_players" FOR EACH ROW EXECUTE FUNCTION "public"."tag_with_simulated_week"();



CREATE OR REPLACE TRIGGER "push_notifications_set_creator" BEFORE INSERT ON "public"."push_notifications" FOR EACH ROW EXECUTE FUNCTION "public"."push_notifications_set_creator"();



CREATE OR REPLACE TRIGGER "teams_clear_nicknames" AFTER UPDATE ON "public"."teams" FOR EACH ROW EXECUTE FUNCTION "public"."clear_dropped_nicknames"();



CREATE OR REPLACE TRIGGER "teams_clear_values" AFTER UPDATE ON "public"."teams" FOR EACH ROW EXECUTE FUNCTION "public"."clear_dropped_values"();



CREATE OR REPLACE TRIGGER "trades_tag_simulated_week" BEFORE INSERT ON "public"."trades" FOR EACH ROW EXECUTE FUNCTION "public"."tag_with_simulated_week"();



CREATE OR REPLACE TRIGGER "transactions_tag_simulated_week" BEFORE INSERT ON "public"."transactions" FOR EACH ROW EXECUTE FUNCTION "public"."tag_with_simulated_week"();



CREATE OR REPLACE TRIGGER "waiver_claims_tag_simulated_week" BEFORE INSERT ON "public"."waiver_claims" FOR EACH ROW EXECUTE FUNCTION "public"."tag_with_simulated_week"();



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dm_messages"
    ADD CONSTRAINT "dm_messages_sender_id_fkey" FOREIGN KEY ("sender_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dm_messages"
    ADD CONSTRAINT "dm_messages_thread_id_fkey" FOREIGN KEY ("thread_id") REFERENCES "public"."dm_threads"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dm_threads"
    ADD CONSTRAINT "dm_threads_user_a_fkey" FOREIGN KEY ("user_a") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dm_threads"
    ADD CONSTRAINT "dm_threads_user_b_fkey" FOREIGN KEY ("user_b") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_draft_id_fkey" FOREIGN KEY ("draft_id") REFERENCES "public"."drafts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."draft_picks"
    ADD CONSTRAINT "draft_picks_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id");



ALTER TABLE ONLY "public"."draft_queues"
    ADD CONSTRAINT "draft_queues_draft_id_fkey" FOREIGN KEY ("draft_id") REFERENCES "public"."drafts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."draft_queues"
    ADD CONSTRAINT "draft_queues_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."drafts"
    ADD CONSTRAINT "drafts_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dropped_players"
    ADD CONSTRAINT "dropped_players_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."feedback_comments"
    ADD CONSTRAINT "feedback_comments_feedback_id_fkey" FOREIGN KEY ("feedback_id") REFERENCES "public"."feedback"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."feedback_comments"
    ADD CONSTRAINT "feedback_comments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."friendships"
    ADD CONSTRAINT "friendships_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."friendships"
    ADD CONSTRAINT "friendships_user_a_fkey" FOREIGN KEY ("user_a") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."friendships"
    ADD CONSTRAINT "friendships_user_b_fkey" FOREIGN KEY ("user_b") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_matchups"
    ADD CONSTRAINT "league_matchups_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_message_reactions"
    ADD CONSTRAINT "league_message_reactions_message_id_fkey" FOREIGN KEY ("message_id") REFERENCES "public"."league_messages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_message_reactions"
    ADD CONSTRAINT "league_message_reactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_messages"
    ADD CONSTRAINT "league_messages_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_messages"
    ADD CONSTRAINT "league_messages_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."league_seasons"
    ADD CONSTRAINT "league_seasons_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."leagues"
    ADD CONSTRAINT "leagues_creator_id_fkey" FOREIGN KEY ("creator_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."leagues"
    ADD CONSTRAINT "leagues_parent_league_id_fkey" FOREIGN KEY ("parent_league_id") REFERENCES "public"."leagues"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."message_responses"
    ADD CONSTRAINT "message_responses_message_id_fkey" FOREIGN KEY ("message_id") REFERENCES "public"."league_messages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."message_responses"
    ADD CONSTRAINT "message_responses_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_games"
    ADD CONSTRAINT "player_games_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."players_cache"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_nicknames"
    ADD CONSTRAINT "player_nicknames_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_nicknames"
    ADD CONSTRAINT "player_nicknames_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_values"
    ADD CONSTRAINT "player_values_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."player_values"
    ADD CONSTRAINT "player_values_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."push_notifications"
    ADD CONSTRAINT "push_notifications_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."team_snapshots"
    ADD CONSTRAINT "team_snapshots_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."team_snapshots"
    ADD CONSTRAINT "team_snapshots_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."teams"
    ADD CONSTRAINT "teams_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."teams"
    ADD CONSTRAINT "teams_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."trade_votes"
    ADD CONSTRAINT "trade_votes_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trade_votes"
    ADD CONSTRAINT "trade_votes_trade_id_fkey" FOREIGN KEY ("trade_id") REFERENCES "public"."trades"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trades"
    ADD CONSTRAINT "trades_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trades"
    ADD CONSTRAINT "trades_parent_trade_id_fkey" FOREIGN KEY ("parent_trade_id") REFERENCES "public"."trades"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trades"
    ADD CONSTRAINT "trades_proposer_team_id_fkey" FOREIGN KEY ("proposer_team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trades"
    ADD CONSTRAINT "trades_recipient_team_id_fkey" FOREIGN KEY ("recipient_team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transactions"
    ADD CONSTRAINT "transactions_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."waiver_claims"
    ADD CONSTRAINT "waiver_claims_league_id_fkey" FOREIGN KEY ("league_id") REFERENCES "public"."leagues"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."waiver_claims"
    ADD CONSTRAINT "waiver_claims_team_id_fkey" FOREIGN KEY ("team_id") REFERENCES "public"."teams"("id") ON DELETE CASCADE;



ALTER TABLE "public"."adp" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "adp_read" ON "public"."adp" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."app_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_settings_read" ON "public"."app_settings" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "app_settings_write" ON "public"."app_settings" USING ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = "auth"."uid"()) AND ("p"."is_admin" = true))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = "auth"."uid"()) AND ("p"."is_admin" = true)))));



ALTER TABLE "public"."depth_charts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "depth_charts_read" ON "public"."depth_charts" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."device_tokens" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "device_tokens_select" ON "public"."device_tokens" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."dm_messages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dm_messages_delete" ON "public"."dm_messages" FOR DELETE USING (("sender_id" = "auth"."uid"()));



CREATE POLICY "dm_messages_insert" ON "public"."dm_messages" FOR INSERT WITH CHECK ((("sender_id" = "auth"."uid"()) AND "public"."is_dm_participant"("thread_id")));



CREATE POLICY "dm_messages_read" ON "public"."dm_messages" FOR SELECT USING ("public"."is_dm_participant"("thread_id"));



ALTER TABLE "public"."dm_threads" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dm_threads_insert" ON "public"."dm_threads" FOR INSERT WITH CHECK ((("auth"."uid"() = "user_a") OR ("auth"."uid"() = "user_b")));



CREATE POLICY "dm_threads_read" ON "public"."dm_threads" FOR SELECT USING ((("auth"."uid"() = "user_a") OR ("auth"."uid"() = "user_b")));



ALTER TABLE "public"."draft_picks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "draft_picks_read" ON "public"."draft_picks" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."draft_queues" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "draft_queues_read" ON "public"."draft_queues" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."drafts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "drafts_commish" ON "public"."drafts" USING ((EXISTS ( SELECT 1
   FROM "public"."leagues" "l"
  WHERE (("l"."id" = "drafts"."league_id") AND ("l"."creator_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."leagues" "l"
  WHERE (("l"."id" = "drafts"."league_id") AND ("l"."creator_id" = "auth"."uid"())))));



CREATE POLICY "drafts_read" ON "public"."drafts" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."dropped_players" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "dropped_players_read" ON "public"."dropped_players" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "dropped_players_write" ON "public"."dropped_players" USING (((EXISTS ( SELECT 1
   FROM "public"."teams" "t"
  WHERE (("t"."league_id" = "dropped_players"."league_id") AND ("t"."owner_id" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM "public"."leagues" "l"
  WHERE (("l"."id" = "dropped_players"."league_id") AND ("l"."creator_id" = "auth"."uid"())))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."teams" "t"
  WHERE (("t"."league_id" = "dropped_players"."league_id") AND ("t"."owner_id" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM "public"."leagues" "l"
  WHERE (("l"."id" = "dropped_players"."league_id") AND ("l"."creator_id" = "auth"."uid"()))))));



ALTER TABLE "public"."feedback" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."feedback_comments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "feedback_comments_delete" ON "public"."feedback_comments" FOR DELETE USING ((("user_id" = "auth"."uid"()) OR "public"."is_app_admin"()));



CREATE POLICY "feedback_comments_insert" ON "public"."feedback_comments" FOR INSERT WITH CHECK ((("user_id" = "auth"."uid"()) AND "public"."can_access_feedback"("feedback_id")));



CREATE POLICY "feedback_comments_read" ON "public"."feedback_comments" FOR SELECT USING ("public"."can_access_feedback"("feedback_id"));



CREATE POLICY "feedback_delete" ON "public"."feedback" FOR DELETE USING ((("user_id" = "auth"."uid"()) OR "public"."is_app_admin"()));



CREATE POLICY "feedback_insert" ON "public"."feedback" FOR INSERT WITH CHECK ((("user_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."profiles" "p"
  WHERE (("p"."id" = "auth"."uid"()) AND (("p"."is_tester" = true) OR ("p"."is_admin" = true)))))));



CREATE POLICY "feedback_read" ON "public"."feedback" FOR SELECT USING ((("user_id" = "auth"."uid"()) OR "public"."is_app_admin"()));



CREATE POLICY "feedback_update" ON "public"."feedback" FOR UPDATE USING ("public"."is_app_admin"()) WITH CHECK ("public"."is_app_admin"());



ALTER TABLE "public"."friendships" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "friendships_delete" ON "public"."friendships" FOR DELETE USING ((("auth"."uid"() = "user_a") OR ("auth"."uid"() = "user_b")));



CREATE POLICY "friendships_insert" ON "public"."friendships" FOR INSERT WITH CHECK ((("requested_by" = "auth"."uid"()) AND (("auth"."uid"() = "user_a") OR ("auth"."uid"() = "user_b")) AND ("status" = 'pending'::"text")));



CREATE POLICY "friendships_read" ON "public"."friendships" FOR SELECT USING ((("auth"."uid"() = "user_a") OR ("auth"."uid"() = "user_b")));



CREATE POLICY "friendships_update" ON "public"."friendships" FOR UPDATE USING (((("auth"."uid"() = "user_a") OR ("auth"."uid"() = "user_b")) AND ("auth"."uid"() <> "requested_by") AND ("status" = 'pending'::"text"))) WITH CHECK (("status" = 'accepted'::"text"));



ALTER TABLE "public"."inactives" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inactives_read" ON "public"."inactives" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."injuries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "injuries_read" ON "public"."injuries" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."injury_history" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "injury_history_read" ON "public"."injury_history" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."league_matchups" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "league_matchups_read" ON "public"."league_matchups" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."league_message_reactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."league_messages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "league_messages_delete" ON "public"."league_messages" FOR DELETE USING ((("user_id" = "auth"."uid"()) OR (EXISTS ( SELECT 1
   FROM "public"."leagues" "l"
  WHERE (("l"."id" = "league_messages"."league_id") AND ("l"."creator_id" = "auth"."uid"()))))));



CREATE POLICY "league_messages_insert" ON "public"."league_messages" FOR INSERT WITH CHECK ((("user_id" = "auth"."uid"()) AND "public"."is_league_member"("league_id")));



CREATE POLICY "league_messages_read" ON "public"."league_messages" FOR SELECT USING ("public"."is_league_member"("league_id"));



CREATE POLICY "league_reactions_delete" ON "public"."league_message_reactions" FOR DELETE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "league_reactions_insert" ON "public"."league_message_reactions" FOR INSERT WITH CHECK ((("user_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."league_messages" "m"
  WHERE (("m"."id" = "league_message_reactions"."message_id") AND "public"."is_league_member"("m"."league_id"))))));



CREATE POLICY "league_reactions_read" ON "public"."league_message_reactions" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."league_messages" "m"
  WHERE (("m"."id" = "league_message_reactions"."message_id") AND "public"."is_league_member"("m"."league_id")))));



ALTER TABLE "public"."league_seasons" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "league_seasons_read" ON "public"."league_seasons" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."leagues" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "leagues_delete_creator" ON "public"."leagues" FOR DELETE USING (("creator_id" = "auth"."uid"()));



CREATE POLICY "leagues_insert_creator" ON "public"."leagues" FOR INSERT WITH CHECK (("creator_id" = "auth"."uid"()));



CREATE POLICY "leagues_read_authed" ON "public"."leagues" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "leagues_update_creator" ON "public"."leagues" FOR UPDATE USING (("creator_id" = "auth"."uid"()));



ALTER TABLE "public"."live_scores" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "live_scores_read" ON "public"."live_scores" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."message_responses" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "message_responses_delete" ON "public"."message_responses" FOR DELETE USING (("user_id" = "auth"."uid"()));



CREATE POLICY "message_responses_insert" ON "public"."message_responses" FOR INSERT WITH CHECK ((("user_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "public"."league_messages" "m"
  WHERE (("m"."id" = "message_responses"."message_id") AND "public"."is_league_member"("m"."league_id"))))));



CREATE POLICY "message_responses_read" ON "public"."message_responses" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."league_messages" "m"
  WHERE (("m"."id" = "message_responses"."message_id") AND "public"."is_league_member"("m"."league_id")))));



CREATE POLICY "message_responses_update" ON "public"."message_responses" FOR UPDATE USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."most_started" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."most_started_history" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "most_started_history_read" ON "public"."most_started_history" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "most_started_read" ON "public"."most_started" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."nfl_schedules" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "nfl_schedules_read" ON "public"."nfl_schedules" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."nfl_team_ranks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nfl_team_ranks_history" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "nfl_team_ranks_history_read" ON "public"."nfl_team_ranks_history" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."nfl_teams" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "nfl_teams_read" ON "public"."nfl_teams" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."player_games" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "player_games_read" ON "public"."player_games" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."player_nicknames" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "player_nicknames_read" ON "public"."player_nicknames" FOR SELECT USING ("public"."is_league_member"("league_id"));



ALTER TABLE "public"."player_values" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "player_values_read" ON "public"."player_values" FOR SELECT USING ("public"."is_league_member"("league_id"));



ALTER TABLE "public"."players_cache" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "players_cache_read" ON "public"."players_cache" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."plays" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "plays_read" ON "public"."plays" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_insert_self" ON "public"."profiles" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "profiles_read_all" ON "public"."profiles" FOR SELECT USING (true);



CREATE POLICY "profiles_update_self" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "profiles_update_theme_self" ON "public"."profiles" FOR UPDATE USING (("id" = "auth"."uid"())) WITH CHECK (("id" = "auth"."uid"()));



ALTER TABLE "public"."push_notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "push_notifications_admin_all" ON "public"."push_notifications" USING ("public"."is_app_admin"()) WITH CHECK ("public"."is_app_admin"());



ALTER TABLE "public"."seasons" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "seasons_read" ON "public"."seasons" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."snap_counts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "snap_counts_read" ON "public"."snap_counts" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "team_ranks_read" ON "public"."nfl_team_ranks" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."team_snapshots" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "team_snapshots_read" ON "public"."team_snapshots" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "team_snapshots_write" ON "public"."team_snapshots" USING ((EXISTS ( SELECT 1
   FROM "public"."leagues" "l"
  WHERE (("l"."id" = "team_snapshots"."league_id") AND ("l"."creator_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."leagues" "l"
  WHERE (("l"."id" = "team_snapshots"."league_id") AND ("l"."creator_id" = "auth"."uid"())))));



ALTER TABLE "public"."teams" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "teams_commish_update" ON "public"."teams" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."leagues" "l"
  WHERE (("l"."id" = "teams"."league_id") AND ("l"."creator_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."leagues" "l"
  WHERE (("l"."id" = "teams"."league_id") AND ("l"."creator_id" = "auth"."uid"())))));



CREATE POLICY "teams_insert_creator" ON "public"."teams" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."leagues"
  WHERE (("leagues"."id" = "teams"."league_id") AND ("leagues"."creator_id" = "auth"."uid"())))));



CREATE POLICY "teams_read_authed" ON "public"."teams" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "teams_update_owner" ON "public"."teams" FOR UPDATE USING ((("owner_id" = "auth"."uid"()) OR (("owner_id" IS NULL) AND ("auth"."role"() = 'authenticated'::"text"))));



ALTER TABLE "public"."trade_votes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trade_votes_read" ON "public"."trade_votes" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."trades" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trades_read" ON "public"."trades" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."transactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "transactions_insert" ON "public"."transactions" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."teams" "t"
  WHERE (("t"."id" = "transactions"."team_id") AND ("t"."owner_id" = "auth"."uid"())))));



CREATE POLICY "transactions_read" ON "public"."transactions" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "transactions_update" ON "public"."transactions" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."leagues" "l"
  WHERE (("l"."id" = "transactions"."league_id") AND ("l"."creator_id" = "auth"."uid"())))));



ALTER TABLE "public"."trending_history" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trending_history_read" ON "public"."trending_history" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."trending_players" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trending_read" ON "public"."trending_players" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."waiver_claims" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "waiver_claims_read" ON "public"."waiver_claims" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "waiver_claims_write" ON "public"."waiver_claims" USING ((EXISTS ( SELECT 1
   FROM "public"."teams" "t"
  WHERE (("t"."id" = "waiver_claims"."team_id") AND ("t"."owner_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."teams" "t"
  WHERE (("t"."id" = "waiver_claims"."team_id") AND ("t"."owner_id" = "auth"."uid"())))));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."app_settings";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."dm_messages";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."draft_picks";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."draft_queues";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."drafts";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."dropped_players";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."friendships";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."league_message_reactions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."league_messages";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."live_scores";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."message_responses";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."player_nicknames";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."player_values";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."trade_votes";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."trades";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."transactions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."waiver_claims";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";














































































































































































GRANT ALL ON TABLE "public"."friendships" TO "anon";
GRANT ALL ON TABLE "public"."friendships" TO "authenticated";
GRANT ALL ON TABLE "public"."friendships" TO "service_role";



GRANT ALL ON FUNCTION "public"."accept_friend_request"("p_other_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_friend_request"("p_other_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_friend_request"("p_other_user" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."trades" TO "anon";
GRANT ALL ON TABLE "public"."trades" TO "authenticated";
GRANT ALL ON TABLE "public"."trades" TO "service_role";



GRANT ALL ON FUNCTION "public"."accept_trade"("p_trade_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_trade"("p_trade_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_trade"("p_trade_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."append_poll_option"("p_message_id" "uuid", "p_option" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."append_poll_option"("p_message_id" "uuid", "p_option" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."append_poll_option"("p_message_id" "uuid", "p_option" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."attempt_execute_trade"("p_trade_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."attempt_execute_trade"("p_trade_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."attempt_execute_trade"("p_trade_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_dm_thread_last_message"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_dm_thread_last_message"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_dm_thread_last_message"() TO "service_role";



GRANT ALL ON FUNCTION "public"."can_access_feedback"("p_feedback_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."can_access_feedback"("p_feedback_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_access_feedback"("p_feedback_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."cancel_trade"("p_trade_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."cancel_trade"("p_trade_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_trade"("p_trade_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."push_notifications" TO "anon";
GRANT ALL ON TABLE "public"."push_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."push_notifications" TO "service_role";



GRANT ALL ON FUNCTION "public"."claim_push_notifications"("p_id" "uuid", "p_limit" integer, "p_lease_seconds" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."claim_push_notifications"("p_id" "uuid", "p_limit" integer, "p_lease_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."claim_push_notifications"("p_id" "uuid", "p_limit" integer, "p_lease_seconds" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."clear_dropped_nicknames"() TO "anon";
GRANT ALL ON FUNCTION "public"."clear_dropped_nicknames"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_dropped_nicknames"() TO "service_role";



GRANT ALL ON FUNCTION "public"."clear_dropped_values"() TO "anon";
GRANT ALL ON FUNCTION "public"."clear_dropped_values"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_dropped_values"() TO "service_role";



GRANT ALL ON FUNCTION "public"."commish_resolve_trade"("p_trade_id" "uuid", "p_approve" boolean, "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."commish_resolve_trade"("p_trade_id" "uuid", "p_approve" boolean, "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."commish_resolve_trade"("p_trade_id" "uuid", "p_approve" boolean, "p_note" "text") TO "service_role";



GRANT ALL ON TABLE "public"."leagues" TO "anon";
GRANT ALL ON TABLE "public"."leagues" TO "authenticated";
GRANT ALL ON TABLE "public"."leagues" TO "service_role";



GRANT ALL ON FUNCTION "public"."complete_league_season"("p_league_id" "uuid", "p_champion_team_id" "uuid", "p_champion_team_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."complete_league_season"("p_league_id" "uuid", "p_champion_team_id" "uuid", "p_champion_team_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."complete_league_season"("p_league_id" "uuid", "p_champion_team_id" "uuid", "p_champion_team_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."dvp_ranks"("p_season" integer, "p_position" "text", "p_scoring" "text", "p_up_to_week" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."dvp_ranks"("p_season" integer, "p_position" "text", "p_scoring" "text", "p_up_to_week" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."dvp_ranks"("p_season" integer, "p_position" "text", "p_scoring" "text", "p_up_to_week" integer) TO "service_role";



GRANT ALL ON TABLE "public"."dm_threads" TO "anon";
GRANT ALL ON TABLE "public"."dm_threads" TO "authenticated";
GRANT ALL ON TABLE "public"."dm_threads" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_or_create_dm_thread"("p_other_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_or_create_dm_thread"("p_other_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_or_create_dm_thread"("p_other_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."invoke_edge_function"("fn" "text", "body" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."invoke_edge_function"("fn" "text", "body" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."invoke_edge_function"("fn" "text", "body" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_app_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_app_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_app_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_dm_participant"("p_thread_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_dm_participant"("p_thread_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_dm_participant"("p_thread_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_league_member"("p_league_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_league_member"("p_league_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_league_member"("p_league_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."drafts" TO "anon";
GRANT ALL ON TABLE "public"."drafts" TO "authenticated";
GRANT ALL ON TABLE "public"."drafts" TO "service_role";



GRANT ALL ON FUNCTION "public"."make_pick"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text", "p_is_auto" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."make_pick"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text", "p_is_auto" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."make_pick"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text", "p_is_auto" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."pause_draft"("p_draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."pause_draft"("p_draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."pause_draft"("p_draft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."player_career"("p_player_id" "text", "p_scoring" "text", "p_use_custom" boolean, "p_pass_yards_per_point" numeric, "p_pass_td" numeric, "p_interception" numeric, "p_rush_yards_per_point" numeric, "p_rush_td" numeric, "p_rec_yards_per_point" numeric, "p_rec_td" numeric, "p_reception" numeric, "p_fumble_lost" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."player_career"("p_player_id" "text", "p_scoring" "text", "p_use_custom" boolean, "p_pass_yards_per_point" numeric, "p_pass_td" numeric, "p_interception" numeric, "p_rush_yards_per_point" numeric, "p_rush_td" numeric, "p_rec_yards_per_point" numeric, "p_rec_td" numeric, "p_reception" numeric, "p_fumble_lost" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."player_career"("p_player_id" "text", "p_scoring" "text", "p_use_custom" boolean, "p_pass_yards_per_point" numeric, "p_pass_td" numeric, "p_interception" numeric, "p_rush_yards_per_point" numeric, "p_rush_td" numeric, "p_rec_yards_per_point" numeric, "p_rec_td" numeric, "p_reception" numeric, "p_fumble_lost" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."player_nickname_history"("p_player_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."player_nickname_history"("p_player_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."player_nickname_history"("p_player_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."propose_trade"("p_league_id" "uuid", "p_proposer_team_id" "uuid", "p_recipient_team_id" "uuid", "p_proposer_player_ids" "text"[], "p_recipient_player_ids" "text"[], "p_note" "text", "p_parent_trade_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."propose_trade"("p_league_id" "uuid", "p_proposer_team_id" "uuid", "p_recipient_team_id" "uuid", "p_proposer_player_ids" "text"[], "p_recipient_player_ids" "text"[], "p_note" "text", "p_parent_trade_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."propose_trade"("p_league_id" "uuid", "p_proposer_team_id" "uuid", "p_recipient_team_id" "uuid", "p_proposer_player_ids" "text"[], "p_recipient_player_ids" "text"[], "p_note" "text", "p_parent_trade_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."push_notifications_set_creator"() TO "anon";
GRANT ALL ON FUNCTION "public"."push_notifications_set_creator"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."push_notifications_set_creator"() TO "service_role";



GRANT ALL ON FUNCTION "public"."queue_add"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."queue_add"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."queue_add"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."queue_remove"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."queue_remove"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."queue_remove"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."queue_reorder"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_ids" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."queue_reorder"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_ids" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."queue_reorder"("p_draft_id" "uuid", "p_team_id" "uuid", "p_player_ids" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."register_device_token"("p_token" "text", "p_environment" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."register_device_token"("p_token" "text", "p_environment" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_device_token"("p_token" "text", "p_environment" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reject_trade"("p_trade_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reject_trade"("p_trade_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_trade"("p_trade_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."reset_all"("p_league_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reset_all"("p_league_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_all"("p_league_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."reset_draft"("p_league_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reset_draft"("p_league_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_draft"("p_league_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."reset_period"("p_league_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reset_period"("p_league_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_period"("p_league_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."resume_draft"("p_draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."resume_draft"("p_draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resume_draft"("p_draft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rollover_league"("p_parent_id" "uuid", "p_new_season" integer, "p_new_name" "text", "p_schedule" "jsonb", "p_waiver_priority" "text"[], "p_teams" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."rollover_league"("p_parent_id" "uuid", "p_new_season" integer, "p_new_name" "text", "p_schedule" "jsonb", "p_waiver_priority" "text"[], "p_teams" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rollover_league"("p_parent_id" "uuid", "p_new_season" integer, "p_new_name" "text", "p_schedule" "jsonb", "p_waiver_priority" "text"[], "p_teams" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."send_friend_request"("p_other_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."send_friend_request"("p_other_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_friend_request"("p_other_user" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON FUNCTION "public"."set_admin_role"("p_user" "uuid", "p_is_admin" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."set_admin_role"("p_user" "uuid", "p_is_admin" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_admin_role"("p_user" "uuid", "p_is_admin" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_auto_pick"("p_draft_id" "uuid", "p_team_id" "uuid", "p_enabled" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."set_auto_pick"("p_draft_id" "uuid", "p_team_id" "uuid", "p_enabled" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_auto_pick"("p_draft_id" "uuid", "p_team_id" "uuid", "p_enabled" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_player_nickname"("p_team_id" "uuid", "p_player_id" "text", "p_nickname" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."set_player_nickname"("p_team_id" "uuid", "p_player_id" "text", "p_nickname" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_player_nickname"("p_team_id" "uuid", "p_player_id" "text", "p_nickname" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_player_value"("p_team_id" "uuid", "p_player_id" "text", "p_value" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."set_player_value"("p_team_id" "uuid", "p_player_id" "text", "p_value" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_player_value"("p_team_id" "uuid", "p_player_id" "text", "p_value" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_tester_role"("p_user" "uuid", "p_is_tester" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."set_tester_role"("p_user" "uuid", "p_is_tester" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_tester_role"("p_user" "uuid", "p_is_tester" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."snapshot_teams"("p_league_id" "uuid", "p_week" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."snapshot_teams"("p_league_id" "uuid", "p_week" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."snapshot_teams"("p_league_id" "uuid", "p_week" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."start_draft"("p_draft_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."start_draft"("p_draft_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."start_draft"("p_draft_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."tag_with_simulated_week"() TO "anon";
GRANT ALL ON FUNCTION "public"."tag_with_simulated_week"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tag_with_simulated_week"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tally_trade_vote"("p_trade_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."tally_trade_vote"("p_trade_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."tally_trade_vote"("p_trade_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."team_on_clock"("p_draft_id" "uuid", "p_pick" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."team_on_clock"("p_draft_id" "uuid", "p_pick" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."team_on_clock"("p_draft_id" "uuid", "p_pick" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."team_ranks_at_week"("p_season" integer, "p_up_to_week" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."team_ranks_at_week"("p_season" integer, "p_up_to_week" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."team_ranks_at_week"("p_season" integer, "p_up_to_week" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."unregister_device_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."unregister_device_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unregister_device_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."vote_trade"("p_trade_id" "uuid", "p_vote" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."vote_trade"("p_trade_id" "uuid", "p_vote" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vote_trade"("p_trade_id" "uuid", "p_vote" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."write_league_matchups"("p_league_id" "uuid", "p_season" integer, "p_matchups" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."write_league_matchups"("p_league_id" "uuid", "p_season" integer, "p_matchups" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."write_league_matchups"("p_league_id" "uuid", "p_season" integer, "p_matchups" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."write_league_season_archive"("p_league_id" "uuid", "p_season" integer, "p_standings" "jsonb", "p_scoring_leader_team_id" "uuid", "p_scoring_leader_name" "text", "p_champion_team_id" "uuid", "p_champion_team_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."write_league_season_archive"("p_league_id" "uuid", "p_season" integer, "p_standings" "jsonb", "p_scoring_leader_team_id" "uuid", "p_scoring_leader_name" "text", "p_champion_team_id" "uuid", "p_champion_team_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."write_league_season_archive"("p_league_id" "uuid", "p_season" integer, "p_standings" "jsonb", "p_scoring_leader_team_id" "uuid", "p_scoring_leader_name" "text", "p_champion_team_id" "uuid", "p_champion_team_name" "text") TO "service_role";
























GRANT ALL ON TABLE "public"."adp" TO "anon";
GRANT ALL ON TABLE "public"."adp" TO "authenticated";
GRANT ALL ON TABLE "public"."adp" TO "service_role";



GRANT ALL ON TABLE "public"."app_settings" TO "anon";
GRANT ALL ON TABLE "public"."app_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."app_settings" TO "service_role";



GRANT ALL ON TABLE "public"."nfl_schedules" TO "anon";
GRANT ALL ON TABLE "public"."nfl_schedules" TO "authenticated";
GRANT ALL ON TABLE "public"."nfl_schedules" TO "service_role";



GRANT ALL ON TABLE "public"."seasons" TO "anon";
GRANT ALL ON TABLE "public"."seasons" TO "authenticated";
GRANT ALL ON TABLE "public"."seasons" TO "service_role";



GRANT ALL ON TABLE "public"."available_seasons" TO "anon";
GRANT ALL ON TABLE "public"."available_seasons" TO "authenticated";
GRANT ALL ON TABLE "public"."available_seasons" TO "service_role";



GRANT ALL ON TABLE "public"."depth_charts" TO "anon";
GRANT ALL ON TABLE "public"."depth_charts" TO "authenticated";
GRANT ALL ON TABLE "public"."depth_charts" TO "service_role";



GRANT ALL ON TABLE "public"."device_tokens" TO "anon";
GRANT ALL ON TABLE "public"."device_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."device_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."dm_messages" TO "anon";
GRANT ALL ON TABLE "public"."dm_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."dm_messages" TO "service_role";



GRANT ALL ON TABLE "public"."draft_picks" TO "anon";
GRANT ALL ON TABLE "public"."draft_picks" TO "authenticated";
GRANT ALL ON TABLE "public"."draft_picks" TO "service_role";



GRANT ALL ON TABLE "public"."draft_queues" TO "anon";
GRANT ALL ON TABLE "public"."draft_queues" TO "authenticated";
GRANT ALL ON TABLE "public"."draft_queues" TO "service_role";



GRANT ALL ON TABLE "public"."dropped_players" TO "anon";
GRANT ALL ON TABLE "public"."dropped_players" TO "authenticated";
GRANT ALL ON TABLE "public"."dropped_players" TO "service_role";



GRANT ALL ON TABLE "public"."player_games" TO "anon";
GRANT ALL ON TABLE "public"."player_games" TO "authenticated";
GRANT ALL ON TABLE "public"."player_games" TO "service_role";



GRANT ALL ON TABLE "public"."players_cache" TO "anon";
GRANT ALL ON TABLE "public"."players_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."players_cache" TO "service_role";



GRANT ALL ON TABLE "public"."dvp_weekly" TO "anon";
GRANT ALL ON TABLE "public"."dvp_weekly" TO "authenticated";
GRANT ALL ON TABLE "public"."dvp_weekly" TO "service_role";



GRANT ALL ON TABLE "public"."feedback" TO "anon";
GRANT ALL ON TABLE "public"."feedback" TO "authenticated";
GRANT ALL ON TABLE "public"."feedback" TO "service_role";



GRANT ALL ON TABLE "public"."feedback_comments" TO "anon";
GRANT ALL ON TABLE "public"."feedback_comments" TO "authenticated";
GRANT ALL ON TABLE "public"."feedback_comments" TO "service_role";



GRANT ALL ON TABLE "public"."inactives" TO "anon";
GRANT ALL ON TABLE "public"."inactives" TO "authenticated";
GRANT ALL ON TABLE "public"."inactives" TO "service_role";



GRANT ALL ON TABLE "public"."injuries" TO "anon";
GRANT ALL ON TABLE "public"."injuries" TO "authenticated";
GRANT ALL ON TABLE "public"."injuries" TO "service_role";



GRANT ALL ON TABLE "public"."injury_history" TO "anon";
GRANT ALL ON TABLE "public"."injury_history" TO "authenticated";
GRANT ALL ON TABLE "public"."injury_history" TO "service_role";



GRANT ALL ON TABLE "public"."league_matchups" TO "anon";
GRANT ALL ON TABLE "public"."league_matchups" TO "authenticated";
GRANT ALL ON TABLE "public"."league_matchups" TO "service_role";



GRANT ALL ON TABLE "public"."league_message_reactions" TO "anon";
GRANT ALL ON TABLE "public"."league_message_reactions" TO "authenticated";
GRANT ALL ON TABLE "public"."league_message_reactions" TO "service_role";



GRANT ALL ON TABLE "public"."league_messages" TO "anon";
GRANT ALL ON TABLE "public"."league_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."league_messages" TO "service_role";



GRANT ALL ON TABLE "public"."league_seasons" TO "anon";
GRANT ALL ON TABLE "public"."league_seasons" TO "authenticated";
GRANT ALL ON TABLE "public"."league_seasons" TO "service_role";



GRANT ALL ON TABLE "public"."live_scores" TO "anon";
GRANT ALL ON TABLE "public"."live_scores" TO "authenticated";
GRANT ALL ON TABLE "public"."live_scores" TO "service_role";



GRANT ALL ON TABLE "public"."message_responses" TO "anon";
GRANT ALL ON TABLE "public"."message_responses" TO "authenticated";
GRANT ALL ON TABLE "public"."message_responses" TO "service_role";



GRANT ALL ON TABLE "public"."most_started" TO "anon";
GRANT ALL ON TABLE "public"."most_started" TO "authenticated";
GRANT ALL ON TABLE "public"."most_started" TO "service_role";



GRANT ALL ON TABLE "public"."most_started_history" TO "anon";
GRANT ALL ON TABLE "public"."most_started_history" TO "authenticated";
GRANT ALL ON TABLE "public"."most_started_history" TO "service_role";



GRANT ALL ON TABLE "public"."nfl_team_ranks" TO "anon";
GRANT ALL ON TABLE "public"."nfl_team_ranks" TO "authenticated";
GRANT ALL ON TABLE "public"."nfl_team_ranks" TO "service_role";



GRANT ALL ON TABLE "public"."nfl_team_ranks_history" TO "anon";
GRANT ALL ON TABLE "public"."nfl_team_ranks_history" TO "authenticated";
GRANT ALL ON TABLE "public"."nfl_team_ranks_history" TO "service_role";



GRANT ALL ON TABLE "public"."nfl_teams" TO "anon";
GRANT ALL ON TABLE "public"."nfl_teams" TO "authenticated";
GRANT ALL ON TABLE "public"."nfl_teams" TO "service_role";



GRANT ALL ON TABLE "public"."player_nicknames" TO "anon";
GRANT ALL ON TABLE "public"."player_nicknames" TO "authenticated";
GRANT ALL ON TABLE "public"."player_nicknames" TO "service_role";



GRANT ALL ON TABLE "public"."player_season_totals" TO "anon";
GRANT ALL ON TABLE "public"."player_season_totals" TO "authenticated";
GRANT ALL ON TABLE "public"."player_season_totals" TO "service_role";



GRANT ALL ON TABLE "public"."player_values" TO "anon";
GRANT ALL ON TABLE "public"."player_values" TO "authenticated";
GRANT ALL ON TABLE "public"."player_values" TO "service_role";



GRANT ALL ON TABLE "public"."plays" TO "anon";
GRANT ALL ON TABLE "public"."plays" TO "authenticated";
GRANT ALL ON TABLE "public"."plays" TO "service_role";



GRANT ALL ON TABLE "public"."snap_counts" TO "anon";
GRANT ALL ON TABLE "public"."snap_counts" TO "authenticated";
GRANT ALL ON TABLE "public"."snap_counts" TO "service_role";



GRANT ALL ON TABLE "public"."team_snapshots" TO "anon";
GRANT ALL ON TABLE "public"."team_snapshots" TO "authenticated";
GRANT ALL ON TABLE "public"."team_snapshots" TO "service_role";



GRANT ALL ON TABLE "public"."teams" TO "anon";
GRANT ALL ON TABLE "public"."teams" TO "authenticated";
GRANT ALL ON TABLE "public"."teams" TO "service_role";



GRANT ALL ON TABLE "public"."trade_votes" TO "anon";
GRANT ALL ON TABLE "public"."trade_votes" TO "authenticated";
GRANT ALL ON TABLE "public"."trade_votes" TO "service_role";



GRANT ALL ON TABLE "public"."transactions" TO "anon";
GRANT ALL ON TABLE "public"."transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."transactions" TO "service_role";



GRANT ALL ON TABLE "public"."trending_history" TO "anon";
GRANT ALL ON TABLE "public"."trending_history" TO "authenticated";
GRANT ALL ON TABLE "public"."trending_history" TO "service_role";



GRANT ALL ON TABLE "public"."trending_players" TO "anon";
GRANT ALL ON TABLE "public"."trending_players" TO "authenticated";
GRANT ALL ON TABLE "public"."trending_players" TO "service_role";



GRANT ALL ON TABLE "public"."waiver_claims" TO "anon";
GRANT ALL ON TABLE "public"."waiver_claims" TO "authenticated";
GRANT ALL ON TABLE "public"."waiver_claims" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































