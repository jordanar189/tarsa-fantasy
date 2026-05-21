import Foundation
import Supabase

// Single shared Supabase client + the service actor that owns all backend
// reads/writes for accounts, leagues and teams. Player stats still come from
// NFLDataService (nflverse CSV cache); only league state lives in Supabase.

enum SupabaseConfig {
    static let url    = URL(string: "https://uxpfktjpmyhdlwfxnwri.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InV4cGZrdGpwbXloZGx3Znhud3JpIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg4ODUyMTcsImV4cCI6MjA5NDQ2MTIxN30.NDpvfErC9U7OsV3SychJre-GJxbpzimz3psScgxEXm8"

    // Supabase Auth is email-based; we synthesize a stable email per username
    // so the user only ever sees/types a username.
    static let usernameEmailDomain = "fantasy-football.app"
    static func email(for username: String) -> String {
        "\(username.lowercased())@\(usernameEmailDomain)"
    }

    // Shared client — Supabase's SDK is internally thread-safe, so a single
    // instance can be used from both the RemoteService actor (writes) and the
    // NFLDataService actor (reads) without contention.
    static let sharedClient: SupabaseClient = {
        SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }()
}

actor RemoteService {
    static let shared = RemoteService()

    let client: SupabaseClient
    private let isoFormatter: ISO8601DateFormatter

    init() {
        client = SupabaseConfig.sharedClient
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFormatter = f
    }

    // MARK: - Auth

    @discardableResult
    func signUp(username: String, password: String) async throws -> Session {
        let email = SupabaseConfig.email(for: username)
        _ = try await client.auth.signUp(
            email: email,
            password: password,
            data: ["username": .string(username)]
        )
        // Auto sign-in (email confirmation is off, but signUp may not return a
        // session every time — call signIn to be sure we have one).
        return try await signIn(username: username, password: password)
    }

    @discardableResult
    func signIn(username: String, password: String) async throws -> Session {
        let email = SupabaseConfig.email(for: username)
        let resp = try await client.auth.signIn(email: email, password: password)
        let profile = try await fetchProfile(userID: resp.user.id)
        return Session(userID: resp.user.id.uuidString, profile: profile)
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    // Returns a session if Supabase already has a persisted, valid session
    // from a prior launch, otherwise nil.
    func restoreSession() async -> Session? {
        do {
            let user = try await client.auth.user()
            let profile = try await fetchProfile(userID: user.id)
            return Session(userID: user.id.uuidString, profile: profile)
        } catch {
            return nil
        }
    }

    private func fetchProfile(userID: UUID) async throws -> Profile {
        let row: ProfileRow = try await client.from("profiles")
            .select()
            .eq("id", value: userID)
            .single()
            .execute()
            .value
        return Profile(
            id: row.id.uuidString, username: row.username,
            isAdmin: row.isAdmin, isTester: row.isTester
        )
    }

    // Returns the user's persisted theme preference. Nil when no row /
    // column found (treat as the default).
    func profileTheme(userID: String) async -> AppTheme? {
        guard let uuid = UUID(uuidString: userID) else { return nil }
        struct Row: Decodable { let theme: String? }
        let row: Row? = try? await client.from("profiles")
            .select("theme")
            .eq("id", value: uuid)
            .single()
            .execute().value
        return row?.theme.flatMap(AppTheme.init(rawValue:))
    }

    @discardableResult
    func setProfileTheme(userID: String, theme: AppTheme) async throws -> AppTheme {
        guard let uuid = UUID(uuidString: userID) else { return theme }
        struct Update: Encodable { let theme: String }
        _ = try await client.from("profiles")
            .update(Update(theme: theme.rawValue))
            .eq("id", value: uuid)
            .execute()
        return theme
    }

    // MARK: - Leagues

    // All leagues the user is a member of (creator or owns at least one team).
    func myLeagues(userID: String) async throws -> [LeagueSummary] {
        guard let uuid = UUID(uuidString: userID) else { return [] }
        // Two queries (created + owned) merged client-side. RLS lets us read
        // anything when authenticated, so we filter explicitly here.
        async let createdRows: [LeagueRow] = client.from("leagues")
            .select()
            .eq("creator_id", value: uuid)
            .execute()
            .value
        async let ownedTeamRows: [TeamRow] = client.from("teams")
            .select()
            .eq("owner_id", value: uuid)
            .execute()
            .value

        let created = try await createdRows
        let ownedTeams = try await ownedTeamRows
        let ownedLeagueIDs = Set(ownedTeams.map(\.leagueId))

        let ownedOnly: [LeagueRow]
        if ownedLeagueIDs.isEmpty {
            ownedOnly = []
        } else {
            let missing = ownedLeagueIDs.subtracting(created.map(\.id))
            if missing.isEmpty {
                ownedOnly = []
            } else {
                ownedOnly = try await client.from("leagues")
                    .select()
                    .in("id", values: Array(missing))
                    .execute()
                    .value
            }
        }

        let all = (created + ownedOnly).sorted { $0.createdAt > $1.createdAt }
        // Need team counts — fetch with another query
        let leagueIDs = all.map(\.id)
        let teamCounts: [UUID: Int] = try await teamCounts(forLeagues: leagueIDs)
        return all.map { row in
            LeagueSummary(
                id: row.id.uuidString,
                name: row.name,
                season: row.season,
                scoring: Scoring(rawValue: row.scoring) ?? .ppr,
                teamCount: teamCounts[row.id] ?? 0,
                createdAt: row.createdAt,
                joinCode: row.joinCode,
                creatorID: row.creatorId.uuidString,
                isTest: row.isTest
            )
        }
    }

    private func teamCounts(forLeagues ids: [UUID]) async throws -> [UUID: Int] {
        if ids.isEmpty { return [:] }
        let rows: [TeamRow] = try await client.from("teams")
            .select("id, league_id, name, owner_id, roster, starters, sort_index")
            .in("league_id", values: ids)
            .execute()
            .value
        var counts: [UUID: Int] = [:]
        for r in rows { counts[r.leagueId, default: 0] += 1 }
        return counts
    }

    func league(id: String) async throws -> League? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        async let leagueRow: LeagueRow? = try? await client.from("leagues")
            .select()
            .eq("id", value: uuid)
            .single()
            .execute()
            .value
        async let teamRows: [TeamRow] = (try? await client.from("teams")
            .select()
            .eq("league_id", value: uuid)
            .order("sort_index", ascending: true)
            .execute()
            .value) ?? []

        guard let lg = await leagueRow else { return nil }
        let teams = await teamRows
        return Self.assemble(league: lg, teams: teams)
    }

    func leagueByCode(_ code: String) async throws -> League? {
        let normalized = code.trimmingCharacters(in: .whitespaces).uppercased()
        let row: LeagueRow? = try? await client.from("leagues")
            .select()
            .eq("join_code", value: normalized)
            .single()
            .execute()
            .value
        guard let lg = row else { return nil }
        let teamRows: [TeamRow] = (try? await client.from("teams")
            .select()
            .eq("league_id", value: lg.id)
            .order("sort_index", ascending: true)
            .execute()
            .value) ?? []
        return Self.assemble(league: lg, teams: teamRows)
    }

    @discardableResult
    func createLeague(
        creatorID: String,
        name: String,
        season: Int,
        scoring: Scoring,
        rosterConfig: RosterConfig,
        yourTeamName: String,
        otherTeamNames: [String],
        regularSeasonWeeks: Int? = nil,
        playoffTeams: Int = 6,
        playoffReseed: Bool = true,
        divisionNames: [String] = [],
        scoringSettings: ScoringSettings? = nil
    ) async throws -> League {
        guard let creatorUUID = UUID(uuidString: creatorID) else {
            throw RemoteError.invalidUserID
        }
        let cleanedName = name.trimmingCharacters(in: .whitespaces)
        let cleanedYour = yourTeamName.trimmingCharacters(in: .whitespaces)
        let cleanedOthers = otherTeamNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let teamCount = 1 + cleanedOthers.count
        guard teamCount >= 2 else { throw RemoteError.tooFewTeams }
        guard teamCount <= 16 else { throw RemoteError.tooManyTeams }

        // Reserve a unique 6-char join code (retry on collision).
        let joinCode = try await reserveJoinCode()

        // Build team UUIDs up-front so we can generate the schedule before
        // inserting (schedule references team IDs).
        let teamIDs: [UUID] = (0..<teamCount).map { _ in UUID() }
        // Standard leagues request a full-length regular season; sims pass nil
        // and fall back to a single round-robin.
        let schedulePlans = Fantasy.generateSchedule(
            teamIDs: teamIDs.map(\.uuidString), weeks: regularSeasonWeeks
        )
        let scheduleAny = scheduleAsAnyJSON(schedulePlans)
        let configAny   = rosterConfigAsAnyJSON(rosterConfig)
        let effectiveSeasonWeeks = schedulePlans.count
        let cleanedDivisions = divisionNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Cap the playoff field at the team count.
        let cappedPlayoffTeams = max(0, min(playoffTeams, teamCount))

        struct LeagueInsert: Encodable {
            let id: UUID
            let name: String
            let season: Int
            let scoring: String
            let roster_config: AnyJSON
            let schedule: AnyJSON
            let join_code: String
            let creator_id: UUID
            let waiver_priority: [String]
            let regular_season_weeks: Int
            let playoff_teams: Int
            let playoff_reseed: Bool
            let division_names: AnyJSON
            let scoring_settings: AnyJSON?
        }
        let leagueID = UUID()
        // Initial priority: reverse-order of team creation (last team picks
        // first — standard pre-season default). League creator's team is at
        // index 0, so they end up with the lowest priority initially.
        let initialPriority = teamIDs.reversed().map { $0.uuidString }
        let leagueInsert = LeagueInsert(
            id: leagueID,
            name: cleanedName.isEmpty ? "Untitled League" : cleanedName,
            season: season,
            scoring: scoring.rawValue,
            roster_config: configAny,
            schedule: scheduleAny,
            join_code: joinCode,
            creator_id: creatorUUID,
            waiver_priority: initialPriority,
            regular_season_weeks: effectiveSeasonWeeks,
            playoff_teams: cappedPlayoffTeams,
            playoff_reseed: playoffReseed,
            division_names: stringsAsAnyJSON(cleanedDivisions),
            scoring_settings: scoringSettings.map(scoringSettingsAsAnyJSON)
        )
        let insertedLeague: LeagueRow = try await client.from("leagues")
            .insert(leagueInsert)
            .select()
            .single()
            .execute()
            .value

        struct TeamInsert: Encodable {
            let id: UUID
            let league_id: UUID
            let name: String
            let owner_id: UUID?
            let sort_index: Int
            let division: Int?
        }
        let allNames = [cleanedYour.isEmpty ? "Your Team" : cleanedYour] + cleanedOthers
        let divCount = cleanedDivisions.count
        let teamInserts: [TeamInsert] = zip(teamIDs, allNames).enumerated().map { idx, pair in
            TeamInsert(
                id: pair.0,
                league_id: insertedLeague.id,
                name: pair.1,
                owner_id: idx == 0 ? creatorUUID : nil,
                sort_index: idx,
                // Distribute teams across divisions in creation order.
                division: divCount >= 2 ? idx % divCount : nil
            )
        }
        let insertedTeams: [TeamRow] = try await client.from("teams")
            .insert(teamInserts)
            .select()
            .execute()
            .value

        return Self.assemble(league: insertedLeague, teams: insertedTeams.sorted { $0.sortIndex < $1.sortIndex })
    }

    private func reserveJoinCode() async throws -> String {
        for _ in 0..<6 {
            let code = Self.randomJoinCode()
            let existing: [LeagueRow] = (try? await client.from("leagues")
                .select()
                .eq("join_code", value: code)
                .execute()
                .value) ?? []
            if existing.isEmpty { return code }
        }
        throw RemoteError.joinCodeCollision
    }

    private static func randomJoinCode() -> String {
        // 6 chars, base-32-ish; skip ambiguous chars (0/O, 1/I).
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    func deleteLeague(_ id: String) async throws {
        guard let uuid = UUID(uuidString: id) else { return }
        try await client.from("leagues").delete().eq("id", value: uuid).execute()
    }

    // MARK: - Teams

    @discardableResult
    func claimTeam(teamID: String, userID: String) async throws -> League? {
        guard let teamUUID = UUID(uuidString: teamID),
              let userUUID = UUID(uuidString: userID) else { return nil }
        struct OwnerUpdate: Encodable { let owner_id: UUID }
        // RLS guarantees we only succeed if owner_id is currently null.
        let updated: TeamRow = try await client.from("teams")
            .update(OwnerUpdate(owner_id: userUUID))
            .eq("id", value: teamUUID)
            .is("owner_id", value: nil as Bool?)
            .select()
            .single()
            .execute()
            .value
        return try await league(id: updated.leagueId.uuidString)
    }

    @discardableResult
    func setRoster(
        teamID: String, roster: [String], starters: [String]
    ) async throws -> League? {
        guard let teamUUID = UUID(uuidString: teamID) else { return nil }
        struct RosterUpdate: Encodable {
            let roster: [String]
            let starters: [String]
        }
        let updated: TeamRow = try await client.from("teams")
            .update(RosterUpdate(roster: roster, starters: starters))
            .eq("id", value: teamUUID)
            .select()
            .single()
            .execute()
            .value
        return try await league(id: updated.leagueId.uuidString)
    }

    // Persists a manually-set lineup (start/sit) plus the IR list, without
    // touching the roster itself. `weeklyLineups` is the full per-week frozen
    // map (caller does the read-modify-write so this stays a plain update).
    // Used by the weekly lineup editor.
    @discardableResult
    func setLineup(
        teamID: String, starters: [String], ir: [String],
        weeklyLineups: [Int: [String]]
    ) async throws -> League? {
        guard let teamUUID = UUID(uuidString: teamID) else { return nil }
        struct LineupUpdate: Encodable {
            let starters: [String]
            let ir: [String]
            let weekly_lineups: AnyJSON
        }
        let weeklyJSON: AnyJSON = .object(Dictionary(uniqueKeysWithValues:
            weeklyLineups.map { (String($0.key), AnyJSON.array($0.value.map { .string($0) })) }
        ))
        let updated: TeamRow = try await client.from("teams")
            .update(LineupUpdate(starters: starters, ir: ir, weekly_lineups: weeklyJSON))
            .eq("id", value: teamUUID)
            .select()
            .single()
            .execute()
            .value
        return try await league(id: updated.leagueId.uuidString)
    }

    // Team branding: name, logo URL, accent color. Any nil leaves that field
    // unchanged (name "" is treated as no-op for name).
    @discardableResult
    func setTeamCustomization(
        teamID: String, name: String?, logoURL: String?, colorHex: String?
    ) async throws -> League? {
        guard let teamUUID = UUID(uuidString: teamID) else { return nil }
        // logo_url / color_hex are sent as explicit JSON (null clears them);
        // name is omitted when blank so it stays unchanged.
        struct BrandUpdate: Encodable {
            let name: String?
            let logo_url: AnyJSON
            let color_hex: AnyJSON
        }
        let cleanedName = name?.trimmingCharacters(in: .whitespaces)
        let updated: TeamRow = try await client.from("teams")
            .update(BrandUpdate(
                name: (cleanedName?.isEmpty == false) ? cleanedName : nil,
                logo_url: logoURL.map { AnyJSON.string($0) } ?? .null,
                color_hex: colorHex.map { AnyJSON.string($0) } ?? .null
            ))
            .eq("id", value: teamUUID)
            .select()
            .single()
            .execute()
            .value
        return try await league(id: updated.leagueId.uuidString)
    }

    // MARK: - Row → model assembly

    private static func assemble(league row: LeagueRow, teams: [TeamRow]) -> League {
        let teamsSorted = teams.sorted { $0.sortIndex < $1.sortIndex }
        // Default priority: reverse team order if the league has none yet.
        let priority = row.waiverPriority.isEmpty
            ? teamsSorted.reversed().map { $0.id.uuidString }
            : row.waiverPriority
        return League(
            id: row.id.uuidString,
            name: row.name,
            season: row.season,
            scoring: Scoring(rawValue: row.scoring) ?? .ppr,
            createdAt: row.createdAt,
            teams: teamsSorted.map { t in
                FantasyTeam(
                    id: t.id.uuidString,
                    name: t.name,
                    roster: t.roster,
                    starters: t.starters,
                    ownerID: t.ownerId?.uuidString,
                    ir: t.ir,
                    weeklyLineups: Dictionary(uniqueKeysWithValues:
                        t.weeklyLineups.compactMap { key, value in
                            Int(key).map { ($0, value) }
                        }),
                    division: t.division,
                    logoURL: t.logoUrl,
                    colorHex: t.colorHex
                )
            },
            schedule: row.schedule,
            rosterConfig: row.rosterConfig,
            joinCode: row.joinCode,
            creatorID: row.creatorId.uuidString,
            waiverSettings: WaiverSettings(
                processDay: row.waiverProcessDay,
                processHour: row.waiverProcessHour,
                periodHours: row.waiverPeriodHours,
                commissionerApproval: row.commissionerApproval
            ),
            waiverPriority: priority,
            lastWaiversRunAt: row.lastWaiversRunAt,
            tradeSettings: TradeSettings(
                approval: TradeApprovalMode(rawValue: row.tradeApproval) ?? .none,
                deadline: row.tradeDeadline,
                voteHours: row.tradeVoteHours
            ),
            isTest: row.isTest,
            simulatedWeek: row.simulatedWeek,
            parentLeagueID: row.parentLeagueId?.uuidString,
            seasonCompleted: row.seasonCompleted,
            seasonCompletedAt: row.seasonCompletedAt,
            regularSeasonWeeks: row.regularSeasonWeeks,
            playoffTeams: row.playoffTeams,
            playoffReseed: row.playoffReseed,
            scoringSettings: row.scoringSettings,
            divisionNames: row.divisionNames,
            championTeamID: row.championTeamId?.uuidString,
            championTeamName: row.championTeamName
        )
    }

    // MARK: - JSON helpers (jsonb columns)

    private func rosterConfigAsAnyJSON(_ c: RosterConfig) -> AnyJSON {
        .object([
            "qb":    .integer(c.qb),
            "rb":    .integer(c.rb),
            "wr":    .integer(c.wr),
            "te":    .integer(c.te),
            "flex":  .integer(c.flex),
            "k":     .integer(c.k),
            "def":   .integer(c.def),
            "bench": .integer(c.bench),
            "ir":    .integer(c.ir),
        ])
    }

    private func scoringSettingsAsAnyJSON(_ s: ScoringSettings) -> AnyJSON {
        .object([
            "passingYardsPerPoint":   .double(s.passingYardsPerPoint),
            "passingTD":              .double(s.passingTD),
            "interception":           .double(s.interception),
            "rushingYardsPerPoint":   .double(s.rushingYardsPerPoint),
            "rushingTD":              .double(s.rushingTD),
            "receivingYardsPerPoint": .double(s.receivingYardsPerPoint),
            "receivingTD":            .double(s.receivingTD),
            "reception":              .double(s.reception),
            "fumbleLost":             .double(s.fumbleLost),
        ])
    }

    private func stringsAsAnyJSON(_ items: [String]) -> AnyJSON {
        .array(items.map { .string($0) })
    }

    private func scheduleAsAnyJSON(_ plans: [ScheduleWeek]) -> AnyJSON {
        .array(plans.map { plan in
            .object([
                "week": .integer(plan.week),
                "matchups": .array(plan.matchups.map { pair in
                    .array(pair.map { .string($0) })
                }),
                "byes": .array(plan.byes.map { .string($0) })
            ])
        })
    }

    // MARK: - Waivers / transactions / settings

    func droppedPlayers(leagueID: String) async throws -> [DroppedPlayer] {
        guard let uuid = UUID(uuidString: leagueID) else { return [] }
        let rows: [DroppedPlayerRow] = (try? await client.from("dropped_players")
            .select()
            .eq("league_id", value: uuid)
            .execute()
            .value) ?? []
        return rows.map {
            DroppedPlayer(
                leagueID: $0.leagueId.uuidString,
                playerID: $0.playerId,
                droppedAt: $0.droppedAt,
                waiverUntil: $0.waiverUntil
            )
        }
    }

    func waiverClaims(leagueID: String) async throws -> [WaiverClaim] {
        guard let uuid = UUID(uuidString: leagueID) else { return [] }
        let rows: [WaiverClaimRow] = (try? await client.from("waiver_claims")
            .select()
            .eq("league_id", value: uuid)
            .order("created_at", ascending: false)
            .execute()
            .value) ?? []
        let teamNames = try await teamNameMap(leagueID: uuid)
        return rows.map { r in
            WaiverClaim(
                id: r.id.uuidString,
                leagueID: r.leagueId.uuidString,
                teamID: r.teamId.uuidString,
                teamName: teamNames[r.teamId] ?? "Team",
                addPlayerID: r.addPlayerId,
                dropPlayerID: r.dropPlayerId,
                teamPriority: r.teamPriority,
                status: WaiverClaimStatus(rawValue: r.status) ?? .pending,
                failureReason: r.failureReason,
                createdAt: r.createdAt,
                processedAt: r.processedAt
            )
        }
    }

    func transactions(leagueID: String, limit: Int = 100) async throws -> [LeagueTransaction] {
        guard let uuid = UUID(uuidString: leagueID) else { return [] }
        let rows: [TransactionRow] = (try? await client.from("transactions")
            .select()
            .eq("league_id", value: uuid)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value) ?? []
        let teamNames = try await teamNameMap(leagueID: uuid)
        return rows.map { r in
            LeagueTransaction(
                id: r.id.uuidString,
                leagueID: r.leagueId.uuidString,
                teamID: r.teamId.uuidString,
                teamName: teamNames[r.teamId] ?? "Team",
                kind: TransactionKind(rawValue: r.kind) ?? .add,
                addPlayerID: r.addPlayerId,
                dropPlayerID: r.dropPlayerId,
                status: TransactionStatus(rawValue: r.status) ?? .completed,
                note: r.note,
                createdAt: r.createdAt,
                resolvedAt: r.resolvedAt
            )
        }
    }

    private func teamNameMap(leagueID: UUID) async throws -> [UUID: String] {
        let rows: [TeamRow] = (try? await client.from("teams")
            .select()
            .eq("league_id", value: leagueID)
            .execute()
            .value) ?? []
        var out: [UUID: String] = [:]
        for r in rows { out[r.id] = r.name }
        return out
    }

    // Instant free-agent add (when player is NOT on waivers). If
    // commissioner_approval is on, this writes the transaction with status
    // pending_approval and does NOT mutate the roster yet — the commissioner
    // approves it via approveTransaction later.
    @discardableResult
    func addFreeAgent(
        league: League,
        team: FantasyTeam,
        addPlayerID: String,
        dropPlayerID: String?
    ) async throws -> League? {
        // Build updated roster.
        var roster = team.roster
        if let drop = dropPlayerID {
            roster.removeAll { $0 == drop }
        }
        if !roster.contains(addPlayerID) { roster.append(addPlayerID) }
        guard roster.count <= league.rosterConfig.totalSize else {
            throw RemoteError.rosterFull
        }

        if league.waiverSettings.commissionerApproval && league.creatorID != team.ownerID {
            // Hold the transaction pending — do not mutate roster yet.
            try await insertTransaction(
                leagueID: league.id, teamID: team.id,
                kind: dropPlayerID == nil ? .add : .addDrop,
                addPlayerID: addPlayerID, dropPlayerID: dropPlayerID,
                status: .pendingApproval, note: nil
            )
            return try await self.league(id: league.id)
        }

        // Apply roster mutation + log transaction + (if a drop) start waiver
        // period for the dropped player.
        _ = try await setRoster(teamID: team.id, roster: roster, starters: [])
        if let drop = dropPlayerID {
            try await registerDrop(leagueID: league.id, playerID: drop,
                                   periodHours: league.waiverSettings.periodHours)
        }
        try await insertTransaction(
            leagueID: league.id, teamID: team.id,
            kind: dropPlayerID == nil ? .add : .addDrop,
            addPlayerID: addPlayerID, dropPlayerID: dropPlayerID,
            status: .completed, note: nil
        )
        return try await self.league(id: league.id)
    }

    @discardableResult
    func dropPlayer(league: League, team: FantasyTeam, playerID: String) async throws -> League? {
        var roster = team.roster
        roster.removeAll { $0 == playerID }
        _ = try await setRoster(teamID: team.id, roster: roster, starters: [])
        try await registerDrop(leagueID: league.id, playerID: playerID,
                               periodHours: league.waiverSettings.periodHours)
        try await insertTransaction(
            leagueID: league.id, teamID: team.id,
            kind: .drop, addPlayerID: nil, dropPlayerID: playerID,
            status: .completed, note: nil
        )
        return try await self.league(id: league.id)
    }

    @discardableResult
    func submitWaiverClaim(
        leagueID: String, teamID: String,
        addPlayerID: String, dropPlayerID: String?
    ) async throws -> WaiverClaim? {
        guard let lid = UUID(uuidString: leagueID),
              let tid = UUID(uuidString: teamID) else { return nil }
        // Auto-assign team priority as (current pending count + 1).
        let existing: [WaiverClaimRow] = (try? await client.from("waiver_claims")
            .select()
            .eq("team_id", value: tid)
            .eq("status", value: "pending")
            .execute()
            .value) ?? []
        let nextPriority = existing.count + 1

        struct ClaimInsert: Encodable {
            let league_id: UUID
            let team_id: UUID
            let add_player_id: String
            let drop_player_id: String?
            let team_priority: Int
        }
        let inserted: WaiverClaimRow = try await client.from("waiver_claims")
            .insert(ClaimInsert(
                league_id: lid, team_id: tid,
                add_player_id: addPlayerID, drop_player_id: dropPlayerID,
                team_priority: nextPriority
            ))
            .select()
            .single()
            .execute()
            .value
        return WaiverClaim(
            id: inserted.id.uuidString,
            leagueID: inserted.leagueId.uuidString,
            teamID: inserted.teamId.uuidString,
            teamName: "",
            addPlayerID: inserted.addPlayerId,
            dropPlayerID: inserted.dropPlayerId,
            teamPriority: inserted.teamPriority,
            status: WaiverClaimStatus(rawValue: inserted.status) ?? .pending,
            failureReason: inserted.failureReason,
            createdAt: inserted.createdAt,
            processedAt: inserted.processedAt
        )
    }

    func cancelWaiverClaim(_ id: String) async throws {
        guard let cid = UUID(uuidString: id) else { return }
        try await client.from("waiver_claims")
            .delete()
            .eq("id", value: cid)
            .execute()
    }

    func reorderWaiverClaims(teamID: String, claimIDsInOrder: [String]) async throws {
        guard UUID(uuidString: teamID) != nil else { return }
        struct PriorityUpdate: Encodable { let team_priority: Int }
        for (idx, claimID) in claimIDsInOrder.enumerated() {
            guard let cid = UUID(uuidString: claimID) else { continue }
            _ = try? await client.from("waiver_claims")
                .update(PriorityUpdate(team_priority: idx + 1))
                .eq("id", value: cid)
                .execute()
        }
    }

    // Commissioner approves a pending transaction: apply the roster change,
    // log the drop on waivers, mark transaction completed.
    @discardableResult
    func approveTransaction(_ txID: String, commissionerID: String) async throws -> League? {
        guard let tid = UUID(uuidString: txID),
              let cuid = UUID(uuidString: commissionerID) else { return nil }
        let tx: TransactionRow = try await client.from("transactions")
            .select()
            .eq("id", value: tid)
            .single()
            .execute()
            .value
        let team: TeamRow = try await client.from("teams")
            .select()
            .eq("id", value: tx.teamId)
            .single()
            .execute()
            .value
        let league: LeagueRow = try await client.from("leagues")
            .select()
            .eq("id", value: tx.leagueId)
            .single()
            .execute()
            .value

        var roster = team.roster
        if let drop = tx.dropPlayerId { roster.removeAll { $0 == drop } }
        if let add = tx.addPlayerId, !roster.contains(add) { roster.append(add) }
        _ = try await setRoster(teamID: team.id.uuidString, roster: roster, starters: [])
        if let drop = tx.dropPlayerId {
            try await registerDrop(leagueID: league.id.uuidString, playerID: drop,
                                   periodHours: league.waiverPeriodHours)
        }

        struct StatusUpdate: Encodable {
            let status: String
            let resolved_at: Date
            let resolved_by: UUID
        }
        _ = try await client.from("transactions")
            .update(StatusUpdate(status: TransactionStatus.completed.rawValue,
                                 resolved_at: Date(), resolved_by: cuid))
            .eq("id", value: tid)
            .execute()
        return try await self.league(id: league.id.uuidString)
    }

    func rejectTransaction(_ txID: String, commissionerID: String, note: String?) async throws {
        guard let tid = UUID(uuidString: txID),
              let cuid = UUID(uuidString: commissionerID) else { return }
        struct StatusUpdate: Encodable {
            let status: String
            let resolved_at: Date
            let resolved_by: UUID
            let note: String?
        }
        _ = try await client.from("transactions")
            .update(StatusUpdate(status: TransactionStatus.rejected.rawValue,
                                 resolved_at: Date(), resolved_by: cuid,
                                 note: note))
            .eq("id", value: tid)
            .execute()
    }

    @discardableResult
    func updateLeague(
        leagueID: String,
        name: String,
        scoring: Scoring,
        rosterConfig: RosterConfig,
        playoffTeams: Int,
        playoffReseed: Bool,
        scoringSettings: ScoringSettings?,
        divisionNames: [String]
    ) async throws -> League? {
        guard let uuid = UUID(uuidString: leagueID) else { return nil }
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        let cleanedDivisions = divisionNames
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        struct LeagueUpdate: Encodable {
            let name: String
            let scoring: String
            let roster_config: AnyJSON
            let playoff_teams: Int
            let playoff_reseed: Bool
            // .null clears custom scoring back to the named preset.
            let scoring_settings: AnyJSON
            let division_names: AnyJSON
        }
        _ = try await client.from("leagues")
            .update(LeagueUpdate(
                name: cleaned.isEmpty ? "Untitled League" : cleaned,
                scoring: scoring.rawValue,
                roster_config: rosterConfigAsAnyJSON(rosterConfig),
                playoff_teams: max(0, playoffTeams),
                playoff_reseed: playoffReseed,
                scoring_settings: scoringSettings.map(scoringSettingsAsAnyJSON) ?? .null,
                division_names: stringsAsAnyJSON(cleanedDivisions)
            ))
            .eq("id", value: uuid)
            .execute()
        return try await self.league(id: leagueID)
    }

    // Assigns a single team to a division index (nil clears it). Used by the
    // settings screen when the commish edits divisions after creation.
    @discardableResult
    func setTeamDivision(teamID: String, division: Int?) async throws -> League? {
        guard let uuid = UUID(uuidString: teamID) else { return nil }
        struct DivUpdate: Encodable { let division: Int? }
        let updated: TeamRow = try await client.from("teams")
            .update(DivUpdate(division: division))
            .eq("id", value: uuid)
            .select()
            .single()
            .execute()
            .value
        return try await self.league(id: updated.leagueId.uuidString)
    }

    @discardableResult
    func renameTeam(teamID: String, name: String) async throws -> League? {
        guard let uuid = UUID(uuidString: teamID) else { return nil }
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        struct NameUpdate: Encodable { let name: String }
        let updated: TeamRow = try await client.from("teams")
            .update(NameUpdate(name: cleaned.isEmpty ? "Team" : cleaned))
            .eq("id", value: uuid)
            .select()
            .single()
            .execute()
            .value
        return try await self.league(id: updated.leagueId.uuidString)
    }

    // Commissioner action: clears owner_id so the team becomes claimable
    // again. Roster + schedule are preserved so the new owner inherits
    // matchups in progress.
    @discardableResult
    func kickTeamOwner(teamID: String) async throws -> League? {
        guard let uuid = UUID(uuidString: teamID) else { return nil }
        struct OwnerClear: Encodable { let owner_id: UUID? }
        let updated: TeamRow = try await client.from("teams")
            .update(OwnerClear(owner_id: nil))
            .eq("id", value: uuid)
            .select()
            .single()
            .execute()
            .value
        return try await self.league(id: updated.leagueId.uuidString)
    }

    @discardableResult
    func updateWaiverSettings(
        leagueID: String,
        settings: WaiverSettings,
        priority: [String]
    ) async throws -> League? {
        guard let uuid = UUID(uuidString: leagueID) else { return nil }
        struct SettingsUpdate: Encodable {
            let waiver_process_day: Int
            let waiver_process_hour: Int
            let waiver_period_hours: Int
            let commissioner_approval: Bool
            let waiver_priority: [String]
        }
        _ = try await client.from("leagues")
            .update(SettingsUpdate(
                waiver_process_day: settings.processDay,
                waiver_process_hour: settings.processHour,
                waiver_period_hours: settings.periodHours,
                commissioner_approval: settings.commissionerApproval,
                waiver_priority: priority
            ))
            .eq("id", value: uuid)
            .execute()
        return try await self.league(id: leagueID)
    }

    // MARK: - Drafts

    func draft(leagueID: String) async throws -> Draft? {
        guard let uuid = UUID(uuidString: leagueID) else { return nil }
        let row: DraftRow? = try? await client.from("drafts")
            .select()
            .eq("league_id", value: uuid)
            .single()
            .execute()
            .value
        return row.map(Self.toDraft)
    }

    func draftPicks(draftID: String) async throws -> [DraftPick] {
        guard let uuid = UUID(uuidString: draftID) else { return [] }
        let rows: [DraftPickRow] = (try? await client.from("draft_picks")
            .select()
            .eq("draft_id", value: uuid)
            .order("pick_number", ascending: true)
            .execute()
            .value) ?? []
        return rows.map(Self.toPick)
    }

    @discardableResult
    func upsertDraft(
        leagueID: String,
        format: DraftFormat,
        pickSeconds: Int,
        startsAt: Date,
        pickOrder: [String],
        rosterSize: Int
    ) async throws -> Draft? {
        guard let lid = UUID(uuidString: leagueID) else { return nil }
        let totalPicks = max(0, rosterSize * pickOrder.count)

        // If a draft already exists for this league and isn't complete, update
        // it in place; otherwise insert a fresh row.
        let existing: DraftRow? = try? await client.from("drafts")
            .select()
            .eq("league_id", value: lid)
            .single()
            .execute()
            .value

        if let existing, existing.status != DraftStatus.complete.rawValue {
            struct DraftUpdate: Encodable {
                let format: String
                let pick_seconds: Int
                let starts_at: Date
                let pick_order: [String]
                let total_picks: Int
            }
            let updated: DraftRow = try await client.from("drafts")
                .update(DraftUpdate(
                    format: format.rawValue,
                    pick_seconds: pickSeconds,
                    starts_at: startsAt,
                    pick_order: pickOrder,
                    total_picks: totalPicks
                ))
                .eq("id", value: existing.id)
                .select()
                .single()
                .execute()
                .value
            return Self.toDraft(updated)
        } else {
            struct DraftInsert: Encodable {
                let league_id: UUID
                let format: String
                let pick_seconds: Int
                let starts_at: Date
                let pick_order: [String]
                let total_picks: Int
            }
            let inserted: DraftRow = try await client.from("drafts")
                .insert(DraftInsert(
                    league_id: lid,
                    format: format.rawValue,
                    pick_seconds: pickSeconds,
                    starts_at: startsAt,
                    pick_order: pickOrder,
                    total_picks: totalPicks
                ))
                .select()
                .single()
                .execute()
                .value
            return Self.toDraft(inserted)
        }
    }

    @discardableResult
    func startDraft(draftID: String) async throws -> Draft? {
        guard let uuid = UUID(uuidString: draftID) else { return nil }
        struct Args: Encodable { let p_draft_id: UUID }
        let row: DraftRow = try await client.rpc("start_draft", params: Args(p_draft_id: uuid))
            .execute()
            .value
        return Self.toDraft(row)
    }

    @discardableResult
    func pauseDraft(draftID: String) async throws -> Draft? {
        guard let uuid = UUID(uuidString: draftID) else { return nil }
        struct Args: Encodable { let p_draft_id: UUID }
        let row: DraftRow = try await client.rpc("pause_draft", params: Args(p_draft_id: uuid))
            .execute()
            .value
        return Self.toDraft(row)
    }

    @discardableResult
    func resumeDraft(draftID: String) async throws -> Draft? {
        guard let uuid = UUID(uuidString: draftID) else { return nil }
        struct Args: Encodable { let p_draft_id: UUID }
        let row: DraftRow = try await client.rpc("resume_draft", params: Args(p_draft_id: uuid))
            .execute()
            .value
        return Self.toDraft(row)
    }

    @discardableResult
    func setAutoPick(draftID: String, teamID: String, enabled: Bool) async throws -> Draft? {
        guard let did = UUID(uuidString: draftID),
              let tid = UUID(uuidString: teamID) else { return nil }
        struct Args: Encodable {
            let p_draft_id: UUID
            let p_team_id: UUID
            let p_enabled: Bool
        }
        let row: DraftRow = try await client.rpc("set_auto_pick", params: Args(
            p_draft_id: did, p_team_id: tid, p_enabled: enabled
        )).execute().value
        return Self.toDraft(row)
    }

    @discardableResult
    func makePick(
        draftID: String, teamID: String, playerID: String, auto: Bool = false
    ) async throws -> Draft? {
        guard let did = UUID(uuidString: draftID),
              let tid = UUID(uuidString: teamID) else { return nil }
        struct Args: Encodable {
            let p_draft_id: UUID
            let p_team_id: UUID
            let p_player_id: String
            let p_is_auto: Bool
        }
        let row: DraftRow = try await client.rpc("make_pick", params: Args(
            p_draft_id: did, p_team_id: tid, p_player_id: playerID, p_is_auto: auto
        )).execute().value
        return Self.toDraft(row)
    }

    // MARK: - Draft queues

    // Returns the team owner's queued player IDs in pick order.
    func draftQueue(draftID: String, teamID: String) async -> [String] {
        guard let did = UUID(uuidString: draftID),
              let tid = UUID(uuidString: teamID) else { return [] }
        struct Row: Decodable {
            let playerId: String; let position: Int
            enum CodingKeys: String, CodingKey {
                case position
                case playerId = "player_id"
            }
        }
        let rows: [Row] = (try? await client.from("draft_queues")
            .select("player_id, position")
            .eq("draft_id", value: did)
            .eq("team_id",  value: tid)
            .order("position", ascending: true)
            .execute().value) ?? []
        return rows.map(\.playerId)
    }

    func queueAdd(draftID: String, teamID: String, playerID: String) async throws {
        guard let did = UUID(uuidString: draftID),
              let tid = UUID(uuidString: teamID) else { return }
        struct Args: Encodable {
            let p_draft_id: UUID; let p_team_id: UUID; let p_player_id: String
        }
        _ = try await client.rpc("queue_add", params: Args(
            p_draft_id: did, p_team_id: tid, p_player_id: playerID
        )).execute()
    }

    func queueRemove(draftID: String, teamID: String, playerID: String) async throws {
        guard let did = UUID(uuidString: draftID),
              let tid = UUID(uuidString: teamID) else { return }
        struct Args: Encodable {
            let p_draft_id: UUID; let p_team_id: UUID; let p_player_id: String
        }
        _ = try await client.rpc("queue_remove", params: Args(
            p_draft_id: did, p_team_id: tid, p_player_id: playerID
        )).execute()
    }

    func queueReorder(draftID: String, teamID: String, playerIDs: [String]) async throws {
        guard let did = UUID(uuidString: draftID),
              let tid = UUID(uuidString: teamID) else { return }
        struct Args: Encodable {
            let p_draft_id: UUID; let p_team_id: UUID; let p_player_ids: [String]
        }
        _ = try await client.rpc("queue_reorder", params: Args(
            p_draft_id: did, p_team_id: tid, p_player_ids: playerIDs
        )).execute()
    }

    private static func toDraft(_ r: DraftRow) -> Draft {
        Draft(
            id: r.id.uuidString,
            leagueID: r.leagueId.uuidString,
            format: DraftFormat(rawValue: r.format) ?? .snake,
            status: DraftStatus(rawValue: r.status) ?? .scheduled,
            pickSeconds: r.pickSeconds,
            startsAt: r.startsAt,
            startedAt: r.startedAt,
            completedAt: r.completedAt,
            currentPick: r.currentPick,
            totalPicks: r.totalPicks,
            pickDeadline: r.pickDeadline,
            pickOrder: r.pickOrder,
            pausedRemaining: r.pausedRemaining,
            autoPickTeamIDs: r.autoPickTeamIds
        )
    }

    private static func toPick(_ r: DraftPickRow) -> DraftPick {
        DraftPick(
            id: r.id.uuidString,
            draftID: r.draftId.uuidString,
            pickNumber: r.pickNumber,
            teamID: r.teamId.uuidString,
            playerID: r.playerId,
            autoPick: r.autoPick,
            pickedAt: r.pickedAt
        )
    }

    // MARK: - Trades

    func trades(leagueID: String) async throws -> [Trade] {
        guard let uuid = UUID(uuidString: leagueID) else { return [] }
        let rows: [TradeRow] = (try? await client.from("trades")
            .select()
            .eq("league_id", value: uuid)
            .order("created_at", ascending: false)
            .execute()
            .value) ?? []
        return rows.map(Self.toTrade)
    }

    func tradeVotes(tradeID: String) async throws -> [TradeVote] {
        guard let uuid = UUID(uuidString: tradeID) else { return [] }
        let rows: [TradeVoteRow] = (try? await client.from("trade_votes")
            .select()
            .eq("trade_id", value: uuid)
            .execute()
            .value) ?? []
        return rows.map {
            TradeVote(
                tradeID: $0.tradeId.uuidString,
                teamID: $0.teamId.uuidString,
                vote: $0.vote,
                votedAt: $0.votedAt
            )
        }
    }

    @discardableResult
    func proposeTrade(
        leagueID: String,
        proposerTeamID: String,
        recipientTeamID: String,
        proposerPlayerIDs: [String],
        recipientPlayerIDs: [String],
        note: String?,
        parentTradeID: String? = nil
    ) async throws -> Trade? {
        guard let lid = UUID(uuidString: leagueID),
              let pid = UUID(uuidString: proposerTeamID),
              let rid = UUID(uuidString: recipientTeamID) else { return nil }
        struct Args: Encodable {
            let p_league_id: UUID
            let p_proposer_team_id: UUID
            let p_recipient_team_id: UUID
            let p_proposer_player_ids: [String]
            let p_recipient_player_ids: [String]
            let p_note: String?
            let p_parent_trade_id: UUID?
        }
        let row: TradeRow = try await client.rpc("propose_trade", params: Args(
            p_league_id: lid,
            p_proposer_team_id: pid,
            p_recipient_team_id: rid,
            p_proposer_player_ids: proposerPlayerIDs,
            p_recipient_player_ids: recipientPlayerIDs,
            p_note: note,
            p_parent_trade_id: parentTradeID.flatMap { UUID(uuidString: $0) }
        )).execute().value
        return Self.toTrade(row)
    }

    @discardableResult
    func acceptTrade(_ tradeID: String) async throws -> Trade? {
        try await callTradeRPC("accept_trade", tradeID: tradeID)
    }

    @discardableResult
    func rejectTrade(_ tradeID: String) async throws -> Trade? {
        try await callTradeRPC("reject_trade", tradeID: tradeID)
    }

    @discardableResult
    func cancelTrade(_ tradeID: String) async throws -> Trade? {
        try await callTradeRPC("cancel_trade", tradeID: tradeID)
    }

    @discardableResult
    func commishResolveTrade(_ tradeID: String, approve: Bool, note: String?) async throws -> Trade? {
        guard let uuid = UUID(uuidString: tradeID) else { return nil }
        struct Args: Encodable {
            let p_trade_id: UUID
            let p_approve: Bool
            let p_note: String?
        }
        let row: TradeRow = try await client.rpc("commish_resolve_trade",
                                                  params: Args(p_trade_id: uuid, p_approve: approve, p_note: note))
            .execute().value
        return Self.toTrade(row)
    }

    @discardableResult
    func voteTrade(_ tradeID: String, vote: String) async throws -> Trade? {
        guard let uuid = UUID(uuidString: tradeID) else { return nil }
        struct Args: Encodable {
            let p_trade_id: UUID
            let p_vote: String
        }
        let row: TradeRow = try await client.rpc("vote_trade",
                                                  params: Args(p_trade_id: uuid, p_vote: vote))
            .execute().value
        return Self.toTrade(row)
    }

    // MARK: - Trending players (MFL market-wide snapshot)

    func trendingPlayers() async -> [TrendingPlayer] {
        struct Row: Decodable {
            let playerId: String
            let addsPct: Double
            let dropsPct: Double
            enum CodingKeys: String, CodingKey {
                case playerId  = "player_id"
                case addsPct   = "adds_pct"
                case dropsPct  = "drops_pct"
            }
        }
        let rows: [Row] = (try? await client.from("trending_players")
            .select("player_id, adds_pct, drops_pct")
            .execute().value) ?? []
        return rows.map { TrendingPlayer(playerID: $0.playerId, adds: $0.addsPct, drops: $0.dropsPct) }
    }

    // MARK: - Trending (historical)

    // Per-(season, week) trending — what % of MFL leagues added / dropped
    // each player during that week. Used by simulations so the bot reacts
    // to the same waiver signal real managers saw at the time.
    func trendingPlayers(season: Int, week: Int) async -> [TrendingPlayer] {
        struct Row: Decodable {
            let playerId: String
            let addsPct: Double
            let dropsPct: Double
            enum CodingKeys: String, CodingKey {
                case playerId = "player_id"
                case addsPct  = "adds_pct"
                case dropsPct = "drops_pct"
            }
        }
        let rows: [Row] = (try? await client.from("trending_history")
            .select("player_id, adds_pct, drops_pct")
            .eq("season", value: season)
            .eq("week",   value: week)
            .execute().value) ?? []
        return rows.map { TrendingPlayer(playerID: $0.playerId, adds: $0.addsPct, drops: $0.dropsPct) }
    }

    // MARK: - Injuries (MFL snapshot)

    // Map keyed by nflverse player_id for fast row-level lookup. Healthy
    // players are absent from the map.
    func injuries() async -> [String: Injury] {
        struct Row: Decodable {
            let playerId: String
            let status: String
            let details: String?
            let expectedReturn: String?
            enum CodingKeys: String, CodingKey {
                case status, details
                case playerId        = "player_id"
                case expectedReturn  = "expected_return"
            }
        }
        let rows: [Row] = (try? await client.from("injuries")
            .select("player_id, status, details, expected_return")
            .execute().value) ?? []
        let df = Self.plainDate
        var out: [String: Injury] = [:]
        out.reserveCapacity(rows.count)
        for r in rows {
            out[r.playerId] = Injury(
                playerID: r.playerId, status: r.status, details: r.details,
                expectedReturn: r.expectedReturn.flatMap(df.date(from:))
            )
        }
        return out
    }

    // Historical injury snapshot for (season, week). Used by simulations so
    // injury context matches what real managers had at the time.
    func injuries(season: Int, week: Int) async -> [String: Injury] {
        struct Row: Decodable {
            let playerId: String
            let status: String
            let details: String?
            let expectedReturn: String?
            enum CodingKeys: String, CodingKey {
                case status, details
                case playerId       = "player_id"
                case expectedReturn = "expected_return"
            }
        }
        let rows: [Row] = (try? await client.from("injury_history")
            .select("player_id, status, details, expected_return")
            .eq("season", value: season)
            .eq("week",   value: week)
            .execute().value) ?? []
        let df = Self.plainDate
        var out: [String: Injury] = [:]
        out.reserveCapacity(rows.count)
        for r in rows {
            out[r.playerId] = Injury(
                playerID: r.playerId, status: r.status, details: r.details,
                expectedReturn: r.expectedReturn.flatMap(df.date(from:))
            )
        }
        return out
    }

    private static let plainDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - App-wide settings (admin-controlled flags)

    func boolSetting(_ key: String) async -> Bool? {
        struct Row: Decodable { let value: AnyJSON }
        let row: Row? = try? await client.from("app_settings")
            .select("value")
            .eq("key", value: key)
            .single()
            .execute()
            .value
        guard case .bool(let b) = row?.value else { return nil }
        return b
    }

    @discardableResult
    func setBoolSetting(_ key: String, value: Bool, userID: String? = nil) async throws -> Bool {
        struct Upsert: Encodable {
            let key: String
            let value: AnyJSON
            let updated_at: Date
            let updated_by: UUID?
        }
        _ = try await client.from("app_settings")
            .upsert(Upsert(
                key: key, value: .bool(value),
                updated_at: Date(),
                updated_by: userID.flatMap { UUID(uuidString: $0) }
            ))
            .execute()
        return value
    }

    // MARK: - Testing Environment: snapshots + resets

    func snapshotTeams(leagueID: String, week: Int) async throws {
        guard let uuid = UUID(uuidString: leagueID) else { return }
        struct Args: Encodable { let p_league_id: UUID; let p_week: Int }
        _ = try await client.rpc("snapshot_teams",
                                  params: Args(p_league_id: uuid, p_week: week))
            .execute()
    }

    @discardableResult
    func resetPeriod(leagueID: String) async throws -> League? {
        guard let uuid = UUID(uuidString: leagueID) else { return nil }
        struct Args: Encodable { let p_league_id: UUID }
        _ = try await client.rpc("reset_period", params: Args(p_league_id: uuid))
            .execute()
        return try await self.league(id: leagueID)
    }

    @discardableResult
    func resetAll(leagueID: String) async throws -> League? {
        guard let uuid = UUID(uuidString: leagueID) else { return nil }
        struct Args: Encodable { let p_league_id: UUID }
        _ = try await client.rpc("reset_all", params: Args(p_league_id: uuid))
            .execute()
        return try await self.league(id: leagueID)
    }

    // Mark a freshly-created league as a Testing Environment league.
    func markAsTestLeague(leagueID: String) async throws {
        guard let uuid = UUID(uuidString: leagueID) else { return }
        struct Update: Encodable {
            let is_test: Bool
            let simulated_week: Int
            let trade_deadline: Date?
        }
        _ = try await client.from("leagues")
            .update(Update(is_test: true, simulated_week: 0, trade_deadline: nil))
            .eq("id", value: uuid)
            .execute()
    }

    @discardableResult
    func setSimulatedWeek(leagueID: String, week: Int?) async throws -> League? {
        guard let uuid = UUID(uuidString: leagueID) else { return nil }
        struct Update: Encodable { let simulated_week: Int? }
        _ = try await client.from("leagues")
            .update(Update(simulated_week: week))
            .eq("id", value: uuid)
            .execute()
        return try await self.league(id: leagueID)
    }

    @discardableResult
    func updateTradeSettings(leagueID: String, settings: TradeSettings) async throws -> League? {
        guard let uuid = UUID(uuidString: leagueID) else { return nil }
        struct SettingsUpdate: Encodable {
            let trade_approval: String
            let trade_deadline: Date?
            let trade_vote_hours: Int
        }
        _ = try await client.from("leagues")
            .update(SettingsUpdate(
                trade_approval: settings.approval.rawValue,
                trade_deadline: settings.deadline,
                trade_vote_hours: settings.voteHours
            ))
            .eq("id", value: uuid)
            .execute()
        return try await self.league(id: leagueID)
    }

    // Force a single retry of attempt_execute_trade — used by the Testing
    // Environment's week-advance logic to retry trades held by locked players.
    @discardableResult
    func callTradeRetry(tradeID: String) async throws -> Trade? {
        try await callTradeRPC("attempt_execute_trade", tradeID: tradeID)
    }

    private func callTradeRPC(_ name: String, tradeID: String) async throws -> Trade? {
        guard let uuid = UUID(uuidString: tradeID) else { return nil }
        struct Args: Encodable { let p_trade_id: UUID }
        let row: TradeRow = try await client.rpc(name, params: Args(p_trade_id: uuid))
            .execute().value
        return Self.toTrade(row)
    }

    private static func toTrade(_ r: TradeRow) -> Trade {
        Trade(
            id: r.id.uuidString,
            leagueID: r.leagueId.uuidString,
            proposerTeamID: r.proposerTeamId.uuidString,
            recipientTeamID: r.recipientTeamId.uuidString,
            proposerPlayerIDs: r.proposerPlayerIds,
            recipientPlayerIDs: r.recipientPlayerIds,
            note: r.note,
            parentTradeID: r.parentTradeId?.uuidString,
            status: TradeStatus(rawValue: r.status) ?? .pending,
            votingEndsAt: r.votingEndsAt,
            acceptedAt: r.acceptedAt,
            executedAt: r.executedAt,
            resolvedAt: r.resolvedAt,
            failureReason: r.failureReason,
            createdAt: r.createdAt
        )
    }

    // MARK: - League history (multi-season)

    // Commish-only. Writes the season archive + matchup history, then flips
    // season_completed = true on the league. The standings + matchups are
    // computed app-side from the current league snapshot (so the league's
    // scoring config drives the numbers).
    @discardableResult
    func completeLeagueSeason(
        leagueID: String,
        standings: [StandingsRow],
        scoringLeaderTeamID: String?,
        scoringLeaderTeamName: String?,
        matchups: [LeagueMatchupArchive],
        championTeamID: String? = nil,
        championTeamName: String? = nil
    ) async throws -> League? {
        guard let lid = UUID(uuidString: leagueID) else { return nil }
        guard let league = try await self.league(id: leagueID) else { return nil }

        // Write archive row.
        let standingsJSON: AnyJSON = .array(standings.map { row in
            .object([
                "id":             .string(row.id),
                "name":           .string(row.name),
                "wins":           .integer(row.wins),
                "losses":         .integer(row.losses),
                "ties":           .integer(row.ties),
                "pointsFor":      .double(row.pointsFor),
                "pointsAgainst":  .double(row.pointsAgainst),
                "games":          .integer(row.games),
                "rank":           .integer(row.rank),
            ])
        })
        struct ArchiveArgs: Encodable {
            let p_league_id: UUID
            let p_season: Int
            let p_standings: AnyJSON
            let p_scoring_leader_team_id: UUID?
            let p_scoring_leader_name: String?
            let p_champion_team_id: UUID?
            let p_champion_team_name: String?
        }
        _ = try await client.rpc("write_league_season_archive", params: ArchiveArgs(
            p_league_id: lid,
            p_season: league.season,
            p_standings: standingsJSON,
            p_scoring_leader_team_id: scoringLeaderTeamID.flatMap(UUID.init(uuidString:)),
            p_scoring_leader_name: scoringLeaderTeamName,
            p_champion_team_id: championTeamID.flatMap(UUID.init(uuidString:)),
            p_champion_team_name: championTeamName
        )).execute()

        // Write matchup history.
        let matchupsJSON: AnyJSON = .array(matchups.map { m in
            .object([
                "week":         .integer(m.week),
                "home_team_id": .string(m.homeTeamID),
                "away_team_id": .string(m.awayTeamID),
                "home_user_id": m.homeUserID.map { .string($0) } ?? .string(""),
                "away_user_id": m.awayUserID.map { .string($0) } ?? .string(""),
                "home_points":  .double(m.homePoints),
                "away_points":  .double(m.awayPoints),
            ])
        })
        struct MatchupArgs: Encodable {
            let p_league_id: UUID; let p_season: Int; let p_matchups: AnyJSON
        }
        _ = try await client.rpc("write_league_matchups", params: MatchupArgs(
            p_league_id: lid, p_season: league.season, p_matchups: matchupsJSON
        )).execute()

        // Flip the flag + stamp the champion.
        struct CompleteArgs: Encodable {
            let p_league_id: UUID
            let p_champion_team_id: UUID?
            let p_champion_team_name: String?
        }
        let row: LeagueRow = try await client.rpc("complete_league_season",
            params: CompleteArgs(
                p_league_id: lid,
                p_champion_team_id: championTeamID.flatMap(UUID.init(uuidString:)),
                p_champion_team_name: championTeamName
            )
        ).execute().value
        let fresh = try await self.league(id: row.id.uuidString)
        return fresh
    }

    // Commish-only. Spawns a new child league for the next season. Returns
    // the freshly created child League; teams are NOT cloned — callers can
    // claim teams normally with the new join code.
    func rolloverLeague(parentID: String, newSeason: Int, newName: String?) async throws -> League? {
        guard let pid = UUID(uuidString: parentID) else { return nil }
        struct Args: Encodable {
            let p_parent_id: UUID; let p_new_season: Int; let p_new_name: String
        }
        let row: LeagueRow = try await client.rpc("rollover_league", params: Args(
            p_parent_id: pid, p_new_season: newSeason, p_new_name: newName ?? ""
        )).execute().value
        return try await self.league(id: row.id.uuidString)
    }

    // Walks the parent chain from `leagueID` upward and returns every
    // archived (league, season) snapshot, newest season first.
    func leagueHistory(leagueID: String) async throws -> [LeagueSeasonArchive] {
        // Collect the chain of league_ids: this league + every ancestor.
        var chain: [UUID] = []
        var cursor: String? = leagueID
        while let id = cursor, let uuid = UUID(uuidString: id) {
            chain.append(uuid)
            guard let lg = try await self.league(id: id) else { break }
            cursor = lg.parentLeagueID
        }
        if chain.isEmpty { return [] }

        struct Row: Decodable {
            let id: UUID; let leagueId: UUID; let season: Int
            let standings: AnyJSON
            let scoringLeaderTeamId: UUID?
            let scoringLeaderTeamName: String?
            let championTeamId: UUID?
            let championTeamName: String?
            let archivedAt: Date
            enum CodingKeys: String, CodingKey {
                case id, season, standings
                case leagueId               = "league_id"
                case scoringLeaderTeamId    = "scoring_leader_team_id"
                case scoringLeaderTeamName  = "scoring_leader_team_name"
                case championTeamId         = "champion_team_id"
                case championTeamName       = "champion_team_name"
                case archivedAt             = "archived_at"
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(UUID.self, forKey: .id)
                leagueId = try c.decode(UUID.self, forKey: .leagueId)
                season = try c.decode(Int.self, forKey: .season)
                standings = try c.decode(AnyJSON.self, forKey: .standings)
                scoringLeaderTeamId = try c.decodeIfPresent(UUID.self, forKey: .scoringLeaderTeamId)
                scoringLeaderTeamName = try c.decodeIfPresent(String.self, forKey: .scoringLeaderTeamName)
                championTeamId = try c.decodeIfPresent(UUID.self, forKey: .championTeamId)
                championTeamName = try c.decodeIfPresent(String.self, forKey: .championTeamName)
                archivedAt = try c.decode(Date.self, forKey: .archivedAt)
            }
        }
        let rows: [Row] = (try? await client.from("league_seasons")
            .select()
            .in("league_id", values: chain)
            .order("season", ascending: false)
            .execute().value) ?? []
        return rows.compactMap { r in
            guard case let .array(items) = r.standings else { return nil }
            let standings: [StandingsRow] = items.compactMap { Self.decodeStandingsRow($0) }
            return LeagueSeasonArchive(
                id: r.id.uuidString,
                leagueID: r.leagueId.uuidString,
                season: r.season,
                standings: standings,
                scoringLeaderTeamID: r.scoringLeaderTeamId?.uuidString,
                scoringLeaderTeamName: r.scoringLeaderTeamName,
                championTeamID: r.championTeamId?.uuidString,
                championTeamName: r.championTeamName,
                archivedAt: r.archivedAt
            )
        }
    }

    // All historical matchups between two users in the league chain that
    // contains `leagueID`. Each entry is from `meUserID`'s perspective.
    func headToHead(leagueID: String, meUserID: String, opponentUserID: String) async throws -> [HeadToHeadEntry] {
        // League chain.
        var chain: [UUID] = []
        var cursor: String? = leagueID
        while let id = cursor, let uuid = UUID(uuidString: id) {
            chain.append(uuid)
            guard let lg = try await self.league(id: id) else { break }
            cursor = lg.parentLeagueID
        }
        guard !chain.isEmpty else { return [] }
        guard let me = UUID(uuidString: meUserID),
              let opp = UUID(uuidString: opponentUserID) else { return [] }

        struct Row: Decodable {
            let season: Int; let week: Int
            let homeTeamId: UUID; let awayTeamId: UUID
            let homeUserId: UUID?; let awayUserId: UUID?
            let homePoints: Double; let awayPoints: Double
            enum CodingKeys: String, CodingKey {
                case season, week
                case homeTeamId   = "home_team_id"
                case awayTeamId   = "away_team_id"
                case homeUserId   = "home_user_id"
                case awayUserId   = "away_user_id"
                case homePoints   = "home_points"
                case awayPoints   = "away_points"
            }
        }
        let rows: [Row] = (try? await client.from("league_matchups")
            .select()
            .in("league_id", values: chain)
            .or("and(home_user_id.eq.\(me),away_user_id.eq.\(opp)),and(home_user_id.eq.\(opp),away_user_id.eq.\(me))")
            .order("season", ascending: false)
            .order("week",   ascending: true)
            .execute().value) ?? []

        // Lookup opponent username (one read).
        let oppRow: ProfileRow? = try? await client.from("profiles")
            .select("id, username").eq("id", value: opp)
            .single().execute().value
        let oppName = oppRow?.username

        return rows.map { r in
            let iAmHome = (r.homeUserId == me)
            return HeadToHeadEntry(
                season: r.season, week: r.week,
                myTeamID:       iAmHome ? r.homeTeamId.uuidString : r.awayTeamId.uuidString,
                opponentTeamID: iAmHome ? r.awayTeamId.uuidString : r.homeTeamId.uuidString,
                opponentUsername: oppName,
                myPoints:       iAmHome ? r.homePoints : r.awayPoints,
                opponentPoints: iAmHome ? r.awayPoints : r.homePoints
            )
        }
    }

    // MARK: - Play-by-play (Game Center)

    func plays(gameID: String) async -> [Play] {
        struct Row: Decodable {
            let gameId: String; let playId: Int
            let season: Int; let week: Int
            let posteam: String?; let defteam: String?
            let playType: String?; let description: String?
            let passerPlayerId: String?; let receiverPlayerId: String?
            let rusherPlayerId: String?; let tdPlayerId: String?
            let yardsGained: Double?; let touchdown: Bool?; let epa: Double?
            let qtr: Int?; let down: Int?; let ydstogo: Int?
            let yardline100: Int?
            let posteamScore: Int?; let defteamScore: Int?
            let gameSecondsRemaining: Int?
            let drive: Int?
            let completePass: Bool?; let passAttempt: Bool?; let rushAttempt: Bool?
            let fieldGoalAttempt: Bool?; let fieldGoalResult: String?
            let extraPointAttempt: Bool?; let extraPointResult: String?
            let twoPointAttempt: Bool?
            let interception: Bool?; let fumble: Bool?; let fumbleLost: Bool?
            let firstDown: Bool?; let sack: Bool?
            let penalty: Bool?; let penaltyYards: Int?
            let airYards: Double?; let yardsAfterCatch: Double?
            let passLocation: String?; let runLocation: String?; let runGap: String?
            enum CodingKeys: String, CodingKey {
                case season, week, posteam, defteam, description, qtr, down,
                     ydstogo, drive, interception, fumble, sack, penalty,
                     touchdown, epa
                case gameId               = "game_id"
                case playId               = "play_id"
                case playType             = "play_type"
                case passerPlayerId       = "passer_player_id"
                case receiverPlayerId     = "receiver_player_id"
                case rusherPlayerId       = "rusher_player_id"
                case tdPlayerId           = "td_player_id"
                case yardsGained          = "yards_gained"
                case yardline100          = "yardline_100"
                case posteamScore         = "posteam_score"
                case defteamScore         = "defteam_score"
                case gameSecondsRemaining = "game_seconds_remaining"
                case completePass         = "complete_pass"
                case passAttempt          = "pass_attempt"
                case rushAttempt          = "rush_attempt"
                case fieldGoalAttempt     = "field_goal_attempt"
                case fieldGoalResult      = "field_goal_result"
                case extraPointAttempt    = "extra_point_attempt"
                case extraPointResult     = "extra_point_result"
                case twoPointAttempt      = "two_point_attempt"
                case fumbleLost           = "fumble_lost"
                case firstDown            = "first_down"
                case penaltyYards         = "penalty_yards"
                case airYards             = "air_yards"
                case yardsAfterCatch      = "yards_after_catch"
                case passLocation         = "pass_location"
                case runLocation          = "run_location"
                case runGap               = "run_gap"
            }
        }
        let rows: [Row] = (try? await client.from("plays")
            .select()
            .eq("game_id", value: gameID)
            .order("play_id", ascending: true)
            .execute().value) ?? []
        return rows.map { r in
            Play(
                gameID: r.gameId, playID: r.playId,
                season: r.season, week: r.week,
                posteam: r.posteam, defteam: r.defteam,
                playType: r.playType, description: r.description,
                passerPlayerID: r.passerPlayerId,
                receiverPlayerID: r.receiverPlayerId,
                rusherPlayerID: r.rusherPlayerId,
                tdPlayerID: r.tdPlayerId,
                yardsGained: r.yardsGained,
                touchdown: r.touchdown, epa: r.epa,
                qtr: r.qtr, down: r.down, ydstogo: r.ydstogo,
                yardline100: r.yardline100,
                posteamScore: r.posteamScore, defteamScore: r.defteamScore,
                gameSecondsRemaining: r.gameSecondsRemaining,
                drive: r.drive,
                completePass: r.completePass,
                passAttempt: r.passAttempt, rushAttempt: r.rushAttempt,
                fieldGoalAttempt: r.fieldGoalAttempt,
                fieldGoalResult: r.fieldGoalResult,
                extraPointAttempt: r.extraPointAttempt,
                extraPointResult: r.extraPointResult,
                twoPointAttempt: r.twoPointAttempt,
                interception: r.interception,
                fumble: r.fumble, fumbleLost: r.fumbleLost,
                firstDown: r.firstDown, sack: r.sack,
                penalty: r.penalty, penaltyYards: r.penaltyYards,
                airYards: r.airYards, yardsAfterCatch: r.yardsAfterCatch,
                passLocation: r.passLocation, runLocation: r.runLocation,
                runGap: r.runGap
            )
        }
    }

    // MARK: - League chat

    // Fetches the most-recent `limit` messages for a league, oldest-first so
    // the caller can append directly into a chat transcript. Username comes
    // from a join on profiles. Reactions are embedded via a join on
    // league_message_reactions so the chat opens with full state in one
    // round-trip.
    func messages(leagueID: String, limit: Int = 200) async -> LeagueChatLoad {
        guard let lid = UUID(uuidString: leagueID) else {
            return LeagueChatLoad(messages: [], reactions: [:])
        }
        struct Row: Decodable {
            let id: UUID
            let leagueId: UUID
            let userId: UUID
            let content: String
            let imageUrl: String?
            let createdAt: Date
            let profiles: ProfilesJoin?
            let leagueMessageReactions: [ReactionJoin]?
            enum CodingKeys: String, CodingKey {
                case id, content, profiles
                case leagueId  = "league_id"
                case userId    = "user_id"
                case imageUrl  = "image_url"
                case createdAt = "created_at"
                case leagueMessageReactions = "league_message_reactions"
            }
        }
        struct ProfilesJoin: Decodable { let username: String? }
        struct ReactionJoin: Decodable {
            let userId: UUID
            let emoji: String
            enum CodingKeys: String, CodingKey {
                case emoji
                case userId = "user_id"
            }
        }
        let rows: [Row] = (try? await client.from("league_messages")
            .select("id, league_id, user_id, content, image_url, created_at, profiles!user_id(username), league_message_reactions(user_id, emoji)")
            .eq("league_id", value: lid)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute().value) ?? []

        var messages: [LeagueMessage] = []
        var reactions: [String: [LeagueMessageReaction]] = [:]
        for r in rows.reversed() {
            let mid = r.id.uuidString
            messages.append(LeagueMessage(
                id: mid,
                leagueID: r.leagueId.uuidString,
                userID: r.userId.uuidString,
                username: r.profiles?.username,
                content: r.content,
                imageURL: r.imageUrl,
                createdAt: r.createdAt
            ))
            if let list = r.leagueMessageReactions, !list.isEmpty {
                reactions[mid] = list.map {
                    LeagueMessageReaction(
                        messageID: mid,
                        userID: $0.userId.uuidString,
                        emoji: $0.emoji
                    )
                }
            }
        }
        return LeagueChatLoad(messages: messages, reactions: reactions)
    }

    @discardableResult
    func sendMessage(
        leagueID: String, userID: String, content: String, imageURL: String? = nil
    ) async throws -> LeagueMessage {
        guard let lid = UUID(uuidString: leagueID),
              let uid = UUID(uuidString: userID) else {
            throw RemoteError.invalidUserID
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Image-only posts are allowed; otherwise text must be non-empty.
        guard !trimmed.isEmpty || imageURL != nil else { throw RemoteError.emptyMessage }
        struct Insert: Encodable {
            let league_id: UUID
            let user_id: UUID
            let content: String
            let image_url: String?
        }
        struct Row: Decodable {
            let id: UUID; let leagueId: UUID; let userId: UUID
            let content: String; let imageUrl: String?; let createdAt: Date
            enum CodingKeys: String, CodingKey {
                case id, content
                case leagueId  = "league_id"
                case userId    = "user_id"
                case imageUrl  = "image_url"
                case createdAt = "created_at"
            }
        }
        let row: Row = try await client.from("league_messages")
            .insert(Insert(
                league_id: lid, user_id: uid,
                content: trimmed, image_url: imageURL
            ))
            .select()
            .single()
            .execute().value
        // Username isn't returned by the insert — look it up once (cheap;
        // the chat view also keeps a local cache).
        let profile = try? await fetchProfile(userID: uid)
        return LeagueMessage(
            id: row.id.uuidString, leagueID: row.leagueId.uuidString,
            userID: row.userId.uuidString, username: profile?.username,
            content: row.content, imageURL: row.imageUrl,
            createdAt: row.createdAt
        )
    }

    func deleteMessage(id: String) async throws {
        guard let mid = UUID(uuidString: id) else { return }
        _ = try await client.from("league_messages")
            .delete()
            .eq("id", value: mid)
            .execute()
    }

    // Uploads image data to the chat-images bucket under the league's
    // folder, returning the public URL to embed in the message row. The
    // path layout (<league_id>/<uuid>.<ext>) is what the storage RLS
    // policy parses to gate writes to league members only.
    func uploadChatImage(
        leagueID: String, data: Data, contentType: String
    ) async throws -> String {
        guard let lid = UUID(uuidString: leagueID) else {
            throw RemoteError.invalidUserID
        }
        let ext: String
        switch contentType.lowercased() {
        case "image/png":  ext = "png"
        case "image/gif":  ext = "gif"
        case "image/heic": ext = "heic"
        case "image/webp": ext = "webp"
        default:           ext = "jpg"
        }
        let folder = lid.uuidString.lowercased()
        let filename = "\(UUID().uuidString.lowercased()).\(ext)"
        let path = "\(folder)/\(filename)"
        _ = try await client.storage
            .from("chat-images")
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: contentType, upsert: false)
            )
        let url = try client.storage.from("chat-images").getPublicURL(path: path)
        return url.absoluteString
    }

    // MARK: - Reactions

    // Toggles the caller's reaction on a message: inserts if absent,
    // deletes if already present. Returns the post-toggle state (true =
    // reaction is now applied, false = it was removed).
    @discardableResult
    func toggleReaction(messageID: String, userID: String, emoji: String) async throws -> Bool {
        guard let mid = UUID(uuidString: messageID),
              let uid = UUID(uuidString: userID) else {
            throw RemoteError.invalidUserID
        }
        // Probe first: if our reaction exists, delete it; otherwise insert.
        struct ExistRow: Decodable { let emoji: String }
        let existing: [ExistRow] = (try? await client.from("league_message_reactions")
            .select("emoji")
            .eq("message_id", value: mid)
            .eq("user_id", value: uid)
            .eq("emoji", value: emoji)
            .limit(1)
            .execute().value) ?? []
        if existing.isEmpty {
            struct Insert: Encodable {
                let message_id: UUID; let user_id: UUID; let emoji: String
            }
            _ = try await client.from("league_message_reactions")
                .insert(Insert(message_id: mid, user_id: uid, emoji: emoji))
                .execute()
            return true
        } else {
            _ = try await client.from("league_message_reactions")
                .delete()
                .eq("message_id", value: mid)
                .eq("user_id", value: uid)
                .eq("emoji", value: emoji)
                .execute()
            return false
        }
    }

    // MARK: - Profiles (by ID)

    // Public-facing profile lookup. Returns nil if no row, never throws —
    // used to populate Profile screens for arbitrary userIDs (no RLS gates
    // SELECT on profiles in this app).
    func profile(userID: String) async -> Profile? {
        guard let uid = UUID(uuidString: userID) else { return nil }
        return try? await fetchProfile(userID: uid)
    }

    // Substring search over profiles.username (case-insensitive). Excludes
    // the caller. No RLS gate on SELECT for profiles so this is a simple
    // ilike. Returns at most `limit` rows.
    func searchUsers(query: String, excludingUserID: String, limit: Int = 25) async -> [Profile] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let me = UUID(uuidString: excludingUserID) else { return [] }
        struct Row: Decodable { let id: UUID; let username: String }
        let rows: [Row] = (try? await client.from("profiles")
            .select("id, username")
            .ilike("username", pattern: "%\(trimmed)%")
            .neq("id", value: me)
            .order("username", ascending: true)
            .limit(limit)
            .execute().value) ?? []
        return rows.map { Profile(id: $0.id.uuidString, username: $0.username) }
    }

    // MARK: - Tester role + feedback

    // Admin-only grant/revoke of the tester flag on another profile. The RPC
    // re-checks the caller is an admin server-side, so this can't be abused
    // by a tampered client.
    @discardableResult
    func setTesterRole(userID: String, isTester: Bool) async throws -> Bool {
        guard let uid = UUID(uuidString: userID) else { throw RemoteError.invalidUserID }
        struct Args: Encodable { let p_user: UUID; let p_is_tester: Bool }
        let row: ProfileRow = try await client
            .rpc("set_tester_role", params: Args(p_user: uid, p_is_tester: isTester))
            .execute().value
        return row.isTester
    }

    // Uploads a feedback screenshot into the feedback-images bucket,
    // namespaced by the author's user_id so storage RLS gates the write.
    func uploadFeedbackImage(
        userID: String, data: Data, contentType: String
    ) async throws -> String {
        guard let uid = UUID(uuidString: userID) else { throw RemoteError.invalidUserID }
        let ext: String
        switch contentType.lowercased() {
        case "image/png":  ext = "png"
        case "image/gif":  ext = "gif"
        case "image/heic": ext = "heic"
        case "image/webp": ext = "webp"
        default:           ext = "jpg"
        }
        let folder = uid.uuidString.lowercased()
        let filename = "\(UUID().uuidString.lowercased()).\(ext)"
        let path = "\(folder)/\(filename)"
        _ = try await client.storage
            .from("feedback-images")
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: contentType, upsert: false)
            )
        let url = try client.storage.from("feedback-images").getPublicURL(path: path)
        return url.absoluteString
    }

    @discardableResult
    func submitFeedback(
        userID: String, content: String, imageURLs: [String]
    ) async throws -> FeedbackItem {
        guard let uid = UUID(uuidString: userID) else { throw RemoteError.invalidUserID }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imageURLs.isEmpty else { throw RemoteError.emptyMessage }
        struct Insert: Encodable {
            let user_id: UUID
            let content: String
            let image_urls: [String]
        }
        struct Row: Decodable {
            let id: UUID; let userId: UUID; let content: String
            let imageUrls: [String]; let status: String; let createdAt: Date
            enum CodingKeys: String, CodingKey {
                case id, content, status
                case userId    = "user_id"
                case imageUrls  = "image_urls"
                case createdAt  = "created_at"
            }
        }
        let row: Row = try await client.from("feedback")
            .insert(Insert(user_id: uid, content: trimmed, image_urls: imageURLs))
            .select("id, user_id, content, image_urls, status, created_at")
            .single()
            .execute().value
        return FeedbackItem(
            id: row.id.uuidString, userID: row.userId.uuidString,
            username: "", content: row.content, imageURLs: row.imageUrls,
            status: FeedbackStatus(rawValue: row.status) ?? .open,
            createdAt: row.createdAt
        )
    }

    // Admin triage list. The feedback rows and the authors' usernames are
    // fetched in two plain selects rather than via a PostgREST embed.
    // The embed (`profiles!user_id(username)`) 400s whenever the
    // feedback↔profiles relationship isn't in PostgREST's schema cache, and
    // the `try?` here would swallow that into a permanently empty inbox — so
    // submitted feedback never showed up. Two simple selects can't hit that
    // failure mode. Non-admins are blocked by RLS and get an empty list.
    func feedbackInbox(limit: Int = 200) async -> [FeedbackItem] {
        struct Row: Decodable {
            let id: UUID; let userId: UUID; let content: String
            let imageUrls: [String]; let status: String; let createdAt: Date
            enum CodingKeys: String, CodingKey {
                case id, content, status
                case userId    = "user_id"
                case imageUrls = "image_urls"
                case createdAt = "created_at"
            }
        }
        let rows: [Row] = (try? await client.from("feedback")
            .select("id, user_id, content, image_urls, status, created_at")
            .order("created_at", ascending: false)
            .limit(limit)
            .execute().value) ?? []

        // Resolve author usernames in one batched lookup. A failure here only
        // costs the display name, never the feedback rows themselves.
        let names = await usernames(forIDs: Set(rows.map(\.userId)))

        return rows.map { r in
            FeedbackItem(
                id: r.id.uuidString, userID: r.userId.uuidString,
                username: names[r.userId] ?? "Unknown",
                content: r.content, imageURLs: r.imageUrls,
                status: FeedbackStatus(rawValue: r.status) ?? .open,
                createdAt: r.createdAt
            )
        }
    }

    // Batched username lookup keyed by user id. Profiles have no SELECT RLS
    // gate (see searchUsers), so any authenticated user can resolve these.
    private func usernames(forIDs ids: Set<UUID>) async -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        struct Row: Decodable { let id: UUID; let username: String }
        let rows: [Row] = (try? await client.from("profiles")
            .select("id, username")
            .in("id", values: Array(ids))
            .execute().value) ?? []
        return Dictionary(rows.map { ($0.id, $0.username) }, uniquingKeysWith: { first, _ in first })
    }

    @discardableResult
    func setFeedbackStatus(id: String, status: FeedbackStatus) async throws -> Bool {
        guard let fid = UUID(uuidString: id) else { throw RemoteError.invalidUserID }
        struct Update: Encodable { let status: String }
        _ = try await client.from("feedback")
            .update(Update(status: status.rawValue))
            .eq("id", value: fid)
            .execute()
        return true
    }

    // MARK: - Friendships

    private struct FriendshipRow: Decodable {
        let userA: UUID
        let userB: UUID
        let requestedBy: UUID
        let status: String
        let createdAt: Date
        let acceptedAt: Date?
        enum CodingKeys: String, CodingKey {
            case status
            case userA       = "user_a"
            case userB       = "user_b"
            case requestedBy = "requested_by"
            case createdAt   = "created_at"
            case acceptedAt  = "accepted_at"
        }
    }

    private static func toFriendship(_ r: FriendshipRow) -> Friendship {
        Friendship(
            userA: r.userA.uuidString,
            userB: r.userB.uuidString,
            requestedBy: r.requestedBy.uuidString,
            state: FriendshipState(rawValue: r.status) ?? .pending,
            createdAt: r.createdAt,
            acceptedAt: r.acceptedAt
        )
    }

    func friendships(userID: String) async -> [Friendship] {
        guard let uid = UUID(uuidString: userID) else { return [] }
        let rows: [FriendshipRow] = (try? await client.from("friendships")
            .select("user_a, user_b, requested_by, status, created_at, accepted_at")
            .or("user_a.eq.\(uid.uuidString.lowercased()),user_b.eq.\(uid.uuidString.lowercased())")
            .execute().value) ?? []
        return rows.map(Self.toFriendship)
    }

    @discardableResult
    func sendFriendRequest(otherUserID: String) async throws -> Friendship {
        guard let other = UUID(uuidString: otherUserID) else {
            throw RemoteError.invalidUserID
        }
        struct Args: Encodable { let p_other_user: UUID }
        let row: FriendshipRow = try await client
            .rpc("send_friend_request", params: Args(p_other_user: other))
            .execute().value
        return Self.toFriendship(row)
    }

    @discardableResult
    func acceptFriendRequest(otherUserID: String) async throws -> Friendship {
        guard let other = UUID(uuidString: otherUserID) else {
            throw RemoteError.invalidUserID
        }
        struct Args: Encodable { let p_other_user: UUID }
        let row: FriendshipRow = try await client
            .rpc("accept_friend_request", params: Args(p_other_user: other))
            .execute().value
        return Self.toFriendship(row)
    }

    // Decline or unfriend — same operation, just delete the row.
    func removeFriendship(otherUserID: String, meUserID: String) async throws {
        guard let other = UUID(uuidString: otherUserID),
              let me    = UUID(uuidString: meUserID) else {
            throw RemoteError.invalidUserID
        }
        let (ua, ub) = me.uuidString < other.uuidString ? (me, other) : (other, me)
        _ = try await client.from("friendships")
            .delete()
            .eq("user_a", value: ua)
            .eq("user_b", value: ub)
            .execute()
    }

    // MARK: - Direct messages

    private struct DMThreadRow: Decodable {
        let id: UUID
        let userA: UUID
        let userB: UUID
        let createdAt: Date
        let lastMessageAt: Date?
        enum CodingKeys: String, CodingKey {
            case id
            case userA          = "user_a"
            case userB          = "user_b"
            case createdAt      = "created_at"
            case lastMessageAt  = "last_message_at"
        }
    }

    private static func toDMThread(_ r: DMThreadRow) -> DMThread {
        DMThread(
            id: r.id.uuidString,
            userA: r.userA.uuidString,
            userB: r.userB.uuidString,
            createdAt: r.createdAt,
            lastMessageAt: r.lastMessageAt
        )
    }

    // Returns all DM threads the caller participates in, with the other
    // user's profile inlined so the inbox can render names without a
    // separate fetch per row.
    func dmInbox(userID: String) async -> [DMInboxEntry] {
        guard let uid = UUID(uuidString: userID) else { return [] }
        struct Row: Decodable {
            let id: UUID
            let userA: UUID
            let userB: UUID
            let createdAt: Date
            let lastMessageAt: Date?
            let profilesA: ProfilesJoin?
            let profilesB: ProfilesJoin?
            enum CodingKeys: String, CodingKey {
                case id
                case userA          = "user_a"
                case userB          = "user_b"
                case createdAt      = "created_at"
                case lastMessageAt  = "last_message_at"
                case profilesA      = "profile_a"
                case profilesB      = "profile_b"
            }
        }
        struct ProfilesJoin: Decodable { let id: UUID; let username: String }
        let rows: [Row] = (try? await client.from("dm_threads")
            .select("id, user_a, user_b, created_at, last_message_at, profile_a:profiles!user_a(id,username), profile_b:profiles!user_b(id,username)")
            .or("user_a.eq.\(uid.uuidString.lowercased()),user_b.eq.\(uid.uuidString.lowercased())")
            .execute().value) ?? []
        let me = uid.uuidString
        return rows.compactMap { r -> DMInboxEntry? in
            let thread = DMThread(
                id: r.id.uuidString,
                userA: r.userA.uuidString,
                userB: r.userB.uuidString,
                createdAt: r.createdAt,
                lastMessageAt: r.lastMessageAt
            )
            let otherJoin: ProfilesJoin? = (r.userA.uuidString == me) ? r.profilesB : r.profilesA
            guard let oj = otherJoin else { return nil }
            return DMInboxEntry(
                thread: thread,
                other: Profile(id: oj.id.uuidString, username: oj.username)
            )
        }
    }

    @discardableResult
    func getOrCreateDMThread(otherUserID: String) async throws -> DMThread {
        guard let other = UUID(uuidString: otherUserID) else {
            throw RemoteError.invalidUserID
        }
        struct Args: Encodable { let p_other_user: UUID }
        let row: DMThreadRow = try await client
            .rpc("get_or_create_dm_thread", params: Args(p_other_user: other))
            .execute().value
        return Self.toDMThread(row)
    }

    func dmMessages(threadID: String, limit: Int = 200) async -> [DMMessage] {
        guard let tid = UUID(uuidString: threadID) else { return [] }
        struct Row: Decodable {
            let id: UUID
            let threadId: UUID
            let senderId: UUID
            let content: String
            let imageUrl: String?
            let createdAt: Date
            enum CodingKeys: String, CodingKey {
                case id, content
                case threadId  = "thread_id"
                case senderId  = "sender_id"
                case imageUrl  = "image_url"
                case createdAt = "created_at"
            }
        }
        let rows: [Row] = (try? await client.from("dm_messages")
            .select("id, thread_id, sender_id, content, image_url, created_at")
            .eq("thread_id", value: tid)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute().value) ?? []
        return rows.reversed().map { r in
            DMMessage(
                id: r.id.uuidString,
                threadID: r.threadId.uuidString,
                senderID: r.senderId.uuidString,
                content: r.content,
                imageURL: r.imageUrl,
                createdAt: r.createdAt
            )
        }
    }

    @discardableResult
    func sendDMMessage(
        threadID: String, senderID: String, content: String, imageURL: String? = nil
    ) async throws -> DMMessage {
        guard let tid = UUID(uuidString: threadID),
              let uid = UUID(uuidString: senderID) else {
            throw RemoteError.invalidUserID
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageURL != nil else { throw RemoteError.emptyMessage }
        struct Insert: Encodable {
            let thread_id: UUID
            let sender_id: UUID
            let content: String
            let image_url: String?
        }
        struct Row: Decodable {
            let id: UUID; let threadId: UUID; let senderId: UUID
            let content: String; let imageUrl: String?; let createdAt: Date
            enum CodingKeys: String, CodingKey {
                case id, content
                case threadId  = "thread_id"
                case senderId  = "sender_id"
                case imageUrl  = "image_url"
                case createdAt = "created_at"
            }
        }
        let row: Row = try await client.from("dm_messages")
            .insert(Insert(
                thread_id: tid, sender_id: uid,
                content: trimmed, image_url: imageURL
            ))
            .select()
            .single()
            .execute().value
        return DMMessage(
            id: row.id.uuidString,
            threadID: row.threadId.uuidString,
            senderID: row.senderId.uuidString,
            content: row.content,
            imageURL: row.imageUrl,
            createdAt: row.createdAt
        )
    }

    func deleteDMMessage(id: String) async throws {
        guard let mid = UUID(uuidString: id) else { return }
        _ = try await client.from("dm_messages")
            .delete()
            .eq("id", value: mid)
            .execute()
    }

    // Uploads a DM image into the dm-images bucket, namespaced by
    // thread_id so the storage RLS gates writes to thread participants.
    func uploadDMImage(
        threadID: String, data: Data, contentType: String
    ) async throws -> String {
        guard let tid = UUID(uuidString: threadID) else {
            throw RemoteError.invalidUserID
        }
        let ext: String
        switch contentType.lowercased() {
        case "image/png":  ext = "png"
        case "image/gif":  ext = "gif"
        case "image/heic": ext = "heic"
        case "image/webp": ext = "webp"
        default:           ext = "jpg"
        }
        let folder = tid.uuidString.lowercased()
        let filename = "\(UUID().uuidString.lowercased()).\(ext)"
        let path = "\(folder)/\(filename)"
        _ = try await client.storage
            .from("dm-images")
            .upload(
                path,
                data: data,
                options: FileOptions(contentType: contentType, upsert: false)
            )
        let url = try client.storage.from("dm-images").getPublicURL(path: path)
        return url.absoluteString
    }

    private static func decodeStandingsRow(_ json: AnyJSON) -> StandingsRow? {
        guard case let .object(o) = json else { return nil }
        func str(_ k: String) -> String? {
            if case let .string(s) = o[k] { return s }
            return nil
        }
        func int(_ k: String) -> Int? {
            if case let .integer(i) = o[k] { return i }
            if case let .double(d)  = o[k] { return Int(d) }
            return nil
        }
        func dbl(_ k: String) -> Double? {
            if case let .double(d)  = o[k] { return d }
            if case let .integer(i) = o[k] { return Double(i) }
            return nil
        }
        guard let id = str("id"), let name = str("name") else { return nil }
        return StandingsRow(
            id: id, name: name,
            wins: int("wins") ?? 0,
            losses: int("losses") ?? 0,
            ties: int("ties") ?? 0,
            pointsFor: dbl("pointsFor") ?? 0,
            pointsAgainst: dbl("pointsAgainst") ?? 0,
            games: int("games") ?? 0,
            rank: int("rank") ?? 0
        )
    }

    // MARK: - Internal write helpers

    private func insertTransaction(
        leagueID: String, teamID: String,
        kind: TransactionKind, addPlayerID: String?, dropPlayerID: String?,
        status: TransactionStatus, note: String?
    ) async throws {
        guard let lid = UUID(uuidString: leagueID),
              let tid = UUID(uuidString: teamID) else { return }
        struct TxInsert: Encodable {
            let league_id: UUID
            let team_id: UUID
            let kind: String
            let add_player_id: String?
            let drop_player_id: String?
            let status: String
            let note: String?
        }
        _ = try await client.from("transactions")
            .insert(TxInsert(
                league_id: lid, team_id: tid,
                kind: kind.rawValue,
                add_player_id: addPlayerID,
                drop_player_id: dropPlayerID,
                status: status.rawValue,
                note: note
            ))
            .execute()
    }

    private func registerDrop(leagueID: String, playerID: String, periodHours: Int) async throws {
        guard let lid = UUID(uuidString: leagueID) else { return }
        let now = Date()
        let until = now.addingTimeInterval(TimeInterval(max(periodHours, 0)) * 3600)
        struct DropUpsert: Encodable {
            let league_id: UUID
            let player_id: String
            let dropped_at: Date
            let waiver_until: Date
        }
        _ = try await client.from("dropped_players")
            .upsert(DropUpsert(
                league_id: lid, player_id: playerID,
                dropped_at: now, waiver_until: until
            ))
            .execute()
    }

    enum RemoteError: LocalizedError {
        case invalidUserID, tooFewTeams, tooManyTeams, joinCodeCollision,
             rosterFull, playerLocked, emptyMessage
        var errorDescription: String? {
            switch self {
            case .invalidUserID:     return "Invalid user."
            case .tooFewTeams:       return "A league needs at least 2 teams."
            case .tooManyTeams:      return "A league can have at most 16 teams."
            case .joinCodeCollision: return "Couldn't generate a unique join code. Try again."
            case .rosterFull:        return "Your roster is full — choose a player to drop."
            case .playerLocked:      return "This player's game is in progress and can't be added or dropped."
            case .emptyMessage:      return "Message can't be empty."
            }
        }
    }
}

// MARK: - Database row types (snake_case → camelCase)

struct ProfileRow: Codable, Hashable {
    let id: UUID
    let username: String
    let theme: String?
    let isAdmin: Bool
    let isTester: Bool

    enum CodingKeys: String, CodingKey {
        case id, username, theme
        case isAdmin  = "is_admin"
        case isTester = "is_tester"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self,   forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        theme    = try c.decodeIfPresent(String.self, forKey: .theme)
        isAdmin  = try c.decodeIfPresent(Bool.self, forKey: .isAdmin)  ?? false
        isTester = try c.decodeIfPresent(Bool.self, forKey: .isTester) ?? false
    }
}

struct LeagueRow: Codable, Hashable {
    let id: UUID
    let name: String
    let season: Int
    let scoring: String
    let rosterConfig: RosterConfig
    let schedule: [ScheduleWeek]
    let joinCode: String
    let creatorId: UUID
    let createdAt: Date
    let waiverProcessDay: Int
    let waiverProcessHour: Int
    let waiverPeriodHours: Int
    let commissionerApproval: Bool
    let waiverPriority: [String]
    let lastWaiversRunAt: Date?
    let tradeApproval: String
    let tradeDeadline: Date?
    let tradeVoteHours: Int
    let isTest: Bool
    let simulatedWeek: Int?
    let parentLeagueId: UUID?
    let seasonCompleted: Bool
    let seasonCompletedAt: Date?
    let regularSeasonWeeks: Int?
    let playoffTeams: Int
    let playoffReseed: Bool
    let scoringSettings: ScoringSettings?
    let divisionNames: [String]
    let championTeamId: UUID?
    let championTeamName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, season, scoring, schedule
        case rosterConfig         = "roster_config"
        case joinCode             = "join_code"
        case creatorId            = "creator_id"
        case createdAt            = "created_at"
        case waiverProcessDay     = "waiver_process_day"
        case waiverProcessHour    = "waiver_process_hour"
        case waiverPeriodHours    = "waiver_period_hours"
        case commissionerApproval = "commissioner_approval"
        case waiverPriority       = "waiver_priority"
        case lastWaiversRunAt     = "last_waivers_run_at"
        case tradeApproval        = "trade_approval"
        case tradeDeadline        = "trade_deadline"
        case tradeVoteHours       = "trade_vote_hours"
        case isTest               = "is_test"
        case simulatedWeek        = "simulated_week"
        case parentLeagueId       = "parent_league_id"
        case seasonCompleted      = "season_completed"
        case seasonCompletedAt    = "season_completed_at"
        case regularSeasonWeeks   = "regular_season_weeks"
        case playoffTeams         = "playoff_teams"
        case playoffReseed        = "playoff_reseed"
        case scoringSettings      = "scoring_settings"
        case divisionNames        = "division_names"
        case championTeamId       = "champion_team_id"
        case championTeamName     = "champion_team_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self,            forKey: .id)
        name         = try c.decode(String.self,          forKey: .name)
        season       = try c.decode(Int.self,             forKey: .season)
        scoring      = try c.decode(String.self,          forKey: .scoring)
        rosterConfig = try c.decode(RosterConfig.self,    forKey: .rosterConfig)
        schedule     = try c.decode([ScheduleWeek].self,  forKey: .schedule)
        joinCode     = try c.decode(String.self,          forKey: .joinCode)
        creatorId    = try c.decode(UUID.self,            forKey: .creatorId)
        createdAt    = try c.decode(Date.self,            forKey: .createdAt)
        // Waiver columns are optional on read so a freshly-migrated DB without
        // values, or a pre-migration LeagueRow shape, still decodes cleanly.
        waiverProcessDay     = try c.decodeIfPresent(Int.self,     forKey: .waiverProcessDay)     ?? WaiverSettings.default.processDay
        waiverProcessHour    = try c.decodeIfPresent(Int.self,     forKey: .waiverProcessHour)    ?? WaiverSettings.default.processHour
        waiverPeriodHours    = try c.decodeIfPresent(Int.self,     forKey: .waiverPeriodHours)    ?? WaiverSettings.default.periodHours
        commissionerApproval = try c.decodeIfPresent(Bool.self,    forKey: .commissionerApproval) ?? false
        waiverPriority       = try c.decodeIfPresent([String].self, forKey: .waiverPriority)      ?? []
        lastWaiversRunAt     = try c.decodeIfPresent(Date.self,    forKey: .lastWaiversRunAt)
        tradeApproval        = try c.decodeIfPresent(String.self,  forKey: .tradeApproval)        ?? TradeApprovalMode.none.rawValue
        tradeDeadline        = try c.decodeIfPresent(Date.self,    forKey: .tradeDeadline)
        tradeVoteHours       = try c.decodeIfPresent(Int.self,     forKey: .tradeVoteHours)       ?? 24
        isTest               = try c.decodeIfPresent(Bool.self,    forKey: .isTest)               ?? false
        simulatedWeek        = try c.decodeIfPresent(Int.self,     forKey: .simulatedWeek)
        parentLeagueId       = try c.decodeIfPresent(UUID.self,    forKey: .parentLeagueId)
        seasonCompleted      = try c.decodeIfPresent(Bool.self,    forKey: .seasonCompleted)      ?? false
        seasonCompletedAt    = try c.decodeIfPresent(Date.self,    forKey: .seasonCompletedAt)
        regularSeasonWeeks   = try c.decodeIfPresent(Int.self,     forKey: .regularSeasonWeeks)
        playoffTeams         = try c.decodeIfPresent(Int.self,     forKey: .playoffTeams)         ?? 6
        playoffReseed        = try c.decodeIfPresent(Bool.self,    forKey: .playoffReseed)        ?? true
        scoringSettings      = try c.decodeIfPresent(ScoringSettings.self, forKey: .scoringSettings)
        divisionNames        = try c.decodeIfPresent([String].self, forKey: .divisionNames)       ?? []
        championTeamId       = try c.decodeIfPresent(UUID.self,    forKey: .championTeamId)
        championTeamName     = try c.decodeIfPresent(String.self,  forKey: .championTeamName)
    }
}

struct TeamRow: Codable, Hashable {
    let id: UUID
    let leagueId: UUID
    let name: String
    let ownerId: UUID?
    let roster: [String]
    let starters: [String]
    let sortIndex: Int
    let ir: [String]
    let weeklyLineups: [String: [String]]
    let division: Int?
    let logoUrl: String?
    let colorHex: String?

    enum CodingKeys: String, CodingKey {
        case id, name, roster, starters, ir, division
        case leagueId      = "league_id"
        case ownerId       = "owner_id"
        case sortIndex     = "sort_index"
        case weeklyLineups = "weekly_lineups"
        case logoUrl       = "logo_url"
        case colorHex      = "color_hex"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self, forKey: .id)
        leagueId  = try c.decode(UUID.self, forKey: .leagueId)
        name      = try c.decode(String.self, forKey: .name)
        ownerId   = try c.decodeIfPresent(UUID.self, forKey: .ownerId)
        roster    = try c.decodeIfPresent([String].self, forKey: .roster)   ?? []
        starters  = try c.decodeIfPresent([String].self, forKey: .starters) ?? []
        sortIndex = try c.decodeIfPresent(Int.self, forKey: .sortIndex)     ?? 0
        ir        = try c.decodeIfPresent([String].self, forKey: .ir)       ?? []
        weeklyLineups = try c.decodeIfPresent([String: [String]].self, forKey: .weeklyLineups) ?? [:]
        division  = try c.decodeIfPresent(Int.self, forKey: .division)
        logoUrl   = try c.decodeIfPresent(String.self, forKey: .logoUrl)
        colorHex  = try c.decodeIfPresent(String.self, forKey: .colorHex)
    }
}

struct WaiverClaimRow: Codable, Hashable {
    let id: UUID
    let leagueId: UUID
    let teamId: UUID
    let addPlayerId: String
    let dropPlayerId: String?
    let teamPriority: Int
    let status: String
    let failureReason: String?
    let createdAt: Date
    let processedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status
        case leagueId      = "league_id"
        case teamId        = "team_id"
        case addPlayerId   = "add_player_id"
        case dropPlayerId  = "drop_player_id"
        case teamPriority  = "team_priority"
        case failureReason = "failure_reason"
        case createdAt     = "created_at"
        case processedAt   = "processed_at"
    }
}

struct TransactionRow: Codable, Hashable {
    let id: UUID
    let leagueId: UUID
    let teamId: UUID
    let kind: String
    let addPlayerId: String?
    let dropPlayerId: String?
    let status: String
    let note: String?
    let createdAt: Date
    let resolvedAt: Date?
    let resolvedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id, kind, status, note
        case leagueId     = "league_id"
        case teamId       = "team_id"
        case addPlayerId  = "add_player_id"
        case dropPlayerId = "drop_player_id"
        case createdAt    = "created_at"
        case resolvedAt   = "resolved_at"
        case resolvedBy   = "resolved_by"
    }
}

struct DraftRow: Codable, Hashable {
    let id: UUID
    let leagueId: UUID
    let format: String
    let status: String
    let pickSeconds: Int
    let startsAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let currentPick: Int
    let totalPicks: Int
    let pickDeadline: Date?
    let pickOrder: [String]
    let pausedRemaining: Int?
    let autoPickTeamIds: [String]

    enum CodingKeys: String, CodingKey {
        case id, format, status
        case leagueId         = "league_id"
        case pickSeconds      = "pick_seconds"
        case startsAt         = "starts_at"
        case startedAt        = "started_at"
        case completedAt      = "completed_at"
        case currentPick      = "current_pick"
        case totalPicks       = "total_picks"
        case pickDeadline     = "pick_deadline"
        case pickOrder        = "pick_order"
        case pausedRemaining  = "paused_remaining"
        case autoPickTeamIds  = "auto_pick_team_ids"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self,           forKey: .id)
        leagueId        = try c.decode(UUID.self,           forKey: .leagueId)
        format          = try c.decode(String.self,         forKey: .format)
        status          = try c.decode(String.self,         forKey: .status)
        pickSeconds     = try c.decode(Int.self,            forKey: .pickSeconds)
        startsAt        = try c.decode(Date.self,           forKey: .startsAt)
        startedAt       = try c.decodeIfPresent(Date.self,  forKey: .startedAt)
        completedAt     = try c.decodeIfPresent(Date.self,  forKey: .completedAt)
        currentPick     = try c.decode(Int.self,            forKey: .currentPick)
        totalPicks      = try c.decode(Int.self,            forKey: .totalPicks)
        pickDeadline    = try c.decodeIfPresent(Date.self,  forKey: .pickDeadline)
        pickOrder       = try c.decode([String].self,       forKey: .pickOrder)
        pausedRemaining = try c.decodeIfPresent(Int.self,   forKey: .pausedRemaining)
        autoPickTeamIds = try c.decodeIfPresent([String].self, forKey: .autoPickTeamIds) ?? []
    }
}

struct DraftPickRow: Codable, Hashable {
    let id: UUID
    let draftId: UUID
    let pickNumber: Int
    let teamId: UUID
    let playerId: String
    let autoPick: Bool
    let pickedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case draftId    = "draft_id"
        case pickNumber = "pick_number"
        case teamId     = "team_id"
        case playerId   = "player_id"
        case autoPick   = "auto_pick"
        case pickedAt   = "picked_at"
    }
}

struct TradeRow: Codable, Hashable {
    let id: UUID
    let leagueId: UUID
    let proposerTeamId: UUID
    let recipientTeamId: UUID
    let proposerPlayerIds: [String]
    let recipientPlayerIds: [String]
    let note: String?
    let parentTradeId: UUID?
    let status: String
    let votingEndsAt: Date?
    let acceptedAt: Date?
    let executedAt: Date?
    let resolvedAt: Date?
    let failureReason: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, note, status
        case leagueId            = "league_id"
        case proposerTeamId      = "proposer_team_id"
        case recipientTeamId     = "recipient_team_id"
        case proposerPlayerIds   = "proposer_player_ids"
        case recipientPlayerIds  = "recipient_player_ids"
        case parentTradeId       = "parent_trade_id"
        case votingEndsAt        = "voting_ends_at"
        case acceptedAt          = "accepted_at"
        case executedAt          = "executed_at"
        case resolvedAt          = "resolved_at"
        case failureReason       = "failure_reason"
        case createdAt           = "created_at"
    }
}

struct TradeVoteRow: Codable, Hashable {
    let tradeId: UUID
    let teamId: UUID
    let vote: String
    let votedAt: Date

    enum CodingKeys: String, CodingKey {
        case vote
        case tradeId = "trade_id"
        case teamId  = "team_id"
        case votedAt = "voted_at"
    }
}

struct DroppedPlayerRow: Codable, Hashable {
    let leagueId: UUID
    let playerId: String
    let droppedAt: Date
    let waiverUntil: Date

    enum CodingKeys: String, CodingKey {
        case leagueId    = "league_id"
        case playerId    = "player_id"
        case droppedAt   = "dropped_at"
        case waiverUntil = "waiver_until"
    }
}
