// Unit tests for the pure domain layer (Fantasy.swift / Models.swift).
// No I/O, no actors — these exercise exactly the logic the release-readiness
// review flagged: standings ordering, auto-pick position phases, lineup
// resolution, and schedule generation.

import Testing
@testable import Tarsa_Fantasy

// MARK: - Fixtures

/// A QB whose weekly fantasy points are given per week. All three preset
/// point fields are set identically so any Scoring preset sees the same value.
private func qb(_ id: String, weekPoints: [Int: Double]) -> Player {
    Player(
        id: id, name: id, position: "QB", positionGroup: "QB",
        headshotURL: "", team: "TST",
        games: weekPoints.map { week, pts in
            Game(season: 2025, week: week,
                 fantasyPoints: pts, fantasyPointsPPR: pts, fantasyPointsHalfPPR: pts)
        }
    )
}

/// Minimal 1-starter league: each team rosters exactly one QB, so a team's
/// weekly score IS that player's points — standings math stays hand-checkable.
private let oneQBConfig = RosterConfig(
    qb: 1, rb: 0, wr: 0, te: 0, flex: 0, k: 0, def: 0, bench: 0, ir: 0
)

private func league(teams: [FantasyTeam], schedule: [ScheduleWeek],
                    config: RosterConfig = oneQBConfig,
                    tiebreaker: TiebreakerMode = .pointsFor) -> League {
    League(
        id: "L1", name: "Test League", season: 2025, scoring: .standard,
        createdAt: Date(timeIntervalSince1970: 0),
        teams: teams, schedule: schedule, rosterConfig: config,
        tiebreaker: tiebreaker
    )
}

// MARK: - Standings

struct StandingsTests {

    /// A 2-0-1 team must outrank a 2-1-0 team even when the 2-1-0 team has
    /// far more points-for: ties count as half a win and the order is win
    /// PERCENTAGE, not raw wins (the pre-release bug sorted by raw wins and
    /// let PF decide, putting B first).
    @Test func tieCountsAsHalfWin() {
        let players: [String: Player] = [
            "qa": qb("qa", weekPoints: [1: 10, 2: 7, 3: 10]),   // team A
            "qb": qb("qb", weekPoints: [1: 5, 2: 20, 3: 20]),   // team B
            "qc": qb("qc", weekPoints: [1: 1, 2: 7, 3: 3]),     // team C
            "qd": qb("qd", weekPoints: [1: 2, 2: 3, 3: 5])      // team D
        ]
        let teams = [
            FantasyTeam(id: "A", name: "A", roster: ["qa"]),
            FantasyTeam(id: "B", name: "B", roster: ["qb"]),
            FantasyTeam(id: "C", name: "C", roster: ["qc"]),
            FantasyTeam(id: "D", name: "D", roster: ["qd"])
        ]
        // A beats B, ties C (7-7), beats D  → 2-0-1, PF 27
        // B loses to A, beats D, beats C    → 2-1-0, PF 45
        let schedule = [
            ScheduleWeek(week: 1, matchups: [["A", "B"], ["C", "D"]], byes: []),
            ScheduleWeek(week: 2, matchups: [["A", "C"], ["B", "D"]], byes: []),
            ScheduleWeek(week: 3, matchups: [["A", "D"], ["B", "C"]], byes: [])
        ]
        let rows = Fantasy.standings(league: league(teams: teams, schedule: schedule),
                                     players: players)

        let a = rows.first { $0.id == "A" }!
        let b = rows.first { $0.id == "B" }!
        #expect(a.wins == 2 && a.losses == 0 && a.ties == 1)
        #expect(b.wins == 2 && b.losses == 1 && b.ties == 0)
        #expect(a.rank < b.rank, ".833 (2-0-1) must outrank .667 (2-1-0) despite lower PF")
    }

    /// Head-to-head tiebreaker: among equal win%, the team that won the
    /// meeting ranks first even with far fewer points-for.
    @Test func headToHeadTiebreaker() {
        let players: [String: Player] = [
            "qa": qb("qa", weekPoints: [1: 5,  2: 30, 3: 30]),   // A: PF 65, lost to B
            "qb": qb("qb", weekPoints: [1: 10, 2: 20, 3: 2]),    // B: PF 32, beat A
            "qc": qb("qc", weekPoints: [1: 2,  2: 10, 3: 5]),
            "qd": qb("qd", weekPoints: [1: 3,  2: 1,  3: 1])
        ]
        let teams = ["A": "qa", "B": "qb", "C": "qc", "D": "qd"].map {
            FantasyTeam(id: $0.key, name: $0.key, roster: [$0.value])
        }
        // A: L(B) W(C) W(D) = 2-1 · B: W(A) W(D) L(C) = 2-1
        let schedule = [
            ScheduleWeek(week: 1, matchups: [["A", "B"], ["C", "D"]], byes: []),
            ScheduleWeek(week: 2, matchups: [["A", "C"], ["B", "D"]], byes: []),
            ScheduleWeek(week: 3, matchups: [["A", "D"], ["B", "C"]], byes: [])
        ]
        let byPF = Fantasy.standings(
            league: league(teams: teams, schedule: schedule, tiebreaker: .pointsFor),
            players: players)
        #expect(byPF.first { $0.id == "A" }!.rank < byPF.first { $0.id == "B" }!.rank,
                "points-for mode: A's 65 PF outranks B's 32")
        let byH2H = Fantasy.standings(
            league: league(teams: teams, schedule: schedule, tiebreaker: .headToHead),
            players: players)
        #expect(byH2H.first { $0.id == "B" }!.rank < byH2H.first { $0.id == "A" }!.rank,
                "h2h mode: B beat A, so B ranks first despite the PF gap")
    }

    /// Points-against tiebreaker: the tougher schedule (more PA) ranks first.
    @Test func pointsAgainstTiebreaker() {
        let players: [String: Player] = [
            "qa": qb("qa", weekPoints: [1: 21]),   // A: PF 21, PA 20
            "qb": qb("qb", weekPoints: [1: 50]),   // B: PF 50, PA 5
            "qc": qb("qc", weekPoints: [1: 20]),
            "qd": qb("qd", weekPoints: [1: 5])
        ]
        let teams = ["A": "qa", "B": "qb", "C": "qc", "D": "qd"].map {
            FantasyTeam(id: $0.key, name: $0.key, roster: [$0.value])
        }
        let schedule = [ScheduleWeek(week: 1, matchups: [["A", "C"], ["B", "D"]], byes: [])]
        let rows = Fantasy.standings(
            league: league(teams: teams, schedule: schedule, tiebreaker: .pointsAgainst),
            players: players)
        #expect(rows.first { $0.id == "A" }!.rank < rows.first { $0.id == "B" }!.rank,
                "A's 20 PA outranks B's 5 PA in points-against mode")
    }

    /// Identical records fall back to points-for.
    @Test func pointsForBreaksEqualRecords() {
        let players: [String: Player] = [
            "qa": qb("qa", weekPoints: [1: 30]),
            "qb": qb("qb", weekPoints: [1: 3]),
            "qc": qb("qc", weekPoints: [1: 10]),
            "qd": qb("qd", weekPoints: [1: 2])
        ]
        let teams = ["A": "qa", "B": "qb", "C": "qc", "D": "qd"].map {
            FantasyTeam(id: $0.key, name: $0.key, roster: [$0.value])
        }
        let schedule = [ScheduleWeek(week: 1, matchups: [["A", "B"], ["C", "D"]], byes: [])]
        let rows = Fantasy.standings(league: league(teams: teams, schedule: schedule),
                                     players: players)
        // A and C are both 1-0; A's 30 PF outranks C's 10.
        #expect(rows.first { $0.id == "A" }!.rank < rows.first { $0.id == "C" }!.rank)
    }
}

// MARK: - Schedule generation

struct GenerateScheduleTests {

    @Test func evenTeamsRoundRobin() {
        let ids = ["A", "B", "C", "D"]
        let weeks = Fantasy.generateSchedule(teamIDs: ids, weeks: 3)
        #expect(weeks.count == 3)
        for wk in weeks {
            #expect(wk.matchups.count == 2)
            #expect(wk.byes.isEmpty)
            // No team appears twice in one week.
            let appearances = wk.matchups.flatMap { $0 }
            #expect(Set(appearances).count == appearances.count)
        }
        // Full single round-robin: every pair meets exactly once in 3 weeks.
        let pairs = weeks.flatMap { $0.matchups.map { Set($0) } }
        #expect(Set(pairs).count == 6)
    }

    @Test func oddTeamsGetWeeklyBye() {
        let ids = ["A", "B", "C", "D", "E"]
        let weeks = Fantasy.generateSchedule(teamIDs: ids, weeks: 5)
        #expect(weeks.count == 5)
        for wk in weeks {
            #expect(wk.matchups.count == 2, "5 teams → 2 games")
            #expect(wk.byes.count == 1, "5 teams → exactly one bye per week")
            let everyone = wk.matchups.flatMap { $0 } + wk.byes
            #expect(Set(everyone).count == 5, "every team plays or has a bye")
        }
    }

    @Test func fewerThanTwoTeamsIsEmpty() {
        #expect(Fantasy.generateSchedule(teamIDs: ["A"], weeks: 3).isEmpty)
        #expect(Fantasy.generateSchedule(teamIDs: [], weeks: 3).isEmpty)
    }

    @Test func longSeasonCyclesRoundRobin() {
        // 4 teams, 14 weeks: rounds repeat, every week still fully paired.
        let weeks = Fantasy.generateSchedule(teamIDs: ["A", "B", "C", "D"], weeks: 14)
        #expect(weeks.count == 14)
        #expect(weeks.allSatisfy { $0.matchups.count == 2 })
    }
}

// MARK: - Auto-pick K/DEF phase

struct AutoPickPhaseTests {

    /// Default 1 K + 1 DEF league, 15 rounds: the last two rounds are the
    /// K/DEF phase (this reproduces the long-standing behavior exactly).
    @Test func defaultPhaseIsFinalTwoRounds() {
        let r14 = Fantasy.autoPickAllowedPositions(
            round: 14, totalRounds: 15, currentLoopPicks: [],
            kSlots: 1, defSlots: 1, kOwned: 0, defOwned: 0)
        #expect(r14 == ["K", "DEF"])
        let r13 = Fantasy.autoPickAllowedPositions(
            round: 13, totalRounds: 15, currentLoopPicks: [],
            kSlots: 1, defSlots: 1, kOwned: 0, defOwned: 0)
        #expect(!r13.contains("K") && !r13.contains("DEF"))
    }

    /// A league that starts neither K nor DEF has NO phase — the final rounds
    /// draft from the normal template (the pre-release bug forced K/DEF here).
    @Test func zeroKDefLeagueHasNoPhase() {
        let last = Fantasy.autoPickAllowedPositions(
            round: 15, totalRounds: 15, currentLoopPicks: [],
            kSlots: 0, defSlots: 0, kOwned: 0, defOwned: 0)
        #expect(!last.contains("K") && !last.contains("DEF"))
        #expect(!last.isEmpty, "template positions still available")
    }

    /// Inside the phase, only the still-missing position is requested.
    @Test func phaseOnlyAsksForMissingPositions() {
        let need = Fantasy.autoPickAllowedPositions(
            round: 14, totalRounds: 15, currentLoopPicks: [],
            kSlots: 1, defSlots: 1, kOwned: 1, defOwned: 0)
        #expect(need == ["DEF"], "K already rostered → only DEF requested")
    }

    /// Both covered early (e.g. via queue): the phase yields to the template.
    @Test func coveredPhaseFallsBackToTemplate() {
        let allowed = Fantasy.autoPickAllowedPositions(
            round: 15, totalRounds: 15, currentLoopPicks: [],
            kSlots: 1, defSlots: 1, kOwned: 1, defOwned: 1)
        #expect(!allowed.contains("K") && !allowed.contains("DEF"))
        #expect(!allowed.isEmpty)
    }

    /// A 2-DEF league reserves a 3-round window (2 DEF + 1 K).
    @Test func phaseWidthTracksSlotCounts() {
        let r12 = Fantasy.autoPickAllowedPositions(
            round: 13, totalRounds: 15, currentLoopPicks: [],
            kSlots: 1, defSlots: 2, kOwned: 0, defOwned: 0)
        #expect(r12 == ["K", "DEF"])
        let r11 = Fantasy.autoPickAllowedPositions(
            round: 12, totalRounds: 15, currentLoopPicks: [],
            kSlots: 1, defSlots: 2, kOwned: 0, defOwned: 0)
        #expect(!r11.contains("K"))
    }
}

// MARK: - Lineup slots & resolution

struct LineupTests {

    @Test func flexAcceptsSkillPositionsOnly() {
        #expect(LineupSlot.flex.accepts(position: "RB"))
        #expect(LineupSlot.flex.accepts(position: "WR"))
        #expect(LineupSlot.flex.accepts(position: "TE"))
        #expect(!LineupSlot.flex.accepts(position: "QB"))
        #expect(!LineupSlot.flex.accepts(position: "K"))
        #expect(!LineupSlot.flex.accepts(position: "DEF"))
    }

    @Test func flexVariantEligibility() {
        #expect(LineupSlot.superflex.accepts(position: "QB"))
        #expect(LineupSlot.superflex.accepts(position: "RB"))
        #expect(LineupSlot.superflex.accepts(position: "WR"))
        #expect(LineupSlot.superflex.accepts(position: "TE"))
        #expect(!LineupSlot.superflex.accepts(position: "K"))
        #expect(LineupSlot.wrFlex.accepts(position: "RB"))
        #expect(LineupSlot.wrFlex.accepts(position: "WR"))
        #expect(!LineupSlot.wrFlex.accepts(position: "TE"))
        #expect(LineupSlot.recFlex.accepts(position: "WR"))
        #expect(LineupSlot.recFlex.accepts(position: "TE"))
        #expect(!LineupSlot.recFlex.accepts(position: "RB"))
    }

    @Test func superflexCountsInStartersAndSlots() {
        let config = RosterConfig(qb: 1, rb: 2, wr: 2, te: 1, flex: 1,
                                  superflex: 1, k: 1, def: 1, bench: 6)
        #expect(config.starterCount == 10)
        #expect(config.starterSlots.filter { $0 == .superflex }.count == 1)
    }

    /// In a 2-QB (superflex) league, auto-fill puts the best QB in the QB
    /// slot and the second QB in the superflex — the catch-all never steals
    /// the dedicated slot's player.
    @Test func superflexAutoFillTakesSecondQB() {
        let config = RosterConfig(qb: 1, rb: 0, wr: 0, te: 0, flex: 0,
                                  superflex: 1, k: 0, def: 0, bench: 0)
        let players = [
            "q1": qb("q1", weekPoints: [1: 25]),
            "q2": qb("q2", weekPoints: [1: 15])
        ]
        let team = FantasyTeam(id: "A", name: "A", roster: ["q2", "q1"])
        let (starters, _) = Fantasy.resolveLineup(
            team: team, players: players, config: config,
            scoring: .standard, week: nil)
        #expect(starters == ["q1", "q2"], "QB slot gets the better QB, SFLX the second")
    }

    /// A frozen weekly lineup with the right slot count is honored verbatim.
    @Test func frozenWeeklyLineupIsHonored() {
        let players = [
            "q1": qb("q1", weekPoints: [1: 10]),
            "q2": qb("q2", weekPoints: [1: 20])
        ]
        let team = FantasyTeam(
            id: "A", name: "A", roster: ["q1", "q2"],
            starters: ["q2"],                 // live lineup says q2...
            weeklyLineups: [1: ["q1"]]        // ...but week 1 froze q1
        )
        let (starters, bench) = Fantasy.resolveLineup(
            team: team, players: players, config: oneQBConfig,
            scoring: .standard, week: 1)
        #expect(starters == ["q1"])
        #expect(bench == ["q2"])
    }

    /// A starter who left the roster is blanked in place — the slot empties,
    /// it doesn't shift (starters are slot-positional).
    @Test func offRosterStarterIsBlankedInPlace() {
        let config = RosterConfig(qb: 2, rb: 0, wr: 0, te: 0, flex: 0,
                                  k: 0, def: 0, bench: 0, ir: 0)
        let players = [
            "q1": qb("q1", weekPoints: [1: 10]),
            "q2": qb("q2", weekPoints: [1: 20])
        ]
        let team = FantasyTeam(
            id: "A", name: "A", roster: ["q2"],       // q1 was dropped
            starters: ["q1", "q2"]
        )
        let (starters, _) = Fantasy.resolveLineup(
            team: team, players: players, config: config,
            scoring: .standard, week: nil)
        #expect(starters == ["", "q2"], "dropped starter blanks its own slot only")
    }

    /// A frozen weekly lineup survives a mid-season slot-layout change:
    /// it's padded/truncated to the new starter count instead of being
    /// discarded and re-auto-filled (which silently rewrote past weeks).
    @Test func frozenLineupPadsWhenSlotLayoutGrows() {
        // Frozen under a 1-QB layout; config later grew to QB + SFLX.
        let grown = RosterConfig(qb: 1, rb: 0, wr: 0, te: 0, flex: 0,
                                 superflex: 1, k: 0, def: 0, bench: 0)
        let players = [
            "q1": qb("q1", weekPoints: [1: 10]),
            "q2": qb("q2", weekPoints: [1: 20])
        ]
        let team = FantasyTeam(
            id: "A", name: "A", roster: ["q1", "q2"],
            weeklyLineups: [1: ["q1"]]      // frozen when there was one slot
        )
        let (starters, _) = Fantasy.resolveLineup(
            team: team, players: players, config: grown,
            scoring: .standard, week: 1)
        #expect(starters == ["q1", ""], "frozen starter kept, new slot padded empty")
    }

    /// No saved lineup at all → auto-fill from the roster.
    @Test func emptyLineupAutoFills() {
        let players = ["q1": qb("q1", weekPoints: [1: 10])]
        let team = FantasyTeam(id: "A", name: "A", roster: ["q1"])
        let (starters, _) = Fantasy.resolveLineup(
            team: team, players: players, config: oneQBConfig,
            scoring: .standard, week: nil)
        #expect(starters == ["q1"])
    }
}

// MARK: - Franchise lineage (all-time history)

struct LineageTests {

    /// Two-season chain: the child's teams point at their parent-season
    /// selves through priorTeamID, so both seasons' ids resolve to the same
    /// franchise root and records aggregate across the rollover — even when
    /// the team changed owners between seasons.
    @Test func allTimeRecordsAggregateAcrossRollover() {
        let parent = league(teams: [
            FantasyTeam(id: "A1", name: "Alpha", ownerID: "u1"),
            FantasyTeam(id: "B1", name: "Bravo", ownerID: "u2")
        ], schedule: [])
        var childTeams = [
            FantasyTeam(id: "A2", name: "Alpha II", ownerID: "u3"),   // re-owned
            FantasyTeam(id: "B2", name: "Bravo", ownerID: nil)        // unclaimed
        ]
        childTeams[0].priorTeamID = "A1"
        childTeams[1].priorTeamID = "B1"
        var child = league(teams: childTeams, schedule: [])
        child.parentLeagueID = parent.id

        let chain = [child, parent]     // newest first
        let roots = Fantasy.franchiseRoots(chain: chain)
        #expect(roots["A2"] == "A1" && roots["B2"] == "B1")

        let archives = [
            LeagueSeasonArchive(
                id: "s2", leagueID: child.id, season: 2026,
                standings: [
                    StandingsRow(id: "A2", name: "Alpha II", wins: 8, losses: 6, ties: 0,
                                 pointsFor: 1400, pointsAgainst: 1300, games: 14, rank: 1),
                    StandingsRow(id: "B2", name: "Bravo", wins: 6, losses: 8, ties: 0,
                                 pointsFor: 1200, pointsAgainst: 1300, games: 14, rank: 2)
                ],
                scoringLeaderTeamID: nil, scoringLeaderTeamName: nil,
                championTeamID: "A2", championTeamName: "Alpha II",
                archivedAt: Date(timeIntervalSince1970: 0)
            ),
            LeagueSeasonArchive(
                id: "s1", leagueID: parent.id, season: 2025,
                standings: [
                    StandingsRow(id: "A1", name: "Alpha", wins: 10, losses: 4, ties: 0,
                                 pointsFor: 1500, pointsAgainst: 1200, games: 14, rank: 1),
                    StandingsRow(id: "B1", name: "Bravo", wins: 4, losses: 10, ties: 0,
                                 pointsFor: 1100, pointsAgainst: 1400, games: 14, rank: 2)
                ],
                scoringLeaderTeamID: nil, scoringLeaderTeamName: nil,
                championTeamID: "B1", championTeamName: "Bravo",
                archivedAt: Date(timeIntervalSince1970: 0)
            )
        ]
        let records = Fantasy.allTimeRecords(archives: archives, chain: chain)
        #expect(records.count == 2, "two franchises, not four fragmented teams")

        let alpha = records.first { $0.id == "A1" }!
        #expect(alpha.wins == 18 && alpha.losses == 10 && alpha.seasons == 2)
        #expect(alpha.championships == 1)
        #expect(alpha.name == "Alpha II", "newest name wins")

        let bravo = records.first { $0.id == "B1" }!
        #expect(bravo.wins == 10 && bravo.losses == 18 && bravo.championships == 1)
    }

    /// The H2H matrix keys matchups from both seasons to franchise roots,
    /// and each cell is from the row franchise's perspective.
    @Test func headToHeadMatrixMergesLineage() {
        let parent = league(teams: [
            FantasyTeam(id: "A1", name: "Alpha", ownerID: "u1"),
            FantasyTeam(id: "B1", name: "Bravo", ownerID: "u2")
        ], schedule: [])
        var childTeams = [
            FantasyTeam(id: "A2", name: "Alpha", ownerID: "u1"),
            FantasyTeam(id: "B2", name: "Bravo", ownerID: nil)
        ]
        childTeams[0].priorTeamID = "A1"
        childTeams[1].priorTeamID = "B1"
        var child = league(teams: childTeams, schedule: [])
        child.parentLeagueID = parent.id
        let chain = [child, parent]

        let matchups = [
            // Parent season: A beats B, then they tie.
            ArchivedMatchup(leagueID: parent.id, season: 2025, week: 1,
                            homeTeamID: "A1", awayTeamID: "B1",
                            homeUserID: "u1", awayUserID: "u2",
                            homePoints: 100, awayPoints: 90),
            ArchivedMatchup(leagueID: parent.id, season: 2025, week: 2,
                            homeTeamID: "B1", awayTeamID: "A1",
                            homeUserID: "u2", awayUserID: "u1",
                            homePoints: 80, awayPoints: 80),
            // Child season (new ids, B unclaimed): B beats A.
            ArchivedMatchup(leagueID: child.id, season: 2026, week: 1,
                            homeTeamID: "B2", awayTeamID: "A2",
                            homeUserID: nil, awayUserID: "u1",
                            homePoints: 120, awayPoints: 110)
        ]
        let grid = Fantasy.headToHeadMatrix(matchups: matchups, chain: chain)
        let aVsB = grid["A1"]?["B1"]
        #expect(aVsB == H2HRecord(wins: 1, losses: 1, ties: 1))
        let bVsA = grid["B1"]?["A1"]
        #expect(bVsA == H2HRecord(wins: 1, losses: 1, ties: 1))
    }
}
