// deno test supabase/functions/sync_espn_live/parse_test.ts
import {
    makeRow, extractPlayerStats, applyFieldGoalDistances, synthesizeDST, fixTeam,
} from "./parse.ts";
import type { EspnSummary } from "./parse.ts";

function expect(cond: boolean, msg: string) {
    if (!cond) throw new Error(msg);
}

const SUMMARY: EspnSummary = {
    boxscore: {
        players: [{
            statistics: [
                {
                    name: "passing",
                    labels: ["C/ATT", "YDS", "AVG", "TD", "INT", "SACKS", "QBR", "RTG"],
                    athletes: [{ athlete: { id: 101, displayName: "Pat QB" },
                                 stats: ["22/30", "285", "9.5", "2", "1", "2-14", "88", "112"] }],
                },
                {
                    name: "rushing",
                    labels: ["CAR", "YDS", "AVG", "TD", "LONG"],
                    athletes: [{ athlete: { id: 102, displayName: "Runner Back" },
                                 stats: ["18", "94", "5.2", "1", "23"] }],
                },
                {
                    name: "receiving",
                    labels: ["REC", "YDS", "AVG", "TD", "LONG", "TGTS"],
                    athletes: [{ athlete: { id: 103, displayName: "Wide Out" },
                                 stats: ["7", "112", "16.0", "1", "45", "10"] }],
                },
                {
                    name: "fumbles",
                    labels: ["FUM", "LOST", "REC"],
                    athletes: [{ athlete: { id: 102, displayName: "Runner Back" },
                                 stats: ["1", "1", "0"] }],
                },
                {
                    name: "kicking",
                    labels: ["FG", "PCT", "LONG", "XP", "PTS"],
                    athletes: [{ athlete: { id: 104, displayName: "Boot Legger" },
                                 stats: ["3/4", "75.0", "52", "2/3", "11"] }],
                },
            ],
        }],
        teams: [
            { team: { abbreviation: "KC" },
              statistics: [
                { name: "sacksYardsLost", displayValue: "1-7" },
                { name: "interceptions", displayValue: "1" },
                { name: "fumblesLost", displayValue: "0" },
              ] },
            { team: { abbreviation: "DEN" },
              statistics: [
                { name: "sacksYardsLost", displayValue: "4-31" },
                { name: "interceptions", displayValue: "2" },
                { name: "fumblesLost", displayValue: "1" },
              ] },
        ],
    },
    scoringPlays: [
        { text: "Boot Legger 52 Yd Field Goal", team: { abbreviation: "KC" }, type: { text: "Field Goal" } },
        { text: "Boot Legger 23 Yd Field Goal", team: { abbreviation: "KC" }, type: { text: "Field Goal" } },
        { text: "Boot Legger 44 Yd Field Goal", team: { abbreviation: "KC" }, type: { text: "Field Goal" } },
        { text: "Corner Guy 35 Yd Interception Return (Boot Legger Kick)", team: { abbreviation: "KC" }, type: { text: "Interception Return Touchdown" } },
        { text: "Held in end zone, Safety", team: { abbreviation: "DEN" }, type: { text: "Safety" } },
    ],
};

const ID_MAP = new Map<string, string>([
    ["101", "gsis_qb"], ["102", "gsis_rb"], ["103", "gsis_wr"], ["104", "gsis_k"],
]);

Deno.test("box score parses into raw counting stats", () => {
    const lines = extractPlayerStats(SUMMARY, ID_MAP);
    const qb = lines.get("gsis_qb")!;
    expect(qb.completions === 22 && qb.attempts === 30, "C/ATT split");
    expect(qb.passing_yards === 285 && qb.passing_tds === 2 && qb.passing_interceptions === 1, "passing line");
    const rb = lines.get("gsis_rb")!;
    expect(rb.carries === 18 && rb.rushing_yards === 94 && rb.rushing_tds === 1, "rushing line");
    expect(rb.fumbles_lost === 1, "fumbles merge onto same player");
    const wr = lines.get("gsis_wr")!;
    expect(wr.receptions === 7 && wr.receiving_yards === 112 && wr.targets === 10, "receiving line");
});

Deno.test("kicker FG distances bucket from scoring plays", () => {
    const lines = extractPlayerStats(SUMMARY, ID_MAP);
    applyFieldGoalDistances(SUMMARY, lines);
    const k = lines.get("gsis_k")!;
    expect(k.fg_made_20_29 === 1, "23-yarder in 20-29");
    expect(k.fg_made_40_49 === 1, "44-yarder in 40-49");
    expect(k.fg_made_50_59 === 1, "52-yarder in 50-59");
    expect(k.fg_missed === 1, "3/4 leaves one miss");
    expect(k.pat_made === 2 && k.pat_missed === 1, "XP 2/3");
    expect(!("__fg_made_total" in k) && !("__kicker_name" in k), "bookkeeping keys removed");
});

Deno.test("unmatched FG makes reconcile into the 30-39 bucket", () => {
    const noPlays: EspnSummary = { boxscore: SUMMARY.boxscore, scoringPlays: [] };
    const lines = extractPlayerStats(noPlays, ID_MAP);
    applyFieldGoalDistances(noPlays, lines);
    const k = lines.get("gsis_k")!;
    expect(k.fg_made_30_39 === 3, "all 3 makes fall back to mid bucket");
});

Deno.test("DST synthesizes from opponent offense + scoring plays", () => {
    const home = { team: "KC", homeAway: "home", score: 30 };
    const away = { team: "DEN", homeAway: "away", score: 12 };
    const dst = synthesizeDST(SUMMARY, home, away);
    const kc = dst.get("DEF_KC")!;
    // KC defense: DEN threw 2 INTs, was sacked 4 times, lost 1 fumble.
    expect(kc.def_sacks === 4 && kc.def_interceptions === 2 && kc.def_fumble_recoveries === 1, "KC DST from DEN offense");
    expect(kc.def_tds === 1, "interception return TD credited");
    expect(kc.def_points_allowed === 12, "points allowed = DEN score");
    const den = dst.get("DEF_DEN")!;
    expect(den.def_safeties === 1, "safety credited to DEN");
    expect(den.def_points_allowed === 30, "points allowed = KC score");
});

Deno.test("makeRow computes offense-only preset points", () => {
    const row = makeRow("gsis_wr", 2026, 3, {
        receptions: 7, receiving_yards: 112, receiving_tds: 1, targets: 10,
    }, false);
    // 112*0.1 + 6 = 17.2 std; PPR +7; half +3.5
    expect(row.fantasy_points === 17.2, `std ${row.fantasy_points}`);
    expect(row.fantasy_points_ppr === 24.2, `ppr ${row.fantasy_points_ppr}`);
    expect(row.fantasy_points_half_ppr === 20.7, `half ${row.fantasy_points_half_ppr}`);
    // Kickers/DST get zero preset points (raw columns carry their scoring).
    const kRow = makeRow("gsis_k", 2026, 3, { fg_made_40_49: 2, pat_made: 3 }, false);
    expect(kRow.fantasy_points === 0, "kicker preset points stay 0");
});

Deno.test("team abbreviation fixup", () => {
    expect(fixTeam("WSH") === "WAS" && fixTeam("KC") === "KC" && fixTeam("la") === "LAR", "fixups");
});
