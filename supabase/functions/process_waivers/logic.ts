// Pure waiver-resolution ordering, split from index.ts so it can be
// unit-tested without pulling in the edge-function server or supabase-js.

export interface OrderableClaim {
    id: string;
    team_id: string;
    created_at: string;
    bid: number | null;
}

// FAAB resolution order: bid desc, then the claiming team's waiver position
// (earlier = better), then submission time, then id for a total order.
export function faabClaimOrder<C extends OrderableClaim>(
    claims: C[], priorityIndex: Map<string, number>
): C[] {
    return [...claims].sort((a, b) => {
        const bidDiff = (b.bid ?? 0) - (a.bid ?? 0);
        if (bidDiff !== 0) return bidDiff;
        const pa = priorityIndex.get(a.team_id) ?? Number.MAX_SAFE_INTEGER;
        const pb = priorityIndex.get(b.team_id) ?? Number.MAX_SAFE_INTEGER;
        if (pa !== pb) return pa - pb;
        const t = a.created_at.localeCompare(b.created_at);
        if (t !== 0) return t;
        return a.id.localeCompare(b.id);
    });
}

// One round-rotation step for priority mode: this round's winners move to
// the back of the working order, everyone else keeps their relative slot.
export function rotateWinners(order: string[], winners: string[]): string[] {
    if (winners.length === 0) return order;
    return [...order.filter(t => !winners.includes(t)), ...winners];
}
