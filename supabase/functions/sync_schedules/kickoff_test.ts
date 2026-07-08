// deno test supabase/functions/sync_schedules/kickoff_test.ts

import { combineKickoff, easternOffset, mergeExisting, ScheduleRow } from "./kickoff.ts";

function assertEquals<T>(actual: T, expected: T, msg?: string) {
    const a = JSON.stringify(actual), e = JSON.stringify(expected);
    if (a !== e) throw new Error(msg ?? `expected ${e}, got ${a}`);
}

// 2026: DST runs Mar 8 (second Sunday) through Nov 1 (first Sunday).
Deno.test("easternOffset picks EDT during US daylight saving", () => {
    assertEquals(easternOffset("2026-09-13"), "-04:00");   // September Sunday slate
    assertEquals(easternOffset("2026-10-31"), "-04:00");   // day before DST ends
    assertEquals(easternOffset("2026-11-01"), "-05:00");   // first Sunday of November
    assertEquals(easternOffset("2026-12-20"), "-05:00");   // late-season EST
    assertEquals(easternOffset("2026-03-07"), "-05:00");   // day before DST starts
    assertEquals(easternOffset("2026-03-08"), "-04:00");   // second Sunday of March
    assertEquals(easternOffset("2027-01-10"), "-05:00");   // playoffs
});

Deno.test("combineKickoff builds ET timestamps and handles NA", () => {
    assertEquals(combineKickoff("2026-09-13", "13:00"), "2026-09-13T13:00:00-04:00");
    assertEquals(combineKickoff("2026-12-20", "20:20"), "2026-12-20T20:20:00-05:00");
    assertEquals(combineKickoff("2026-09-13", "9:30"), "2026-09-13T09:30:00-04:00");
    assertEquals(combineKickoff("2026-09-13", ""), "2026-09-13T13:00:00-04:00");
    assertEquals(combineKickoff("NA", "13:00"), null);
    assertEquals(combineKickoff(undefined, "13:00"), null);
});

function row(overrides: Partial<ScheduleRow>): ScheduleRow {
    return {
        game_id: "2026_01_KC_BUF", season: 2026, week: 1,
        home_team: "BUF", away_team: "KC",
        kickoff: "2026-09-13T13:00:00-04:00",
        home_score: null, away_score: null, status: "scheduled",
        ...overrides,
    };
}

Deno.test("mergeExisting keeps a same-slot kickoff from a better source", () => {
    // ESPN wrote the exact UTC instant (17:00Z == 13:00 EDT); nflverse's
    // reconstruction is the same slot, so the existing value is kept.
    const r = row({});
    mergeExisting(r, {
        game_id: r.game_id, kickoff: "2026-09-13T17:00Z",
        status: "scheduled", home_score: null, away_score: null,
    });
    assertEquals(r.kickoff, "2026-09-13T17:00Z");
});

Deno.test("mergeExisting takes the new kickoff on a real reschedule", () => {
    // Game flexed from 1pm to Sunday night — gap > 2h, nflverse wins.
    const r = row({ kickoff: "2026-09-13T20:20:00-04:00" });
    mergeExisting(r, {
        game_id: r.game_id, kickoff: "2026-09-13T17:00Z",
        status: "scheduled", home_score: null, away_score: null,
    });
    assertEquals(r.kickoff, "2026-09-13T20:20:00-04:00");
});

Deno.test("mergeExisting backfills kickoff when the CSV has none", () => {
    const r = row({ kickoff: null });
    mergeExisting(r, {
        game_id: r.game_id, kickoff: "2026-09-13T17:00Z",
        status: "scheduled", home_score: null, away_score: null,
    });
    assertEquals(r.kickoff, "2026-09-13T17:00Z");
});

Deno.test("mergeExisting preserves an overnight final the CSV hasn't ingested", () => {
    // sync_espn_live marked the game final with scores last night; the CSV
    // still has no result. Without the merge this row would regress to
    // in_progress with nulled scores.
    const r = row({ status: "in_progress" });
    mergeExisting(r, {
        game_id: r.game_id, kickoff: r.kickoff,
        status: "final", home_score: 27, away_score: 24,
    });
    assertEquals(r.status, "final");
    assertEquals(r.home_score, 27);
    assertEquals(r.away_score, 24);
});

Deno.test("mergeExisting lets an authoritative CSV result win", () => {
    const r = row({ status: "final", home_score: 30, away_score: 17 });
    mergeExisting(r, {
        game_id: r.game_id, kickoff: r.kickoff,
        status: "in_progress", home_score: 13, away_score: 10,
    });
    assertEquals(r.status, "final");
    assertEquals(r.home_score, 30);
    assertEquals(r.away_score, 17);
});

Deno.test("mergeExisting is a no-op for brand-new games", () => {
    const r = row({});
    mergeExisting(r, undefined);
    assertEquals(r.kickoff, "2026-09-13T13:00:00-04:00");
    assertEquals(r.status, "scheduled");
});
