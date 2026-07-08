// deno test supabase/functions/sync_news/parse_test.ts

import { parseArticles, EspnArticle } from "./parse.ts";

function assertEquals<T>(actual: T, expected: T, msg?: string) {
    const a = JSON.stringify(actual), e = JSON.stringify(expected);
    if (a !== e) throw new Error(msg ?? `expected ${e}, got ${a}`);
}

const espnMap = new Map([
    ["3139477", "00-0033873"],   // Patrick Mahomes
    ["4241389", "00-0036355"],   // CeeDee Lamb
]);

const FIXTURE: EspnArticle[] = [
    {
        id: 40001,
        headline: "Mahomes throws four TDs in rout",
        description: "KC quarterback carves up the secondary.",
        published: "2026-09-13T21:05:00Z",
        links: { web: { href: "https://www.espn.com/nfl/story/_/id/40001" } },
        images: [{ url: "https://a.espncdn.com/photo/40001.jpg" }],
        categories: [
            { type: "athlete", athleteId: 3139477 },
            { type: "team", athleteId: undefined },
            { type: "athlete", athlete: { id: "4241389" } },
            { type: "athlete", athleteId: 999999 },   // not in players_cache
        ],
    },
    {
        // no id and no dataSourceIdentifier → dropped
        headline: "Orphan article",
        published: "2026-09-13T20:00:00Z",
    },
    {
        dataSourceIdentifier: "40002",
        headline: "League roundup",
        published: "2026-09-13T19:00:00Z",
        categories: [{ type: "team" }],
    },
];

Deno.test("parseArticles maps athletes, tolerates gaps, drops id-less rows", () => {
    const rows = parseArticles(FIXTURE, espnMap);
    assertEquals(rows.length, 2);

    const first = rows[0];
    assertEquals(first.id, "40001");
    assertEquals(first.headline, "Mahomes throws four TDs in rout");
    assertEquals(first.url, "https://www.espn.com/nfl/story/_/id/40001");
    assertEquals(first.image_url, "https://a.espncdn.com/photo/40001.jpg");
    // Both known athletes tagged (numeric and nested string forms); the
    // unknown ESPN id is skipped rather than polluting the array.
    assertEquals([...first.player_ids].sort(), ["00-0033873", "00-0036355"]);

    const second = rows[1];
    assertEquals(second.id, "40002");
    assertEquals(second.player_ids, []);
    assertEquals(second.description, null);
    assertEquals(second.url, null);
});

Deno.test("parseArticles requires headline and published", () => {
    const rows = parseArticles(
        [{ id: 1, published: "2026-01-01T00:00:00Z" },
         { id: 2, headline: "No date" }],
        espnMap,
    );
    assertEquals(rows.length, 0);
});
