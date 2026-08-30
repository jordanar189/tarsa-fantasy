import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
    STAT_COLUMNS, compactScoringPlays, extractBoxScore, fantasyPoints,
    gameRowFromEvent, gameStatus, preseasonWeekLabel,
} from "./parse.ts";
import type { EspnBoxSummary, EspnEvent, EspnScoreboard } from "./parse.ts";

const summary: EspnBoxSummary = {
    boxscore: {
        players: [
            {
                team: { abbreviation: "WSH" },
                statistics: [
                    { name: "passing", labels: ["C/ATT", "YDS", "AVG", "TD", "INT", "SACKS", "QBR", "RTG"],
                      athletes: [{ athlete: { id: 1, displayName: "Backup QB", jersey: "8" }, stats: ["12/20", "150", "7.5", "1", "1", "2-13", "55", "80"] }] },
                    { name: "rushing", labels: ["CAR", "YDS", "AVG", "TD", "LONG"],
                      athletes: [
                        { athlete: { id: 1, displayName: "Backup QB", jersey: "8" }, stats: ["2", "9", "4.5", "0", "7"] },
                        { athlete: { id: 2, displayName: "UDFA Back", jersey: "35" }, stats: ["10", "61", "6.1", "1", "24"] },
                      ] },
                    { name: "receiving", labels: ["REC", "YDS", "AVG", "TD", "LONG", "TGTS"],
                      athletes: [{ athlete: { id: 2, displayName: "UDFA Back", jersey: "35" }, stats: ["3", "22", "7.3", "0", "11", "4"] }] },
                    { name: "fumbles", labels: ["FUM", "LOST", "REC"],
                      athletes: [{ athlete: { id: 2, displayName: "UDFA Back", jersey: "35" }, stats: ["1", "1", "0"] }] },
                    { name: "kickReturns", labels: ["NO", "YDS", "AVG", "LONG", "TD"],
                      athletes: [{ athlete: { id: 2, displayName: "UDFA Back", jersey: "35" }, stats: ["2", "48", "24.0", "31", "0"] }] },
                    { name: "kicking", labels: ["FG", "PCT", "LONG", "XP", "PTS"],
                      athletes: [{ athlete: { id: 5, displayName: "Camp Leg", jersey: "3" }, stats: ["2/3", "66.7", "48", "1/1", "7"] }] },
                ],
            },
            {
                team: { abbreviation: "BAL" },
                statistics: [
                    { name: "defensive", labels: ["TOT", "SOLO", "SACKS", "TFL", "PD", "QB HTS", "TD"],
                      athletes: [{ athlete: { id: 9, displayName: "Rookie LB", jersey: "52" }, stats: ["7", "4", "1.0", "2", "1", "2", "0"] }] },
                    { name: "interceptions", labels: ["INT", "YDS", "TD"],
                      athletes: [{ athlete: { id: 9, displayName: "Rookie LB", jersey: "52" }, stats: ["1", "30", "1"] }] },
                    { name: "punting", labels: ["NO", "YDS", "AVG", "TB", "In 20", "LONG"],
                      athletes: [{ athlete: { id: 11, displayName: "Punter", jersey: "6" }, stats: ["3", "140", "46.7", "0", "2", "55"] }] },
                ],
            },
        ],
    },
    scoringPlays: [{
        id: "1", text: "UDFA Back 24 Yd Run (Camp Leg Kick)", type: { text: "Rushing Touchdown", abbreviation: "TD" },
        period: { number: 2 }, clock: { displayValue: "3:12" }, awayScore: 7, homeScore: 0, team: { abbreviation: "WSH" },
    }],
};

Deno.test("extractBoxScore keeps every athlete and merges categories", () => {
    const lines = extractBoxScore(summary);
    const byID = new Map(lines.map(l => [l.espnAthleteID, l]));
    assertEquals(lines.length, 5);

    const qb = byID.get("1")!;
    assertEquals(qb.team, "WAS");                // WSH → nflverse WAS
    assertEquals(qb.opponent, "BAL");
    assertEquals([qb.stats.completions, qb.stats.attempts, qb.stats.passing_yards, qb.stats.passing_tds,
                  qb.stats.passing_interceptions, qb.stats.sacks_taken], [12, 20, 150, 1, 1, 2]);
    assertEquals(qb.stats.carries, 2);

    const rb = byID.get("2")!;
    assertEquals(rb.jersey, "35");
    assertEquals([rb.stats.carries, rb.stats.rushing_yards, rb.stats.rushing_tds, rb.stats.rushing_long], [10, 61, 1, 24]);
    assertEquals([rb.stats.receptions, rb.stats.targets, rb.stats.receiving_yards], [3, 4, 22]);
    assertEquals([rb.stats.fumbles, rb.stats.fumbles_lost], [1, 1]);
    assertEquals([rb.stats.kick_returns, rb.stats.kick_return_yards], [2, 48]);

    const lb = byID.get("9")!;
    assertEquals([lb.stats.def_tackles_solo, lb.stats.def_tackle_assists, lb.stats.def_sacks, lb.stats.def_tackles_for_loss,
                  lb.stats.def_pass_defended, lb.stats.def_qb_hits], [4, 3, 1, 2, 1, 2]);
    assertEquals([lb.stats.def_interceptions, lb.stats.def_tds], [1, 1]);   // pick-six counted once

    const k = byID.get("5")!;
    assertEquals([k.stats.fg_made, k.stats.fg_att, k.stats.fg_long, k.stats.pat_made, k.stats.pat_att], [2, 3, 48, 1, 1]);

    // Punter only appears in an ignored category → present with all-zero stats.
    const p = byID.get("11")!;
    for (const c of STAT_COLUMNS) assertEquals(p.stats[c], 0, c);
});

Deno.test("every line carries every stat column (bulk-upsert shape) and points", () => {
    for (const line of extractBoxScore(summary)) {
        for (const c of STAT_COLUMNS) assertEquals(typeof line.stats[c], "number", `${line.name} ${c}`);
        assertEquals(typeof line.stats.fantasy_points_ppr, "number");
    }
    const rb = extractBoxScore(summary).find(l => l.espnAthleteID === "2")!;
    // 61*0.1 + 6 + 22*0.1 - 2 = 12.3 std; +3 rec ppr
    assertEquals(rb.stats.fantasy_points, 12.3);
    assertEquals(rb.stats.fantasy_points_ppr, 15.3);
    assertEquals(rb.stats.fantasy_points_half_ppr, 13.8);
});

Deno.test("fantasyPoints matches the sync_espn_live preset", () => {
    assertEquals(fantasyPoints({ passing_yards: 300, passing_tds: 2, passing_interceptions: 1, receptions: 0 }),
                 { std: 18, ppr: 18, half: 18 });
});

const event: EspnEvent = {
    id: "401873308",
    date: "2026-08-29T17:00Z",
    season: { year: 2026, type: 1 },
    week: { number: 4 },
    status: { period: 3, displayClock: "4:12", type: { name: "STATUS_IN_PROGRESS", state: "in", completed: false, shortDetail: "3rd 4:12" } },
    competitions: [{
        venue: { fullName: "Lucas Oil Stadium" },
        competitors: [
            { homeAway: "home", score: "17", team: { abbreviation: "IND" }, linescores: [{ value: 7, period: 1 }, { value: 10, period: 2 }, { value: 0, period: 3 }] },
            { homeAway: "away", score: "3",  team: { abbreviation: "DET" }, linescores: [{ value: 3, period: 1 }, { value: 0, period: 2 }] },
        ],
    }],
};

Deno.test("gameRowFromEvent maps a live event", () => {
    const row = gameRowFromEvent(event, "Preseason Week 3", new Date("2026-08-29T18:00:00Z"))!;
    assertEquals(row.game_id, "401873308");
    assertEquals([row.season, row.pre_week, row.week_label], [2026, 4, "Preseason Week 3"]);
    assertEquals([row.home_team, row.away_team], ["IND", "DET"]);
    assertEquals([row.home_score, row.away_score], [17, 3]);
    assertEquals(row.home_linescores, [7, 10, 0]);
    assertEquals(row.away_linescores, [3, 0]);
    assertEquals([row.status, row.period, row.clock, row.status_detail], ["in_progress", 3, "4:12", "3rd 4:12"]);
    assertEquals(row.venue, "Lucas Oil Stadium");
    assertEquals(row.kickoff, "2026-08-29T17:00Z");
});

Deno.test("gameStatus: scheduled games carry no score/clock; finals and postponements map", () => {
    const pre: EspnEvent = { ...event, status: { type: { name: "STATUS_SCHEDULED", state: "pre", completed: false, shortDetail: "8/29 - 1:00 PM EDT" } } };
    const row = gameRowFromEvent(pre, "x")!;
    assertEquals([row.status, row.home_score, row.period, row.clock], ["scheduled", null, null, null]);
    assertEquals(gameStatus({ ...event, status: { type: { name: "STATUS_FINAL", state: "post", completed: true } } }), "final");
    assertEquals(gameStatus({ ...event, status: { type: { name: "STATUS_POSTPONED", state: "post", completed: false } } }), "postponed");
    assertEquals(gameRowFromEvent({ ...event, competitions: [] }, "x"), null);
});

Deno.test("preseasonWeekLabel prefers ESPN's calendar, falls back to convention", () => {
    const sb: EspnScoreboard = { leagues: [{ calendar: [
        { label: "Preseason", value: "1", entries: [{ label: "Hall of Fame Weekend", value: "1" }, { label: "Preseason Week 1", value: "2" }] },
        { label: "Regular Season", value: "2", entries: [{ label: "Week 1", value: "1" }] },
    ] }] };
    assertEquals(preseasonWeekLabel(sb, 2), "Preseason Week 1");
    assertEquals(preseasonWeekLabel({}, 1), "Hall of Fame Weekend");
    assertEquals(preseasonWeekLabel({}, 4), "Preseason Week 3");
});

Deno.test("compactScoringPlays keeps only what the app renders", () => {
    assertEquals(compactScoringPlays(summary), [{
        text: "UDFA Back 24 Yd Run (Camp Leg Kick)", type: "TD", period: 2, clock: "3:12", away: 7, home: 0, team: "WAS",
    }]);
});
