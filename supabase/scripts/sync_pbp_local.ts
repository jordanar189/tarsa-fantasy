#!/usr/bin/env -S deno run --allow-net --allow-env
//
// Local PBP backfill. Use this instead of `supabase functions invoke sync_pbp`
// when you need to ingest a full season — the Edge Function CPU cap chokes
// on the 150 MB CSV parse, but your laptop doesn't care.
//
// Usage:
//   export SUPABASE_URL=https://uxpfktjpmyhdlwfxnwri.supabase.co
//   export SUPABASE_SERVICE_ROLE_KEY=eyJ...   # from Dashboard → Project Settings → API
//   deno run --allow-net --allow-env supabase/scripts/sync_pbp_local.ts 2024 2025
//
// Args: one or more season years (e.g. 2020 2021 2022). Each season ~30-60s.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!SUPABASE_URL || !SERVICE_KEY) {
    console.error("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY env vars first.");
    Deno.exit(1);
}

const seasons = Deno.args.map(Number).filter(n => Number.isFinite(n));
if (seasons.length === 0) {
    console.error("Pass at least one season year as an argument, e.g.:");
    console.error("  deno run --allow-net --allow-env supabase/scripts/sync_pbp_local.ts 2024 2025");
    Deno.exit(1);
}

const supa = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

const PBP_URL = (year: number) =>
    `https://github.com/nflverse/nflverse-data/releases/download/pbp/play_by_play_${year}.csv.gz`;

interface PlayRow {
    game_id: string; play_id: number; season: number; week: number;
    posteam: string | null; defteam: string | null;
    play_type: string | null; description: string | null;
    passer_player_id: string | null; receiver_player_id: string | null;
    rusher_player_id: string | null; td_player_id: string | null;
    yards_gained: number | null; touchdown: boolean | null; epa: number | null;
    // Game Center expansion (see 20260521000000_plays_expand.sql).
    qtr: number | null; down: number | null; ydstogo: number | null;
    yardline_100: number | null;
    posteam_score: number | null; defteam_score: number | null;
    game_seconds_remaining: number | null;
    drive: number | null;
    complete_pass: boolean | null;
    pass_attempt: boolean | null; rush_attempt: boolean | null;
    field_goal_attempt: boolean | null; field_goal_result: string | null;
    extra_point_attempt: boolean | null; extra_point_result: string | null;
    two_point_attempt: boolean | null;
    interception: boolean | null;
    fumble: boolean | null; fumble_lost: boolean | null;
    first_down: boolean | null; sack: boolean | null;
    penalty: boolean | null; penalty_yards: number | null;
    air_yards: number | null; yards_after_catch: number | null;
    pass_location: string | null; run_location: string | null; run_gap: string | null;
}

for (const year of seasons) {
    const t0 = performance.now();
    console.log(`→ ${year} fetching…`);
    const resp = await fetch(PBP_URL(year));
    if (!resp.ok || !resp.body) {
        console.warn(`  ${year}: HTTP ${resp.status} (skipping)`);
        continue;
    }

    // Memory's not constrained on a laptop — buffer the whole thing, then
    // native String.split('\n'). Much faster than per-byte JS loops.
    const compressed = new Uint8Array(await resp.arrayBuffer());
    const decompressed = await new Response(
        new Response(compressed).body!.pipeThrough(new DecompressionStream("gzip"))
    ).text();
    const lines = decompressed.split("\n");
    const header = splitCsvLine(lines[0]);
    const colIdx = new Map(header.map((c, i) => [c, i]));
    if (!colIdx.has("game_id") || !colIdx.has("play_id") || !colIdx.has("week")) {
        console.error(`  ${year}: CSV missing required columns`);
        continue;
    }

    let batch: PlayRow[] = [];
    let total = 0;
    for (let i = 1; i < lines.length; i++) {
        const line = lines[i].replace(/\r$/, "");
        if (line.length === 0) continue;
        const fields = splitCsvLine(line);
        const row = projectRow(fields, colIdx, year);
        if (!row) continue;
        batch.push(row);
        if (batch.length >= 1000) {
            const { error } = await supa.from("plays").upsert(batch, { onConflict: "game_id,play_id" });
            if (error) { console.error(`  upsert error: ${error.message}`); Deno.exit(2); }
            total += batch.length;
            Deno.stdout.writeSync(new TextEncoder().encode(`\r  ${year}: ${total} plays upserted…`));
            batch = [];
        }
    }
    if (batch.length > 0) {
        const { error } = await supa.from("plays").upsert(batch, { onConflict: "game_id,play_id" });
        if (error) { console.error(`\n  upsert error: ${error.message}`); Deno.exit(2); }
        total += batch.length;
    }
    const secs = ((performance.now() - t0) / 1000).toFixed(1);
    console.log(`\r  ${year}: ${total} plays upserted in ${secs}s${" ".repeat(20)}`);
}

console.log("Done.");

// ----------- Helpers (same logic as the Edge Function) -----------

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
        game_id: gameID, play_id: playID,
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

function num(v: string | undefined): number {
    if (!v) return 0;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA" || s.toUpperCase() === "NULL") return 0;
    const n = Number(s); return Number.isFinite(n) ? n : 0;
}
function numOrNull(v: string | undefined): number | null {
    if (!v) return null;
    const s = v.trim();
    if (s === "" || s.toUpperCase() === "NA" || s.toUpperCase() === "NULL") return null;
    const n = Number(s); return Number.isFinite(n) ? n : null;
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
