// deno test supabase/functions/process_waivers/logic_test.ts
import { faabClaimOrder, rotateWinners } from "./logic.ts";

function claim(id: string, team: string, bid: number | null, at = "2026-09-16T00:00:00Z") {
    return { id, team_id: team, bid, created_at: at };
}

Deno.test("faabClaimOrder: highest bid first", () => {
    const idx = new Map([["A", 0], ["B", 1]]);
    const ordered = faabClaimOrder([claim("1", "A", 5), claim("2", "B", 40)], idx);
    if (ordered[0].id !== "2") throw new Error("highest bid should win");
});

Deno.test("faabClaimOrder: tie goes to better waiver position", () => {
    const idx = new Map([["A", 2], ["B", 0]]);
    const ordered = faabClaimOrder([claim("1", "A", 10), claim("2", "B", 10)], idx);
    if (ordered[0].team_id !== "B") throw new Error("tie should go to earlier waiver position");
});

Deno.test("faabClaimOrder: same team+bid falls back to submission time", () => {
    const idx = new Map([["A", 0]]);
    const ordered = faabClaimOrder([
        claim("late", "A", 10, "2026-09-16T12:00:00Z"),
        claim("early", "A", 10, "2026-09-16T01:00:00Z"),
    ], idx);
    if (ordered[0].id !== "early") throw new Error("earlier submission should come first");
});

Deno.test("faabClaimOrder: null bids sort as $0", () => {
    const idx = new Map([["A", 0], ["B", 1]]);
    const ordered = faabClaimOrder([claim("1", "A", null), claim("2", "B", 1)], idx);
    if (ordered[0].id !== "2") throw new Error("$1 should beat a null ($0) bid");
});

Deno.test("rotateWinners: winners move to the back, others keep order", () => {
    const next = rotateWinners(["A", "B", "C", "D"], ["B", "D"]);
    if (next.join(",") !== "A,C,B,D") throw new Error(`unexpected order ${next}`);
});

Deno.test("rotateWinners: no winners leaves order unchanged", () => {
    const order = ["A", "B"];
    if (rotateWinners(order, []) !== order) throw new Error("should return same array");
});
