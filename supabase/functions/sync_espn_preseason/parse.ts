// Preseason ESPN parsing: scoreboard events → preseason_games rows, and the
// summary box score → per-athlete stat lines. Unlike sync_espn_live's parser
// this keeps EVERY athlete (a quarter of a preseason box score is players
// nflverse has never seen — the roster battles preseason is about) and adds
// kick/punt returns. Pure and deno-testable; no I/O.

import { fixTeam } from "../sync_espn_live/parse.ts";

export type StatMap = Record<string, number>;

// Every stat column on preseason_player_stats, in table order. Rows sent to
// PostgREST in one bulk upsert must all carry the same keys, so lines are
// always materialised against this list (0 where the category was absent).
export const STAT_COLUMNS = [
    "completions", "attempts", "passing_yards", "passing_tds", "passing_interceptions", "sacks_taken",
    "carries", "rushing_yards", "rushing_tds", "rushing_long",
    "receptions", "targets", "receiving_yards", "receiving_tds", "receiving_long",
    "fumbles", "fumbles_lost",
    "def_tackles_solo", "def_tackle_assists", "def_sacks", "def_tackles_for_loss",
    "def_qb_hits", "def_pass_defended", "def_interceptions", "def_tds",
    "kick_returns", "kick_return_yards", "kick_return_tds",
    "punt_returns", "punt_return_yards", "punt_return_tds",
    "fg_made", "fg_att", "fg_long", "pat_made", "pat_att",
] as const;

export interface BoxLine {
    espnAthleteID: string;
    name: string;
    jersey: string | null;
    team: string;
    opponent: string;
    stats: StatMap;
}

export interface EspnBoxSummary {
    boxscore?: {
        players?: Array<{
            team?: { abbreviation?: string };
            statistics?: Array<{
                name?: string;
                labels?: string[];
                athletes?: Array<{
                    athlete?: { id?: number | string; displayName?: string; jersey?: string };
                    stats?: string[];
                }>;
            }>;
        }>;
    };
    scoringPlays?: EspnScoringPlay[];
}

export interface EspnScoringPlay {
    id?: string;
    text?: string;
    type?: { text?: string; abbreviation?: string };
    period?: { number?: number };
    clock?: { displayValue?: string };
    awayScore?: number;
    homeScore?: number;
    team?: { abbreviation?: string };
}

export function extractBoxScore(summary: EspnBoxSummary): BoxLine[] {
    const teamBoxes = summary.boxscore?.players ?? [];
    const teams = teamBoxes.map(p => fixTeam(p.team?.abbreviation ?? ""));
    const out = new Map<string, BoxLine>();

    teamBoxes.forEach((teamBox, i) => {
        const team = teams[i];
        const opponent = teams.find((_, j) => j !== i) ?? "";
        for (const cat of teamBox.statistics ?? []) {
            const labels = cat.labels ?? [];
            const name = (cat.name ?? "").toLowerCase();
            for (const entry of cat.athletes ?? []) {
                const id = String(entry.athlete?.id ?? "");
                if (!id) continue;
                let line = out.get(id);
                if (!line) {
                    line = {
                        espnAthleteID: id,
                        name: entry.athlete?.displayName ?? "",
                        jersey: entry.athlete?.jersey ?? null,
                        team, opponent, stats: {},
                    };
                    out.set(id, line);
                }
                mergeCategory(line.stats, name, labels, entry.stats ?? []);
            }
        }
    });

    for (const line of out.values()) finalise(line.stats);
    return [...out.values()];
}

function mergeCategory(acc: StatMap, cat: string, labels: string[], stats: string[]): void {
    const idx = (label: string) => labels.indexOf(label);
    // Leading number of a cell: "12/20" → 12, "3-21" → 3, "45.5" → 45.5.
    const num = (label: string) => {
        const i = idx(label);
        if (i < 0 || i >= stats.length) return 0;
        const n = parseFloat((stats[i] ?? "").split("/")[0]);
        return Number.isFinite(n) ? n : 0;
    };
    const pair = (label: string): [number, number] => {
        const i = idx(label);
        if (i < 0 || i >= stats.length) return [0, 0];
        const [a, b] = (stats[i] ?? "").split("/").map(Number);
        return [Number.isFinite(a) ? a : 0, Number.isFinite(b) ? b : 0];
    };

    switch (cat) {
        case "passing": {
            const [comp, att] = pair("C/ATT");
            acc.completions = comp;
            acc.attempts = att;
            acc.passing_yards = num("YDS");
            acc.passing_tds = num("TD");
            acc.passing_interceptions = num("INT");
            acc.sacks_taken = num("SACKS");
            break;
        }
        case "rushing":
            acc.carries = num("CAR");
            acc.rushing_yards = num("YDS");
            acc.rushing_tds = num("TD");
            acc.rushing_long = num("LONG");
            break;
        case "receiving":
            acc.receptions = num("REC");
            acc.receiving_yards = num("YDS");
            acc.receiving_tds = num("TD");
            acc.receiving_long = num("LONG");
            acc.targets = num("TGTS");
            break;
        case "fumbles":
            acc.fumbles = num("FUM");
            acc.fumbles_lost = num("LOST");
            break;
        case "defensive": {
            const total = num("TOT");
            const solo = num("SOLO");
            acc.def_tackles_solo = solo;
            acc.def_tackle_assists = Math.max(0, total - solo);
            acc.def_sacks = num("SACKS");
            acc.def_tackles_for_loss = num("TFL");
            acc.def_pass_defended = num("PD");
            acc.def_qb_hits = num("QB HTS");
            // A pick-six shows in both the defensive and interceptions TD
            // columns — max() rather than sum avoids the double count.
            acc.def_tds = Math.max(acc.def_tds ?? 0, num("TD"));
            break;
        }
        case "interceptions":
            acc.def_interceptions = num("INT");
            acc.def_tds = Math.max(acc.def_tds ?? 0, num("TD"));
            break;
        case "kickreturns":
            acc.kick_returns = num("NO");
            acc.kick_return_yards = num("YDS");
            acc.kick_return_tds = num("TD");
            break;
        case "puntreturns":
            acc.punt_returns = num("NO");
            acc.punt_return_yards = num("YDS");
            acc.punt_return_tds = num("TD");
            break;
        case "kicking": {
            const [fgMade, fgAtt] = pair("FG");
            const [xpMade, xpAtt] = pair("XP");
            acc.fg_made = fgMade;
            acc.fg_att = fgAtt;
            acc.fg_long = num("LONG");
            acc.pat_made = xpMade;
            acc.pat_att = xpAtt;
            break;
        }
        // punting and anything new ESPN adds: ignored.
    }
}

function finalise(s: StatMap): void {
    for (const col of STAT_COLUMNS) if (s[col] == null) s[col] = 0;
    const pts = fantasyPoints(s);
    s.fantasy_points = pts.std;
    s.fantasy_points_ppr = pts.ppr;
    s.fantasy_points_half_ppr = pts.half;
}

// Same preset formula as sync_espn_live's makeRow — display only; preseason
// never feeds league scoring.
export function fantasyPoints(s: StatMap): { std: number; ppr: number; half: number } {
    const std =
        (s.passing_yards ?? 0) * 0.04 + (s.passing_tds ?? 0) * 4
        - (s.passing_interceptions ?? 0) * 2
        + (s.rushing_yards ?? 0) * 0.1 + (s.rushing_tds ?? 0) * 6
        + (s.receiving_yards ?? 0) * 0.1 + (s.receiving_tds ?? 0) * 6
        - (s.fumbles_lost ?? 0) * 2;
    const rec = s.receptions ?? 0;
    return { std: round2(std), ppr: round2(std + rec), half: round2(std + rec * 0.5) };
}

function round2(x: number): number { return Math.round(x * 100) / 100; }

// ---- Scoreboard events → preseason_games rows ----

export interface EspnScoreboard {
    events?: EspnEvent[];
    season?: { year?: number; type?: number };
    week?: { number?: number };
    leagues?: Array<{
        calendar?: Array<{
            label?: string;
            value?: string | number;
            entries?: Array<{ label?: string; value?: string | number }>;
        }>;
    }>;
}

export interface EspnEvent {
    id: string;
    date?: string;
    season?: { year?: number; type?: number };
    week?: { number?: number };
    status?: {
        period?: number;
        displayClock?: string;
        type?: { name?: string; state?: string; completed?: boolean; shortDetail?: string; detail?: string };
    };
    competitions?: Array<{
        venue?: { fullName?: string };
        competitors?: Array<{
            homeAway?: string;
            score?: string | number;
            team?: { abbreviation?: string };
            linescores?: Array<{ value?: number; period?: number }>;
        }>;
    }>;
}

export interface GameRow {
    game_id: string;
    season: number;
    pre_week: number;
    week_label: string;
    home_team: string;
    away_team: string;
    home_score: number | null;
    away_score: number | null;
    home_linescores: number[];
    away_linescores: number[];
    status: string;
    period: number | null;
    clock: string | null;
    status_detail: string | null;
    kickoff: string | null;
    venue: string | null;
    updated_at: string;
}

export function isPreseason(ev: EspnEvent, scoreboardType?: number): boolean {
    return (ev.season?.type ?? scoreboardType) === 1;
}

export function gameStatus(ev: EspnEvent): string {
    const t = ev.status?.type;
    const name = (t?.name ?? "").toUpperCase();
    if (name.includes("POSTPONED") || name.includes("CANCEL")) return "postponed";
    if (t?.state === "in") return "in_progress";
    if (t?.state === "post" && t?.completed === true) return "final";
    return "scheduled";
}

export function gameRowFromEvent(ev: EspnEvent, weekLabel: string, now = new Date()): GameRow | null {
    const comp = ev.competitions?.[0];
    const home = comp?.competitors?.find(c => c.homeAway === "home");
    const away = comp?.competitors?.find(c => c.homeAway === "away");
    const homeTeam = fixTeam(home?.team?.abbreviation ?? "");
    const awayTeam = fixTeam(away?.team?.abbreviation ?? "");
    const season = ev.season?.year;
    const preWeek = ev.week?.number;
    if (!homeTeam || !awayTeam || !season || !preWeek) return null;

    const status = gameStatus(ev);
    const score = (c: typeof home) => {
        if (status === "scheduled") return null;
        const n = Number(c?.score);
        return Number.isFinite(n) ? n : null;
    };
    const lines = (c: typeof home) =>
        (c?.linescores ?? []).map(l => Math.trunc(Number(l.value ?? 0)));

    return {
        game_id: ev.id,
        season,
        pre_week: preWeek,
        week_label: weekLabel,
        home_team: homeTeam,
        away_team: awayTeam,
        home_score: score(home),
        away_score: score(away),
        home_linescores: lines(home),
        away_linescores: lines(away),
        status,
        period: status === "scheduled" ? null : (ev.status?.period ?? null),
        clock: status === "in_progress" ? (ev.status?.displayClock ?? null) : null,
        status_detail: ev.status?.type?.shortDetail ?? ev.status?.type?.detail ?? null,
        kickoff: ev.date ?? null,
        venue: comp?.venue?.fullName ?? null,
        updated_at: now.toISOString(),
    };
}

// ESPN's own label for a preseason week ("Hall of Fame Weekend", "Preseason
// Week 2", …) from the scoreboard calendar; falls back to the conventional
// naming when the calendar isn't present (older cached responses, tests).
export function preseasonWeekLabel(sb: EspnScoreboard, preWeek: number): string {
    const pre = sb.leagues?.[0]?.calendar?.find(c => String(c.value) === "1");
    const entry = pre?.entries?.find(e => String(e.value) === String(preWeek));
    if (entry?.label) return entry.label;
    return preWeek === 1 ? "Hall of Fame Weekend" : `Preseason Week ${preWeek - 1}`;
}

export interface ScoringPlayRow {
    text: string; type: string | null; period: number | null; clock: string | null;
    away: number | null; home: number | null; team: string | null;
}

export function compactScoringPlays(summary: EspnBoxSummary): ScoringPlayRow[] {
    return (summary.scoringPlays ?? []).map(p => ({
        text: p.text ?? "",
        type: p.type?.abbreviation ?? p.type?.text ?? null,
        period: p.period?.number ?? null,
        clock: p.clock?.displayValue ?? null,
        away: p.awayScore ?? null,
        home: p.homeScore ?? null,
        team: p.team?.abbreviation ? fixTeam(p.team.abbreviation) : null,
    }));
}
