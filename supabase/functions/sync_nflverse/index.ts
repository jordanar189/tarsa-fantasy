// Mirrors nflverse weekly player stats into Supabase. Runs daily via pg_cron.
//
// Body (all optional):
//   { "seasons": [2023, 2024, 2025] }       // explicit list
//   { "from": 2023 }                         // from this year through current
//   {}                                       // default: previous + current + next
//
// Reads stats_player_week_{year}.csv from the new "stats_player" release tag
// (nflverse renamed from "player_stats" in 2025). Also pulls roster_{year}.csv
// to populate espn_id for ESPN live-score cross-referencing + player bio.
//
// When a season's stats CSV 404s (off-season / pre-Week 1, e.g. the upcoming
// year), it falls back to a roster-only refresh: players_cache is updated from
// roster_{year}.csv so teams/rookies are ready for off-season drafts, with no
// player_games or `seasons` row written.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL          = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY      = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const STATS_URL_TEMPLATE    = "https://github.com/nflverse/nflverse-data/releases/download/stats_player/stats_player_week_{YEAR}.csv";
const ROSTERS_URL_TEMPLATE  = "https://github.com/nflverse/nflverse-data/releases/download/rosters/roster_{YEAR}.csv";

const supa = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

interface PlayerRow {
    id: string; espn_id: string | null; name: string;
    position: string; position_group: string;
    team: string; headshot_url: string;
    // Bio columns added in the Phase 1 stats overhaul. All nullable —
    // upserts only set them when the rosters CSV provided a value.
    birth_date?: string | null;
    height_in?: number | null;
    weight_lb?: number | null;
    college?: string | null;
    jersey_number?: number | null;
    draft_year?: number | null;
    draft_round?: number | null;
    draft_pick?: number | null;
    years_exp?: number | null;
    status?: string | null;
}
interface GameRow {
    player_id: string; season: number; week: number;
    team: string; opponent: string;
    completions: number; attempts: number;
    passing_yards: number; passing_tds: number; passing_interceptions: number;
    carries: number; rushing_yards: number; rushing_tds: number;
    receptions: number; targets: number;
    receiving_yards: number; receiving_tds: number;
    fumbles_lost: number;
    fantasy_points: number; fantasy_points_ppr: number; fantasy_points_half_ppr: number;
    // Kicking (made FGs bucketed by distance + PATs + misses). Zero for non-kickers.
    fg_made_0_19: number; fg_made_20_29: number; fg_made_30_39: number;
    fg_made_40_49: number; fg_made_50_59: number; fg_made_60: number;
    fg_missed: number; pat_made: number; pat_missed: number;
    // Team defense, aggregated per team-week onto the DEF_<TEAM> row — and,
    // since the IDP pipeline, also filled per defender on individual rows.
    def_sacks: number; def_interceptions: number; def_fumble_recoveries: number;
    def_tds: number; def_safeties: number;
    def_points_allowed: number | null;
    // Per-defender IDP counting stats (zero on DST + offensive rows).
    def_tackles_solo: number; def_tackle_assists: number;
    def_tackles_for_loss: number; def_qb_hits: number;
    def_pass_defended: number; def_fumbles_forced: number;
}

// Per team-week defensive accumulator, summed across every player on the team.
// Turned into one DEF_<TEAM> game row once points allowed is joined from the
// schedule.
interface DefenseAgg {
    team: string; season: number; week: number; opponent: string;
    sacks: number; interceptions: number; fumble_recoveries: number;
    tds: number; safeties: number;
}

// All-zero kicking + defense fields, spread into offensive/kicker game rows so
// every row carries the full column set for the upsert.
const ZERO_SPECIAL = {
    fg_made_0_19: 0, fg_made_20_29: 0, fg_made_30_39: 0, fg_made_40_49: 0,
    fg_made_50_59: 0, fg_made_60: 0, fg_missed: 0, pat_made: 0, pat_missed: 0,
    def_sacks: 0, def_interceptions: 0, def_fumble_recoveries: 0,
    def_tds: 0, def_safeties: 0, def_points_allowed: null as number | null,
    def_tackles_solo: 0, def_tackle_assists: 0, def_tackles_for_loss: 0,
    def_qb_hits: 0, def_pass_defended: 0, def_fumbles_forced: 0,
};

// IDP columns read per player row. Names are taken from the nflverse
// stats_player_week data dictionary; the parser zero-fills any that are
// missing and syncSeason reports found/missing per season, so a rename in
// the upstream CSV surfaces in the sync response instead of silently
// zeroing a stat.
const IDP_CSV_COLUMNS = [
    "def_tackles_solo", "def_tackle_assists", "def_tackles_for_loss",
    "def_qb_hits", "def_pass_defended", "def_fumbles_forced",
    "def_sacks", "def_interceptions", "fumble_recovery_opp",
    "def_tds", "def_safeties",
];

Deno.serve(async (req: Request) => {
    try {
        const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
        const seasons = pickSeasons(body);
        const results: Record<number, unknown> = {};
        for (const year of seasons) {
            results[year] = await syncSeason(year);
        }
        return new Response(JSON.stringify({ ok: true, seasons: results }), {
            headers: { "Content-Type": "application/json" }
        });
    } catch (err) {
        console.error(err);
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

function pickSeasons(body: { seasons?: number[]; from?: number }): number[] {
    const now = new Date();
    // NFL "season year" is the calendar year of Week 1. Week 1 is early Sep,
    // so before that, the latest finished season is last year.
    const currentSeason = now.getUTCMonth() >= 8 // Sep+
        ? now.getUTCFullYear()
        : now.getUTCFullYear() - 1;
    if (body.seasons?.length) return body.seasons;
    if (body.from != null) {
        const out: number[] = [];
        for (let y = body.from; y <= currentSeason; y++) out.push(y);
        return out;
    }
    // Default: previous + current (re-sync recent in case of stat corrections)
    // plus the upcoming season. The upcoming year has no weekly stats CSV until
    // games are played; syncSeason falls back to a roster-only refresh so player
    // teams and incoming rookies are ready for off-season drafts.
    return [currentSeason - 1, currentSeason, currentSeason + 1];
}

async function syncSeason(year: number): Promise<unknown> {
    const url = STATS_URL_TEMPLATE.replace("{YEAR}", String(year));
    const resp = await fetch(url);
    if (resp.status === 404) {
        // No weekly stats yet (off-season / pre-Week 1). Still refresh the
        // roster so player teams reflect the upcoming season and rookies/free
        // agents appear for draft prep. Best-effort: skips if rosters 404 too.
        return await syncRostersOnly(year);
    }
    if (!resp.ok) {
        return { error: `stats HTTP ${resp.status}` };
    }
    const csv = await resp.text();
    const { players, games, defense, idpColumns } = parseStatsCsv(csv);
    if (players.size === 0) return { error: "empty parse" };

    // Build one team-defense (DST) game row per team-week. Points allowed is the
    // opponent's final score, joined from the already-synced schedule; rows whose
    // score isn't known yet (game not final) keep a null tier input. Only teams
    // with a seeded DEF_<TEAM> player get a row, so historical relocated-team
    // codes (OAK/SD/STL) don't trip the player_games foreign key.
    const pointsAllowed = await fetchPointsAllowed(year);
    const validDefenseIDs = await fetchDefensePlayerIDs();
    const defenseRows: GameRow[] = [];
    for (const agg of defense.values()) {
        const defID = `DEF_${agg.team}`;
        if (!validDefenseIDs.has(defID)) continue;
        const pa = pointsAllowed.get(`${agg.team}|${agg.week}`);
        defenseRows.push({
            ...ZERO_SPECIAL,
            player_id: defID,
            season: agg.season, week: agg.week,
            team: agg.team, opponent: agg.opponent,
            completions: 0, attempts: 0,
            passing_yards: 0, passing_tds: 0, passing_interceptions: 0,
            carries: 0, rushing_yards: 0, rushing_tds: 0,
            receptions: 0, targets: 0, receiving_yards: 0, receiving_tds: 0,
            fumbles_lost: 0,
            // K/DST points are computed app-side from the raw stats below, so the
            // precomputed fantasy fields stay 0 (the app adds the special points).
            fantasy_points: 0, fantasy_points_ppr: 0, fantasy_points_half_ppr: 0,
            def_sacks: round2(agg.sacks),
            def_interceptions: round2(agg.interceptions),
            def_fumble_recoveries: round2(agg.fumble_recoveries),
            def_tds: round2(agg.tds),
            def_safeties: round2(agg.safeties),
            def_points_allowed: pa ?? null,
        });
    }

    // Augment with rosters data: ESPN IDs (for live-score xref) + bio columns.
    // Optional — sync still works if the rosters CSV 404s.
    const rosterByGsis = await fetchRosterMap(year);
    for (const [pid, r] of rosterByGsis) {
        const p = players.get(pid);
        if (!p) continue;
        if (r.espn_id) p.espn_id = r.espn_id;
        p.birth_date    = r.birth_date    ?? null;
        p.height_in     = r.height_in     ?? null;
        p.weight_lb     = r.weight_lb     ?? null;
        p.college       = r.college       ?? null;
        p.jersey_number = r.jersey_number ?? null;
        p.draft_year    = r.draft_year    ?? null;
        p.draft_round   = r.draft_round   ?? null;
        p.draft_pick    = r.draft_pick    ?? null;
        p.years_exp     = r.years_exp     ?? null;
        p.status        = r.status        ?? null;
    }

    // Upsert in chunks to stay within PostgREST payload limits.
    const playerRows = [...players.values()];
    const gameRows   = [...games, ...defenseRows];

    await upsertChunks("players_cache", playerRows, 500, "id");
    await upsertChunks("player_games",  gameRows,  500, "player_id,season,week");

    await supa.from("seasons").upsert({
        season: year,
        games_count: gameRows.length,
        last_synced_at: new Date().toISOString()
    });

    return {
        players: playerRows.length, games: gameRows.length, defenses: defenseRows.length,
        idp_columns: idpColumns,
    };
}

// Off-season fallback: no weekly stats CSV yet, so refresh players_cache from
// the rosters CSV alone. Updates each player's team to the upcoming season and
// surfaces rookies / free-agent moves for draft prep. Writes no player_games
// and no `seasons` row — season availability is driven by the schedule, and a
// stats-less season must not look like it has stats. Skips cleanly if the
// rosters CSV isn't published yet either.
async function syncRostersOnly(year: number): Promise<unknown> {
    const players = await fetchRosterPlayers(year);
    if (players.length === 0) return { skipped: "not_published_yet" };
    await upsertChunks("players_cache", players, 500, "id");
    return { rosters_only: players.length };
}

// [`${team}|${week}`: points allowed] for a season, derived from the synced
// schedule's final scores (a team's points allowed = its opponent's score).
// Games without a final score yet are omitted. Empty if schedules aren't synced.
async function fetchPointsAllowed(year: number): Promise<Map<string, number>> {
    interface SchedRow {
        week: number; home_team: string; away_team: string;
        home_score: number | null; away_score: number | null;
    }
    const { data, error } = await supa.from("nfl_schedules")
        .select("week, home_team, away_team, home_score, away_score")
        .eq("season", year);
    const out = new Map<string, number>();
    if (error || !data) return out;
    for (const r of data as SchedRow[]) {
        if (r.home_score == null || r.away_score == null) continue;
        out.set(`${r.home_team}|${r.week}`, r.away_score);
        out.set(`${r.away_team}|${r.week}`, r.home_score);
    }
    return out;
}

// The set of seeded team-defense player ids ("DEF_KC", …). DST game rows are
// only written for these so the player_games FK to players_cache always holds.
async function fetchDefensePlayerIDs(): Promise<Set<string>> {
    const { data, error } = await supa.from("players_cache")
        .select("id").eq("position", "DEF");
    const out = new Set<string>();
    if (error || !data) return out;
    for (const r of data as { id: string }[]) out.add(r.id);
    return out;
}

async function fetchRosterPlayers(year: number): Promise<PlayerRow[]> {
    const map = await fetchRosterMap(year);
    const out: PlayerRow[] = [];
    for (const [gsis, r] of map) {
        if (!r.name || !r.position) continue;   // need at least identity + position
        out.push({
            id: gsis,
            espn_id: r.espn_id ?? null,
            name: r.name,
            position: r.position,
            position_group: positionGroup(r.position),
            team: r.team ?? "",
            headshot_url: r.headshot_url ?? "",
            birth_date:    r.birth_date    ?? null,
            height_in:     r.height_in     ?? null,
            weight_lb:     r.weight_lb     ?? null,
            college:       r.college       ?? null,
            jersey_number: r.jersey_number ?? null,
            draft_year:    r.draft_year    ?? null,
            draft_round:   r.draft_round   ?? null,
            draft_pick:    r.draft_pick    ?? null,
            years_exp:     r.years_exp     ?? null,
            status:        r.status        ?? null,
        });
    }
    return out;
}

// Rosters CSV has no position_group column; derive a reasonable one. Display
// only and overwritten with the authoritative value once the stats sync runs.
// Defenders group to DL/LB/DB — the client's IDP slots and position filters
// match by group, and rookies exist only via this roster-only path until
// their first stat line.
function positionGroup(pos: string): string {
    const p = pos.toUpperCase();
    if (p === "QB") return "QB";
    if (p === "RB" || p === "FB" || p === "HB") return "RB";
    if (p === "WR") return "WR";
    if (p === "TE") return "TE";
    if (p === "K" || p === "PK") return "K";
    if (p === "DE" || p === "DT" || p === "NT" || p === "EDGE" || p === "DL") return "DL";
    if (p === "ILB" || p === "OLB" || p === "MLB" || p === "LB") return "LB";
    if (p === "CB" || p === "S" || p === "FS" || p === "SS" || p === "SAF" || p === "DB") return "DB";
    return p;
}

interface RosterFields {
    espn_id?: string;
    // Identity fields — only consumed by the roster-only sync path. The weekly
    // stats path ignores these (it takes name/position/team from the stats CSV).
    name?: string;
    position?: string;
    team?: string;
    headshot_url?: string;
    birth_date?: string;
    height_in?: number;
    weight_lb?: number;
    college?: string;
    jersey_number?: number;
    draft_year?: number;
    draft_round?: number;
    draft_pick?: number;
    years_exp?: number;
    status?: string;
}

async function fetchRosterMap(year: number): Promise<Map<string, RosterFields>> {
    const url = ROSTERS_URL_TEMPLATE.replace("{YEAR}", String(year));
    const resp = await fetch(url);
    if (!resp.ok) return new Map();
    const csv = await resp.text();
    const rows = parseCsv(csv);
    const header = rows.shift();
    if (!header) return new Map();
    const ix = {
        gsis:       header.indexOf("gsis_id"),
        espn:       header.indexOf("espn_id"),
        name:       header.indexOf("full_name") >= 0 ? header.indexOf("full_name") : header.indexOf("player_name"),
        position:   header.indexOf("position"),
        team:       header.indexOf("team"),
        headshot:   header.indexOf("headshot_url"),
        birth:      header.indexOf("birth_date"),
        height:     header.indexOf("height"),
        weight:     header.indexOf("weight"),
        college:    header.indexOf("college"),
        jersey:     header.indexOf("jersey_number"),
        draftYear:  header.indexOf("rookie_year") >= 0 ? header.indexOf("rookie_year") : header.indexOf("entry_year"),
        draftRound: header.indexOf("draft_round"),   // -1 if missing; we'll compute
        draftPick:  header.indexOf("draft_number"),
        yearsExp:   header.indexOf("years_exp"),
        status:     header.indexOf("status"),
    };
    if (ix.gsis < 0) return new Map();
    const out = new Map<string, RosterFields>();
    for (const r of rows) {
        const gsis = r[ix.gsis]?.trim();
        if (!gsis) continue;
        const fields: RosterFields = {};
        const espn = ix.espn >= 0 ? r[ix.espn]?.trim() : "";
        if (espn && espn !== "NA") fields.espn_id = espn;

        const name = ix.name >= 0 ? r[ix.name]?.trim() : "";
        if (name && name !== "NA") fields.name = name;
        const position = ix.position >= 0 ? r[ix.position]?.trim() : "";
        if (position && position !== "NA") fields.position = position;
        const team = ix.team >= 0 ? r[ix.team]?.trim() : "";
        if (team && team !== "NA") fields.team = team;
        const headshot = ix.headshot >= 0 ? r[ix.headshot]?.trim() : "";
        if (headshot && headshot !== "NA") fields.headshot_url = headshot;

        const birth = ix.birth >= 0 ? r[ix.birth]?.trim() : "";
        if (birth && birth !== "NA") fields.birth_date = birth;
        const height = ix.height >= 0 ? numOrNull(r[ix.height]) : null;
        if (height != null) fields.height_in = Math.round(height);
        const weight = ix.weight >= 0 ? numOrNull(r[ix.weight]) : null;
        if (weight != null) fields.weight_lb = Math.round(weight);
        const college = ix.college >= 0 ? r[ix.college]?.trim() : "";
        if (college && college !== "NA") fields.college = college;
        const jersey = ix.jersey >= 0 ? numOrNull(r[ix.jersey]) : null;
        if (jersey != null) fields.jersey_number = Math.round(jersey);
        const dy = ix.draftYear >= 0 ? numOrNull(r[ix.draftYear]) : null;
        if (dy != null && dy > 0) fields.draft_year = Math.round(dy);
        // Pick: 0 / NA in nflverse means undrafted — store null, not 0.
        const dpRaw = ix.draftPick >= 0 ? numOrNull(r[ix.draftPick]) : null;
        const dp = dpRaw != null && dpRaw > 0 ? Math.round(dpRaw) : null;
        if (dp != null) fields.draft_pick = dp;
        // Round: prefer the CSV column when present, otherwise derive from
        // the overall pick. NFL rounds aren't exactly 32 picks (compensatory
        // picks shift things) but (pick - 1) / 32 + 1 puts everyone in the
        // right round through pick 224; beyond that the seventh round is
        // approximated. Good enough for a display label.
        const drRaw = ix.draftRound >= 0 ? numOrNull(r[ix.draftRound]) : null;
        const dr = drRaw != null && drRaw > 0
            ? Math.round(drRaw)
            : (dp != null ? Math.min(7, Math.floor((dp - 1) / 32) + 1) : null);
        if (dr != null) fields.draft_round = dr;
        const ye = ix.yearsExp >= 0 ? numOrNull(r[ix.yearsExp]) : null;
        if (ye != null) fields.years_exp = Math.round(ye);
        const status = ix.status >= 0 ? r[ix.status]?.trim() : "";
        if (status && status !== "NA") fields.status = status;

        out.set(gsis, fields);
    }
    return out;
}

function numOrNull(v: string | undefined): number | null {
    if (!v) return null;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA" || s.toUpperCase() === "NULL") return null;
    const n = Number(s);
    return Number.isFinite(n) ? n : null;
}

async function upsertChunks<T>(table: string, rows: T[], chunk: number, onConflict: string) {
    for (let i = 0; i < rows.length; i += chunk) {
        const slice = rows.slice(i, i + chunk);
        const { error } = await supa.from(table).upsert(slice, { onConflict });
        if (error) throw new Error(`upsert ${table}[${i}..${i+slice.length}]: ${error.message}`);
    }
}

function parseStatsCsv(csv: string): {
    players: Map<string, PlayerRow>; games: GameRow[]; defense: Map<string, DefenseAgg>;
    idpColumns: { found: string[]; missing: string[] };
} {
    const rows = parseCsv(csv);
    const header = rows.shift();
    if (!header) {
        return { players: new Map(), games: [], defense: new Map(),
                 idpColumns: { found: [], missing: IDP_CSV_COLUMNS } };
    }
    const col = (k: string) => header.indexOf(k);
    const idpColumns = {
        found:   IDP_CSV_COLUMNS.filter((k) => col(k) >= 0),
        missing: IDP_CSV_COLUMNS.filter((k) => col(k) < 0),
    };
    const ix = {
        season: col("season"), week: col("week"),
        season_type: col("season_type"),
        pid: col("player_id"),
        display: col("player_display_name"), name: col("player_name"),
        position: col("position"), position_group: col("position_group"),
        headshot: col("headshot_url"),
        team: col("team"), opp: col("opponent_team"),
        completions: col("completions"), attempts: col("attempts"),
        passYds: col("passing_yards"), passTds: col("passing_tds"), passInt: col("passing_interceptions"),
        carries: col("carries"), rushYds: col("rushing_yards"), rushTds: col("rushing_tds"),
        rec: col("receptions"), targets: col("targets"),
        recYds: col("receiving_yards"), recTds: col("receiving_tds"),
        fumSack: col("sack_fumbles_lost"), fumRush: col("rushing_fumbles_lost"), fumRec: col("receiving_fumbles_lost"),
        fp: col("fantasy_points"), fpPpr: col("fantasy_points_ppr"),
        // Kicking
        fgMade0_19: col("fg_made_0_19"), fgMade20_29: col("fg_made_20_29"),
        fgMade30_39: col("fg_made_30_39"), fgMade40_49: col("fg_made_40_49"),
        fgMade50_59: col("fg_made_50_59"), fgMade60: col("fg_made_60_"),
        fgMissed: col("fg_missed"), patMade: col("pat_made"), patMissed: col("pat_missed"),
        // Defense / special teams (per-player; aggregated to the team below)
        defSacks: col("def_sacks"), defInt: col("def_interceptions"),
        fumRecOpp: col("fumble_recovery_opp"),
        defTds: col("def_tds"), stTds: col("special_teams_tds"),
        defSafeties: col("def_safeties"),
        // IDP (per-player only; never aggregated onto the DST line)
        defTacklesSolo: col("def_tackles_solo"),
        defTackleAssists: col("def_tackle_assists"),
        defTfl: col("def_tackles_for_loss"),
        defQbHits: col("def_qb_hits"),
        defPd: col("def_pass_defended"),
        defFf: col("def_fumbles_forced"),
    };

    const players = new Map<string, PlayerRow>();
    const games: GameRow[] = [];
    const defense = new Map<string, DefenseAgg>();
    for (const r of rows) {
        if (ix.season_type >= 0 && (r[ix.season_type] ?? "").toUpperCase() !== "REG") continue;
        const pid = r[ix.pid]?.trim();
        if (!pid) continue;

        if (!players.has(pid)) {
            players.set(pid, {
                id: pid,
                espn_id: null,
                name: r[ix.display] ?? r[ix.name] ?? pid,
                position: r[ix.position] ?? "",
                position_group: r[ix.position_group] ?? "",
                team: r[ix.team] ?? "",
                headshot_url: r[ix.headshot] ?? ""
            });
        } else {
            const p = players.get(pid)!;
            if (r[ix.team]) p.team = r[ix.team]!;
        }

        const season = Math.trunc(num(r[ix.season]));
        const week   = Math.trunc(num(r[ix.week]));
        const team   = r[ix.team] ?? "";
        const opp    = r[ix.opp] ?? "";

        // Accumulate this player's defensive + return-TD contribution onto the
        // team's DST line for the week. Done for every row (a return TD can sit
        // on an offensive player's line), keyed by team-week.
        if (team) {
            const key = `${team}|${week}`;
            const agg = defense.get(key) ?? {
                team, season, week, opponent: opp,
                sacks: 0, interceptions: 0, fumble_recoveries: 0, tds: 0, safeties: 0,
            };
            agg.sacks            += num(r[ix.defSacks]);
            agg.interceptions    += num(r[ix.defInt]);
            agg.fumble_recoveries += num(r[ix.fumRecOpp]);
            agg.tds              += num(r[ix.defTds]) + num(r[ix.stTds]);
            agg.safeties         += num(r[ix.defSafeties]);
            if (!agg.opponent && opp) agg.opponent = opp;
            defense.set(key, agg);
        }

        const recs = num(r[ix.rec]);
        const fp = num(r[ix.fp]);
        games.push({
            ...ZERO_SPECIAL,
            player_id: pid,
            season, week, team, opponent: opp,
            completions: num(r[ix.completions]),
            attempts: num(r[ix.attempts]),
            passing_yards: num(r[ix.passYds]),
            passing_tds: num(r[ix.passTds]),
            passing_interceptions: num(r[ix.passInt]),
            carries: num(r[ix.carries]),
            rushing_yards: num(r[ix.rushYds]),
            rushing_tds: num(r[ix.rushTds]),
            receptions: recs,
            targets: num(r[ix.targets]),
            receiving_yards: num(r[ix.recYds]),
            receiving_tds: num(r[ix.recTds]),
            fumbles_lost: num(r[ix.fumSack]) + num(r[ix.fumRush]) + num(r[ix.fumRec]),
            fantasy_points: fp,
            fantasy_points_ppr: num(r[ix.fpPpr]),
            fantasy_points_half_ppr: round2(fp + 0.5 * recs),
            // Kicking inputs (zero for non-kickers).
            fg_made_0_19: num(r[ix.fgMade0_19]),
            fg_made_20_29: num(r[ix.fgMade20_29]),
            fg_made_30_39: num(r[ix.fgMade30_39]),
            fg_made_40_49: num(r[ix.fgMade40_49]),
            fg_made_50_59: num(r[ix.fgMade50_59]),
            fg_made_60: num(r[ix.fgMade60]),
            fg_missed: num(r[ix.fgMissed]),
            pat_made: num(r[ix.patMade]),
            pat_missed: num(r[ix.patMissed]),
            // Per-defender IDP line (zeros on offensive rows — the CSV carries
            // these columns for every row). def_points_allowed stays null from
            // ZERO_SPECIAL, so nothing here scores as a team defense.
            def_sacks: num(r[ix.defSacks]),
            def_interceptions: num(r[ix.defInt]),
            def_fumble_recoveries: num(r[ix.fumRecOpp]),
            def_tds: num(r[ix.defTds]),
            def_safeties: num(r[ix.defSafeties]),
            def_tackles_solo: num(r[ix.defTacklesSolo]),
            def_tackle_assists: num(r[ix.defTackleAssists]),
            def_tackles_for_loss: num(r[ix.defTfl]),
            def_qb_hits: num(r[ix.defQbHits]),
            def_pass_defended: num(r[ix.defPd]),
            def_fumbles_forced: num(r[ix.defFf]),
        });
    }
    return { players, games, defense, idpColumns };
}

function num(v: string | undefined): number {
    if (!v) return 0;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA" || s.toUpperCase() === "NULL") return 0;
    const n = Number(s);
    return Number.isFinite(n) ? n : 0;
}

function round2(x: number): number {
    return Math.round(x * 100) / 100;
}

// RFC 4180 CSV parser — handles quoted fields w/ embedded commas + newlines
// and "" for an escaped quote inside a quoted field.
function parseCsv(text: string): string[][] {
    const out: string[][] = [];
    let field = "", row: string[] = [], inQ = false;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (inQ) {
            if (c === "\"") {
                if (text[i + 1] === "\"") { field += "\""; i++; }
                else { inQ = false; }
            } else { field += c; }
        } else {
            if (c === "\"") inQ = true;
            else if (c === ",") { row.push(field); field = ""; }
            else if (c === "\r") { /* skip — handled by \n */ }
            else if (c === "\n") { row.push(field); field = ""; out.push(row); row = []; }
            else field += c;
        }
    }
    if (field.length > 0 || row.length > 0) { row.push(field); out.push(row); }
    return out;
}
