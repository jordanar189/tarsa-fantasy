// Mirrors ESPN's NFL news feed into player_news (hourly cron). Articles are
// tagged with local player ids resolved from ESPN athlete ids so the app can
// show a per-player card and a league-wide feed. Upserts on the ESPN article
// id, so re-runs and edited articles are idempotent. Parsing lives in
// parse.ts (pure, deno-testable).

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { parseArticles, EspnArticle } from "./parse.ts";

const SUPABASE_URL     = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const NEWS_URL = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/news?limit=50";

const supa: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false }
});

Deno.serve(async (_req: Request) => {
    try {
        const resp = await fetch(NEWS_URL, { headers: { "User-Agent": "fantasy-football-ios" } });
        if (!resp.ok) {
            return new Response(JSON.stringify({ error: `HTTP ${resp.status}` }), {
                status: 500, headers: { "Content-Type": "application/json" }
            });
        }
        const json = await resp.json().catch(() => null) as { articles?: EspnArticle[] } | null;
        const articles = json?.articles ?? [];

        // espn_id → local id map (paginated; players_cache holds every player).
        const espnToLocal = new Map<string, string>();
        for (let from = 0; ; from += 1000) {
            const { data: page } = await supa.from("players_cache")
                .select("id, espn_id")
                .not("espn_id", "is", null)
                .order("id")
                .range(from, from + 999);
            if (!page || page.length === 0) break;
            for (const r of page as Array<{ id: string; espn_id: string | null }>) {
                if (r.espn_id) espnToLocal.set(r.espn_id, r.id);
            }
            if (page.length < 1000) break;
        }

        const rows = parseArticles(articles, espnToLocal);
        if (rows.length > 0) {
            const { error } = await supa.from("player_news")
                .upsert(rows, { onConflict: "id" });
            if (error) throw new Error(`news upsert: ${error.message}`);
        }

        // Keep the table lean: the feed only ever shows recent items.
        await supa.from("player_news")
            .delete()
            .lt("published", new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString());

        return new Response(JSON.stringify({
            ok: true, received: articles.length, written: rows.length,
            tagged: rows.filter(r => r.player_ids.length > 0).length,
        }), { headers: { "Content-Type": "application/json" } });
    } catch (err) {
        return new Response(JSON.stringify({ error: String(err) }), {
            status: 500, headers: { "Content-Type": "application/json" }
        });
    }
});
