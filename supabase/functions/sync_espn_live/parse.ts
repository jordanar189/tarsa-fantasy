// Pure ESPN box-score / scoring-play parsing, split from index.ts so it can
// be unit-tested without pulling in the edge-function server or supabase-js.

// ESPN abbreviations that differ from the nflverse convention (same map as
// sync_schedules_espn, so DEF_<TEAM> ids and game_ids line up).
const TEAM_FIXUP: Record<string, string> = {
    WSH: "WAS", LA: "LAR", JAC: "JAX", OAK: "LV", SD: "LAC", STL: "LAR",
};
export function fixTeam(abbr: string): string {
    const up = (abbr ?? "").toUpperCase();
    return TEAM_FIXUP[up] ?? up;
}

// Raw counting stats, keyed by our live_scores/player_games column names.
export type StatMap = Record<string, number>;

export interface LiveRow {
    player_id: string; season: number; week: number;
    fantasy_points: number; fantasy_points_ppr: number; fantasy_points_half_ppr: number;
    is_final: boolean;
    [col: string]: string | number | boolean | null;
}

export interface EspnSummary {
    boxscore?: {
        players?: Array<{
            statistics?: Array<{
                name?: string;
                labels?: string[];
                athletes?: Array<{
                    athlete?: { id?: number | string; displayName?: string };
                    stats?: string[];
                }>;
            }>;
        }>;
        teams?: Array<{
            team?: { abbreviation?: string };
            statistics?: Array<{ name?: string; displayValue?: string }>;
        }>;
    };
    scoringPlays?: Array<{
        text?: string;
        team?: { abbreviation?: string };
        type?: { text?: string };
    }>;
}

export interface Side { team: string; homeAway: string; score: number }

// Standard preset scoring (offense only — K/DST points always derive from
// the raw columns app-side, mirroring nflverse's fantasy_points convention):
//   pass yd × 0.04, pass TD × 4, INT × -2
//   rush yd × 0.1, rush TD × 6
//   rec × 1 (PPR) / 0.5 (half), rec yd × 0.1, rec TD × 6
//   fumble lost × -2
export function makeRow(
    playerID: string, season: number, week: number, s: StatMap, isFinal: boolean
): LiveRow {
    const std =
        (s.passing_yards ?? 0) * 0.04 + (s.passing_tds ?? 0) * 4
        - (s.passing_interceptions ?? 0) * 2
        + (s.rushing_yards ?? 0) * 0.1 + (s.rushing_tds ?? 0) * 6
        + (s.receiving_yards ?? 0) * 0.1 + (s.receiving_tds ?? 0) * 6
        - (s.fumbles_lost ?? 0) * 2;
    const rec = s.receptions ?? 0;
    const row: LiveRow = {
        player_id: playerID, season, week,
        fantasy_points:          round2(std),
        fantasy_points_ppr:      round2(std + rec),
        fantasy_points_half_ppr: round2(std + rec * 0.5),
        is_final: isFinal,
        def_points_allowed: null,
    };
    for (const [k, v] of Object.entries(s)) row[k] = v;
    return row;
}

export function extractPlayerStats(
    summary: EspnSummary, espnIDtoGsis: Map<string, string>
): Map<string, StatMap> {
    const out = new Map<string, StatMap>();
    const boxscore = summary?.boxscore?.players ?? [];

    for (const teamBox of boxscore) {
        for (const cat of teamBox?.statistics ?? []) {
            const labels = cat.labels ?? [];
            const name = (cat.name ?? "").toLowerCase();
            for (const athleteEntry of cat.athletes ?? []) {
                const athleteID = String(athleteEntry?.athlete?.id ?? "");
                const gsis = espnIDtoGsis.get(athleteID);
                if (!gsis) continue;
                const stats = athleteEntry.stats ?? [];
                if (!out.has(gsis)) out.set(gsis, {});
                mergeCategory(out.get(gsis)!, name, labels, stats,
                              athleteEntry?.athlete?.displayName ?? "");
            }
        }
    }
    return out;
}

function mergeCategory(
    acc: StatMap, catName: string, labels: string[], stats: string[],
    displayName: string
): void {
    const idx = (label: string) => labels.indexOf(label);
    const num = (label: string) => {
        const i = idx(label);
        if (i < 0 || i >= stats.length) return 0;
        const n = Number((stats[i] ?? "").split("/")[0]);
        return Number.isFinite(n) ? n : 0;
    };
    // "12/20"-style pairs (C/ATT, FG, XP): both halves.
    const pair = (label: string): [number, number] => {
        const i = idx(label);
        if (i < 0 || i >= stats.length) return [0, 0];
        const parts = (stats[i] ?? "").split("/");
        const a = Number(parts[0]), b = Number(parts[1]);
        return [Number.isFinite(a) ? a : 0, Number.isFinite(b) ? b : 0];
    };

    if (catName === "passing") {
        const [comp, att] = pair("C/ATT");
        acc.completions = comp;
        acc.attempts = att;
        acc.passing_yards = num("YDS");
        acc.passing_tds = num("TD");
        acc.passing_interceptions = num("INT");
    } else if (catName === "rushing") {
        acc.carries = num("CAR");
        acc.rushing_yards = num("YDS");
        acc.rushing_tds = num("TD");
    } else if (catName === "receiving") {
        acc.receptions = num("REC");
        acc.receiving_yards = num("YDS");
        acc.receiving_tds = num("TD");
        acc.targets = num("TGTS");
    } else if (catName === "fumbles") {
        acc.fumbles_lost = num("LOST");
    } else if (catName === "kicking") {
        const [fgMade, fgAtt] = pair("FG");
        const [xpMade, xpAtt] = pair("XP");
        acc.fg_missed = Math.max(0, fgAtt - fgMade);
        acc.pat_made = xpMade;
        acc.pat_missed = Math.max(0, xpAtt - xpMade);
        // Distance buckets come from the scoring plays; stash the make count
        // and name so applyFieldGoalDistances can reconcile.
        acc.__fg_made_total = fgMade;
        (acc as Record<string, unknown>).__kicker_name = displayName;
    }
}

// The box score has FG makes/attempts but not distances; scoring plays carry
// "<Kicker Name> 43 Yd Field Goal". Bucket each make by matching the play
// text against the kicker names collected above. Makes the play texts don't
// account for land in the mid-value 30-39 bucket.
export function applyFieldGoalDistances(summary: EspnSummary, lines: Map<string, StatMap>) {
    const kickers: { gsis: string; name: string; acc: StatMap }[] = [];
    for (const [gsis, acc] of lines) {
        const name = (acc as Record<string, unknown>).__kicker_name;
        if (typeof name === "string" && name.length > 0) {
            kickers.push({ gsis, name: name.toLowerCase(), acc });
        }
    }

    if (kickers.length > 0) {
        for (const play of summary?.scoringPlays ?? []) {
            const text = (play?.text ?? "").toLowerCase();
            const m = text.match(/(\d+)\s*(?:yd|yard)s?\s*field goal/);
            if (!m) continue;
            const yards = Number(m[1]);
            const kicker = kickers.find(k => text.includes(k.name));
            if (!kicker) continue;
            const bucket =
                yards < 20 ? "fg_made_0_19" :
                yards < 30 ? "fg_made_20_29" :
                yards < 40 ? "fg_made_30_39" :
                yards < 50 ? "fg_made_40_49" :
                yards < 60 ? "fg_made_50_59" : "fg_made_60";
            kicker.acc[bucket] = (kicker.acc[bucket] ?? 0) + 1;
        }
    }

    for (const { acc } of kickers) {
        const made = acc.__fg_made_total ?? 0;
        const bucketed =
            (acc.fg_made_0_19 ?? 0) + (acc.fg_made_20_29 ?? 0) + (acc.fg_made_30_39 ?? 0)
            + (acc.fg_made_40_49 ?? 0) + (acc.fg_made_50_59 ?? 0) + (acc.fg_made_60 ?? 0);
        if (made > bucketed) {
            acc.fg_made_30_39 = (acc.fg_made_30_39 ?? 0) + (made - bucketed);
        }
        delete acc.__fg_made_total;
        delete (acc as Record<string, unknown>).__kicker_name;
    }
}

// Team-defense rows: the defense's production is the opponent's offensive
// misery (times sacked, INTs thrown, fumbles lost), defensive/return TDs and
// safeties come from the scoring plays, points allowed is the opponent's
// scoreboard total (the standard convention).
export function synthesizeDST(
    summary: EspnSummary, home: Side | undefined, away: Side | undefined
): Map<string, StatMap> {
    const out = new Map<string, StatMap>();
    if (!home?.team || !away?.team) return out;

    const teamStats = new Map<string, Map<string, string>>();
    for (const t of summary?.boxscore?.teams ?? []) {
        const abbr = fixTeam(t?.team?.abbreviation ?? "");
        const m = new Map<string, string>();
        for (const s of t?.statistics ?? []) {
            if (s?.name) m.set(s.name, s.displayValue ?? "");
        }
        teamStats.set(abbr, m);
    }

    const firstNum = (v: string | undefined) => {
        const n = Number((v ?? "").split("-")[0]);
        return Number.isFinite(n) ? n : 0;
    };

    for (const [side, opp] of [[home, away], [away, home]] as [Side, Side][]) {
        const oppOffense = teamStats.get(opp.team);
        const stats: StatMap = {
            def_sacks:              firstNum(oppOffense?.get("sacksYardsLost")),
            def_interceptions:      firstNum(oppOffense?.get("interceptions")),
            def_fumble_recoveries:  firstNum(oppOffense?.get("fumblesLost")),
            def_tds: 0,
            def_safeties: 0,
        };
        stats.def_points_allowed = opp.score;
        out.set(`DEF_${side.team}`, stats);
    }

    for (const play of summary?.scoringPlays ?? []) {
        const abbr = fixTeam(play?.team?.abbreviation ?? "");
        const acc = out.get(`DEF_${abbr}`);
        if (!acc) continue;
        const text = (play?.text ?? "").toLowerCase();
        const type = (play?.type?.text ?? "").toLowerCase();
        if (type === "safety" || text.includes("safety")) {
            acc.def_safeties = (acc.def_safeties ?? 0) + 1;
        } else if (/interception return|fumble return|fumble recovery.*touchdown|blocked (punt|field goal).*touchdown|punt return.*touchdown|kickoff return.*touchdown/.test(text)) {
            acc.def_tds = (acc.def_tds ?? 0) + 1;
        }
    }
    return out;
}

function round2(x: number): number { return Math.round(x * 100) / 100; }
