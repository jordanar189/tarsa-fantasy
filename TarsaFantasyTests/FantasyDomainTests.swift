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
                    config: RosterConfig = oneQBConfig) -> League {
    League(
        id: "L1", name: "Test League", season: 2025, scoring: .standard,
        createdAt: Date(timeIntervalSince1970: 0),
        teams: teams, schedule: schedule, rosterConfig: config
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
