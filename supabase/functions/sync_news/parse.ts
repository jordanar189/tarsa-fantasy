// Pure parsing for sync_news: ESPN news API articles → player_news rows.
// Deno-testable, no I/O. The athlete → local-id mapping is injected so the
// parser stays pure.

export interface EspnArticle {
    id?: number | string;
    dataSourceIdentifier?: string;
    headline?: string;
    description?: string;
    published?: string;
    links?: { web?: { href?: string } };
    images?: Array<{ url?: string }>;
    categories?: Array<{
        type?: string;
        athleteId?: number | string;
        athlete?: { id?: number | string };
    }>;
}

export interface NewsRow {
    id: string;
    headline: string;
    description: string | null;
    published: string;
    url: string | null;
    image_url: string | null;
    player_ids: string[];
    source: string;
}

// espnIdToLocal: players_cache.espn_id → players_cache.id (gsis).
export function parseArticles(
    articles: EspnArticle[],
    espnIdToLocal: Map<string, string>,
): NewsRow[] {
    const out: NewsRow[] = [];
    for (const a of articles) {
        const id = String(a.id ?? a.dataSourceIdentifier ?? "").trim();
        const headline = (a.headline ?? "").trim();
        const published = (a.published ?? "").trim();
        if (!id || !headline || !published) continue;

        const players = new Set<string>();
        for (const c of a.categories ?? []) {
            if ((c.type ?? "") !== "athlete") continue;
            const espnId = String(c.athleteId ?? c.athlete?.id ?? "").trim();
            const local = espnId ? espnIdToLocal.get(espnId) : undefined;
            if (local) players.add(local);
        }

        out.push({
            id,
            headline,
            description: (a.description ?? "").trim() || null,
            published,
            url: a.links?.web?.href ?? null,
            image_url: a.images?.[0]?.url ?? null,
            player_ids: [...players],
            source: "espn",
        });
    }
    return out;
}
