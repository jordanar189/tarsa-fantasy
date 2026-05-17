// Mirrors nflverse play-by-play data into Supabase, **one week per
// invocation**. This is the workaround for the free-tier Edge Function CPU
// cap (~2 sec/request): a full season has 45k plays and would blow it, but
// a single week is ~2.5k.
//
// The CSV is downloaded once (no per-week files exist on nflverse) and
// stream-parsed; rows for other weeks are cheaply skipped via a single-field
// pre-scan, and the stream is aborted entirely once we pass the target week.
//
// Body (optional):
//   { "season": 2025, "week": 5 }     // explicit
//   { "season": 2025, "weeks": [1,2] } // multiple weeks in one call
//   {}                                 // default: current season + current NFL week
//
// Backfill loop in bash:
//   for s in 2024 2025; do
//     for w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
//       curl -X POST .../sync_pbp -d "{\"season\":$s,\"week\":$w}"
//     done
//   done

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PBP_URL_TEMPLATE = "https://github.com/nflverse/nflverse-data/releases/download/pbp/play_by_play_{YEAR}.csv.gz";

const supa = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

// Projected columns — kept in sync with the plays table schema (slim base
// columns plus the Game Center expansion).
interface PlayRow {
    game_id: string;
    play_id: number;
    season: number;
    week: number;
    posteam: string | null;
    defteam: string | null;
    play_type: string | null;
    description: string | null;
    passer_player_id: string | null;
    receiver_player_id: string | null;
    rusher_player_id: string | null;
    td_player_id: string | null;
    yards_gained: number | null;
    touchdown: boolean | null;
    epa: number | null;
    // Game Center expansion (see 20260521000000_plays_expand.sql).
    qtr: number | null;
    down: number | null;
    ydstogo: number | null;
    yardline_100: number | null;
    posteam_score: number | null;
    defteam_score: number | null;
    game_seconds_remaining: number | null;
    drive: number | null;
    complete_pass: boolean | null;
    pass_attempt: boolean | null;
    rush_attempt: boolean | null;
    field_goal_attempt: boolean | null;
    field_goal_result: string | null;
    extra_point_attempt: boolean | null;
    extra_point_result: string | null;
    two_point_attempt: boolean | null;
    interception: boolean | null;
    fumble: boolean | null;
    fumble_lost: boolean | null;
    first_down: boolean | null;
    sack: boolean | null;
    penalty: boolean | null;
    penalty_yards: number | null;
    air_yards: number | null;
    yards_after_catch: number | null;
    pass_location: string | null;
    run_location: string | null;
    run_gap: string | null;
}

Deno.serve(async (req: Request) => {
    try {
        const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
        const { season, weeks } = pickTarget(body);
        const results: Record<string, unknown> = {};
        for (const week of weeks) {
            results[`${season}-w${week}`] = await syncWeek(season, week);
        }
        return new Response(JSON.stringify({ ok: true, results }), {
            headers: { "Content-Type": "application/json" }
        });
    } catch (err) {
        console.error(err);
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

function pickTarget(body: { season?: number; week?: number; weeks?: number[] }): { season: number; weeks: number[] } {
    const now = new Date();
    const currentSeason = now.getUTCMonth() >= 8
        ? now.getUTCFullYear()
        : now.getUTCFullYear() - 1;
    const season = body.season ?? currentSeason;
    let weeks: number[];
    if (body.weeks && body.weeks.length > 0) weeks = body.weeks;
    else if (body.week != null) weeks = [body.week];
    else weeks = [estimateCurrentWeek()];
    return { season, weeks };
}

function estimateCurrentWeek(): number {
    // NFL Week 1 historically opens the Thursday following Labor Day. As a
    // rough estimate (we don't need to be precise — the function only writes
    // matching rows and exits cheaply if no matches), pick the calendar week
    // number relative to Sept 1.
    const now = new Date();
    const year = now.getUTCMonth() >= 8 ? now.getUTCFullYear() : now.getUTCFullYear() - 1;
    const opener = new Date(Date.UTC(year, 8, 1)); // Sept 1
    const days = Math.floor((now.getTime() - opener.getTime()) / 86400000);
    const w = Math.max(1, Math.min(22, Math.floor(days / 7) + 1));
    return w;
}

async function syncWeek(season: number, week: number): Promise<unknown> {
    const url = PBP_URL_TEMPLATE.replace("{YEAR}", String(season));
    const resp = await fetch(url);
    if (resp.status === 404) return { skipped: "not_published_yet" };
    if (!resp.ok || !resp.body) return { error: `HTTP ${resp.status}` };

    const lineStream = resp.body
        .pipeThrough(new DecompressionStream("gzip"))
        .pipeThrough(new TextDecoderStream())
        .pipeThrough(makeLineStream());
    const reader = lineStream.getReader();

    let header: string[] | null = null;
    let colIdx: Map<string, number> = new Map();
    let weekColumn = -1;
    let seenWeek = false;
    let batch: PlayRow[] = [];
    let total = 0;
    let scanned = 0;

    try {
        while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            const line = value;
            if (!header) {
                header = splitCsvLine(line);
                for (let i = 0; i < header.length; i++) colIdx.set(header[i], i);
                weekColumn = colIdx.get("week") ?? -1;
                if (weekColumn < 0 || !colIdx.has("game_id") || !colIdx.has("play_id")) {
                    return { error: "header missing required columns" };
                }
                continue;
            }
            scanned++;
            // Cheap pre-filter: extract only the week field without a full split.
            const rowWeek = extractFieldByIndex(line, weekColumn);
            if (rowWeek == null) continue;
            const w = parseInt(rowWeek, 10);
            if (!Number.isFinite(w)) continue;
            if (w === week) {
                seenWeek = true;
                const fields = splitCsvLine(line);
                const row = projectRow(fields, colIdx, season);
                if (row) batch.push(row);
                if (batch.length >= 500) {
                    await upsert(batch);
                    total += batch.length;
                    batch = [];
                }
            } else if (seenWeek && w > week) {
                // CSV is sorted by game_id which groups weeks together; once
                // we've seen our target week and moved past it, we're done.
                await reader.cancel();
                break;
            }
        }
        if (batch.length > 0) {
            await upsert(batch);
            total += batch.length;
        }
        return { plays: total, scanned };
    } catch (err) {
        await reader.cancel().catch(() => {});
        throw err;
    }
}

async function upsert(rows: PlayRow[]) {
    const { error } = await supa.from("plays").upsert(rows, { onConflict: "game_id,play_id" });
    if (error) throw new Error(`plays upsert: ${error.message}`);
}

function projectRow(fields: string[], colIdx: Map<string, number>, fallbackSeason: number): PlayRow | null {
    const get = (col: string): string | undefined => {
        const i = colIdx.get(col);
        if (i === undefined || i >= fields.length) return undefined;
        return fields[i];
    };
    const gameID = get("game_id");
    const playIDRaw = get("play_id");
    if (!gameID || !playIDRaw) return null;
    const playID = Math.trunc(num(playIDRaw));
    if (!Number.isFinite(playID)) return null;
    const week = Math.trunc(num(get("week")));
    if (!Number.isFinite(week)) return null;
    return {
        game_id: gameID,
        play_id: playID,
        season: Math.trunc(num(get("season")) || fallbackSeason),
        week,
        posteam: text(get("posteam")),
        defteam: text(get("defteam")),
        play_type: text(get("play_type")),
        description: text(get("desc")),
        passer_player_id:   text(get("passer_player_id")),
        receiver_player_id: text(get("receiver_player_id")),
        rusher_player_id:   text(get("rusher_player_id")),
        td_player_id:       text(get("td_player_id")),
        yards_gained:       numOrNull(get("yards_gained")),
        touchdown:          boolOrNull(get("touchdown")),
        epa:                numOrNull(get("epa")),
        qtr:                intOrNull(get("qtr")),
        down:               intOrNull(get("down")),
        ydstogo:            intOrNull(get("ydstogo")),
        yardline_100:       intOrNull(get("yardline_100")),
        posteam_score:      intOrNull(get("posteam_score")),
        defteam_score:      intOrNull(get("defteam_score")),
        game_seconds_remaining: intOrNull(get("game_seconds_remaining")),
        drive:              intOrNull(get("drive")),
        complete_pass:      boolOrNull(get("complete_pass")),
        pass_attempt:       boolOrNull(get("pass_attempt")),
        rush_attempt:       boolOrNull(get("rush_attempt")),
        field_goal_attempt: boolOrNull(get("field_goal_attempt")),
        field_goal_result:  text(get("field_goal_result")),
        extra_point_attempt:boolOrNull(get("extra_point_attempt")),
        extra_point_result: text(get("extra_point_result")),
        two_point_attempt:  boolOrNull(get("two_point_attempt")),
        interception:       boolOrNull(get("interception")),
        fumble:             boolOrNull(get("fumble")),
        fumble_lost:        boolOrNull(get("fumble_lost")),
        first_down:         boolOrNull(get("first_down")),
        sack:               boolOrNull(get("sack")),
        penalty:            boolOrNull(get("penalty")),
        penalty_yards:      intOrNull(get("penalty_yards")),
        air_yards:          numOrNull(get("air_yards")),
        yards_after_catch:  numOrNull(get("yards_after_catch")),
        pass_location:      text(get("pass_location")),
        run_location:       text(get("run_location")),
        run_gap:            text(get("run_gap"))
    };
}

function intOrNull(v: string | undefined): number | null {
    const n = numOrNull(v);
    if (n == null) return null;
    return Math.trunc(n);
}

// Reads just the Nth comma-separated field from a CSV line without parsing
// the whole thing. Skips quoted regions. Returns null if there are fewer
// fields than `index` requires. ~10× faster than splitCsvLine when we only
// need one column for filtering.
function extractFieldByIndex(line: string, index: number): string | null {
    let field = 0;
    let start = 0;
    let inQ = false;
    let i = 0;
    while (i < line.length) {
        const c = line.charCodeAt(i);
        if (inQ) {
            if (c === 34) { // "
                if (line.charCodeAt(i + 1) === 34) { i += 2; continue; }
                inQ = false; i++; continue;
            }
            i++;
        } else {
            if (c === 34) { inQ = true; i++; }
            else if (c === 44) { // ,
                if (field === index) return line.slice(start, i);
                field++;
                start = i + 1;
                i++;
            } else {
                i++;
            }
        }
    }
    if (field === index) return line.slice(start);
    return null;
}

// ----------- Shared helpers -----------

function num(v: string | undefined): number {
    if (!v) return 0;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA" || s.toUpperCase() === "NULL") return 0;
    const n = Number(s);
    return Number.isFinite(n) ? n : 0;
}
function numOrNull(v: string | undefined): number | null {
    if (!v) return null;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA" || s.toUpperCase() === "NULL") return null;
    const n = Number(s);
    return Number.isFinite(n) ? n : null;
}
function text(v: string | undefined): string | null {
    if (!v) return null;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA" || s.toUpperCase() === "NULL") return null;
    return s;
}
function boolOrNull(v: string | undefined): boolean | null {
    const s = (v ?? "").trim().toUpperCase();
    if (s === "" || s === "NA" || s === "NULL") return null;
    if (s === "TRUE" || s === "1") return true;
    if (s === "FALSE" || s === "0") return false;
    const n = Number(s);
    if (Number.isFinite(n)) return n !== 0;
    return null;
}

function makeLineStream(): TransformStream<string, string> {
    let buf = "";
    return new TransformStream<string, string>({
        transform(chunk, controller) {
            buf += chunk;
            let start = 0;
            for (let i = 0; i < buf.length; i++) {
                if (buf.charCodeAt(i) !== 10) continue;
                const candidate = buf.slice(start, i).replace(/\r$/, "");
                if (quotesBalanced(candidate)) {
                    controller.enqueue(candidate);
                    start = i + 1;
                }
            }
            buf = buf.slice(start);
        },
        flush(controller) {
            const tail = buf.replace(/\r$/, "");
            if (tail.length > 0 && quotesBalanced(tail)) controller.enqueue(tail);
        }
    });
}

function quotesBalanced(s: string): boolean {
    let count = 0;
    for (let i = 0; i < s.length; i++) {
        if (s.charCodeAt(i) !== 34) continue;
        if (s.charCodeAt(i + 1) === 34) { i++; continue; }
        count++;
    }
    return count % 2 === 0;
}

function splitCsvLine(line: string): string[] {
    const out: string[] = [];
    let cur = "";
    let inQ = false;
    for (let i = 0; i < line.length; i++) {
        const c = line[i];
        if (inQ) {
            if (c === "\"") {
                if (line[i + 1] === "\"") { cur += "\""; i++; }
                else { inQ = false; }
            } else cur += c;
        } else {
            if (c === "\"") inQ = true;
            else if (c === ",") { out.push(cur); cur = ""; }
            else cur += c;
        }
    }
    out.push(cur);
    return out;
}
