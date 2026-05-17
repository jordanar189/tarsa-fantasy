// Mirrors Fantasy Football Calculator (FFC) ADP into public.adp.
//
// Body (all optional):
//   { "seasons": [2024, 2025], "scorings": ["ppr", "standard", "half"], "teams": 12 }
//   {}                            // default: current + previous, all three scorings, 12-team
//
// FFC's player IDs aren't nflverse IDs, so each FFC row is matched to a
// players_cache row by (normalized name, position, team). Unmatched rows are
// skipped — coverage is near-100% for actives in the current season, lower
// for historical retirees.

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

interface FFCPlayer {
    player_id: number;
    name: string;
    position: string;
    team: string;
    adp: number;
    times_drafted?: number;
    high?: number;
    low?: number;
    stdev?: number;
}
interface FFCResponse { status?: string; players?: FFCPlayer[]; }

interface CachePlayer { id: string; name: string; position: string | null; team: string | null; }

interface AdpRow {
    season: number; scoring: string; player_id: string;
    adp: number; times_drafted: number | null;
    high: number | null; low: number | null; stdev: number | null;
}

// iOS Scoring enum → FFC URL slug.
const FFC_FORMAT: Record<string, string> = {
    standard: "standard",
    ppr:      "ppr",
    half:     "half-ppr",
};

Deno.serve(async (req: Request) => {
    try {
        const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
        const seasons: number[] = pickSeasons(body);
        const scorings: string[] = body.scorings ?? ["ppr", "standard", "half"];
        const teams: number = body.teams ?? 12;

        const cache = await loadCache();
        const summary: Record<string, unknown> = {};

        for (const season of seasons) {
            for (const scoring of scorings) {
                const ffcFormat = FFC_FORMAT[scoring];
                if (!ffcFormat) { summary[`${season}/${scoring}`] = { skipped: "unknown scoring" }; continue; }
                const result = await syncOne(season, scoring, ffcFormat, teams, cache);
                summary[`${season}/${scoring}`] = result;
            }
        }
        return new Response(JSON.stringify({ ok: true, summary }), {
            headers: { "Content-Type": "application/json" }
        });
    } catch (err) {
        return new Response(JSON.stringify({ ok: false, error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});

function pickSeasons(body: Record<string, unknown>): number[] {
    if (Array.isArray(body.seasons) && body.seasons.length > 0) {
        return (body.seasons as unknown[]).map(s => Number(s)).filter(Number.isFinite) as number[];
    }
    const y = new Date().getUTCFullYear();
    return [y, y - 1];
}

async function loadCache(): Promise<Map<string, CachePlayer>> {
    // Paginate through players_cache (PostgREST default page = 1000).
    const cache: CachePlayer[] = [];
    const pageSize = 1000;
    for (let from = 0; ; from += pageSize) {
        const { data, error } = await supa.from("players_cache")
            .select("id, name, position, team")
            .range(from, from + pageSize - 1);
        if (error) throw new Error(`players_cache: ${error.message}`);
        const rows = (data ?? []) as CachePlayer[];
        cache.push(...rows);
        if (rows.length < pageSize) break;
    }
    // Build a lookup keyed by name+position+team and a fallback by name+position.
    const m = new Map<string, CachePlayer>();
    for (const p of cache) {
        if (!p.position) continue;
        const n  = normalizeName(p.name);
        const po = p.position.toUpperCase();
        const t  = (p.team ?? "").toUpperCase();
        m.set(`${n}|${po}|${t}`, p);
        // Fallback if team has shifted between cache and FFC: name+position only.
        // Prefer the more recent entry by overwriting; the fallback key is only
        // consulted when the exact triple misses.
        m.set(`${n}|${po}`, p);
    }
    return m;
}

async function syncOne(
    season: number, scoring: string, ffcFormat: string, teams: number,
    cache: Map<string, CachePlayer>
): Promise<Record<string, unknown>> {
    const url = `https://fantasyfootballcalculator.com/api/v1/adp/${ffcFormat}?teams=${teams}&year=${season}`;
    const resp = await fetch(url);
    if (!resp.ok) return { error: `HTTP ${resp.status}` };
    const data = await resp.json() as FFCResponse;
    const players = data.players ?? [];

    const rows: AdpRow[] = [];
    let matched = 0, missed = 0;
    for (const ffc of players) {
        const po = (ffc.position ?? "").toUpperCase();
        // Skip team defenses — we don't surface IDP/DEF in the UI.
        if (po === "DEF" || po === "DST") continue;

        const playerID = resolve(ffc, cache);
        if (!playerID) { missed += 1; continue; }
        matched += 1;
        rows.push({
            season, scoring, player_id: playerID,
            adp:   ffc.adp,
            times_drafted: ffc.times_drafted ?? null,
            high:  ffc.high  ?? null,
            low:   ffc.low   ?? null,
            stdev: ffc.stdev ?? null,
        });
    }

    // Upsert in chunks. With ~200 rows per season this is one round-trip in practice.
    const chunkSize = 500;
    for (let i = 0; i < rows.length; i += chunkSize) {
        const slice = rows.slice(i, i + chunkSize);
        const { error } = await supa.from("adp")
            .upsert(slice, { onConflict: "season,scoring,player_id" });
        if (error) throw new Error(`adp upsert: ${error.message}`);
    }
    return { matched, missed, returned: players.length };
}

function resolve(ffc: FFCPlayer, cache: Map<string, CachePlayer>): string | null {
    const n  = normalizeName(ffc.name);
    const po = (ffc.position ?? "").toUpperCase();
    const t  = (ffc.team ?? "").toUpperCase();
    return cache.get(`${n}|${po}|${t}`)?.id
        ?? cache.get(`${n}|${po}`)?.id
        ?? null;
}

function normalizeName(name: string): string {
    return name
        .toLowerCase()
        .replace(/\./g, "")              // "D.J." → "DJ"
        .replace(/'/g, "")               // "O'Neal" → "ONeal"
        .replace(/\s+(jr|sr|iii|ii|iv|v)\b/g, "")
        .replace(/\s+/g, " ")
        .trim();
}
