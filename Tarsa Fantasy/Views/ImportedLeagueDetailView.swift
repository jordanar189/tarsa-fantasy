import SwiftUI

// Read-only browser for a league imported from Sleeper. A season switcher up top
// (the league's full history) drives a segmented set of views: standings,
// rosters, weekly scores, transactions, and the draft.
struct ImportedLeagueDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let leagueID: String

    enum Mode: String, CaseIterable, Identifiable {
        case standings, rosters, matchups, transactions, draft
        var id: String { rawValue }
        var label: String {
            switch self {
            case .standings:    return "Standings"
            case .rosters:      return "Rosters"
            case .matchups:     return "Scores"
            case .transactions: return "Moves"
            case .draft:        return "Draft"
            }
        }
    }

    @State private var mode: Mode = .standings
    @State private var selectedSeasonID: String?
    @State private var reimporting = false
    @State private var showingActivate = false

    private var league: ImportedLeague? { app.importedSleeperLeague(id: leagueID) }

    private var season: ImportedSeason? {
        guard let league else { return nil }
        if let id = selectedSeasonID, let s = league.seasons.first(where: { $0.id == id }) { return s }
        return league.seasons.first
    }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            if let league, let season {
                content(league: league, season: season)
            } else {
                Text("This imported league is no longer available.")
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textSecondary)
            }
            if reimporting { reimportOverlay }
        }
        .navigationTitle(league?.name ?? "Imported league")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await reimport() } } label: {
                        Label("Refresh from Sleeper", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        app.deleteImportedSleeperLeague(id: leagueID)
                        dismiss()
                    } label: {
                        Label("Remove import", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(FFColor.textPrimary)
                }
            }
        }
        .sheet(isPresented: $showingActivate) {
            SleeperActivateView(leagueID: leagueID)
        }
    }

    // Banner that turns the read-only archive into a real league. Once
    // promoted, it instead jumps straight to the live league.
    @ViewBuilder
    private func activationBanner(league: ImportedLeague) -> some View {
        if let liveID = league.activatedLeagueID {
            Button {
                Task { await app.selectLeague(liveID) }
            } label: {
                HStack(spacing: FFSpace.m) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(FFColor.positive)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Live in Tarsa").font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                        Text("Open your playable league").font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
                .ffCard(padding: FFSpace.m)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, FFSpace.l)
        } else {
            Button {
                showingActivate = true
            } label: {
                HStack(spacing: FFSpace.m) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(FFGradient.brand, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activate as a live league").font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                        Text("Draft, set lineups & trade in Tarsa").font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
                .ffCard(padding: FFSpace.m)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, FFSpace.l)
        }
    }

    @ViewBuilder
    private func content(league: ImportedLeague, season: ImportedSeason) -> some View {
        VStack(spacing: FFSpace.m) {
            activationBanner(league: league)
            if league.seasons.count > 1 {
                seasonSwitcher(league: league, season: season)
            }
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, FFSpace.l)

            switch mode {
            case .standings:    ImportedStandingsSection(season: season)
            case .rosters:      ImportedRostersSection(season: season)
            case .matchups:     ImportedMatchupsSection(season: season)
            case .transactions: ImportedTransactionsSection(season: season)
            case .draft:        ImportedDraftSection(season: season)
            }
        }
        .padding(.top, FFSpace.s)
    }

    private func seasonSwitcher(league: ImportedLeague, season: ImportedSeason) -> some View {
        Menu {
            ForEach(league.seasons) { s in
                Button {
                    selectedSeasonID = s.id
                } label: {
                    if s.id == season.id {
                        Label(s.season, systemImage: "checkmark")
                    } else {
                        Text(s.season)
                    }
                }
            }
        } label: {
            HStack(spacing: FFSpace.s) {
                Image(systemName: "calendar")
                Text("\(season.season) season")
                    .font(.ffHeadline)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
                Spacer()
                FFPill { Text(season.scoringLabel.uppercased()) }
            }
            .foregroundStyle(FFColor.textPrimary)
            .ffCard(padding: FFSpace.m)
            .padding(.horizontal, FFSpace.l)
        }
    }

    private var reimportOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: FFSpace.m) {
                ProgressView().tint(.white)
                Text("Refreshing…").font(.ffCaption).foregroundStyle(.white)
            }
            .padding(FFSpace.xl)
            .background(FFColor.surfaceElevated, in: RoundedRectangle(cornerRadius: FFRadius.l))
        }
    }

    private func reimport() async {
        reimporting = true
        defer { reimporting = false }
        _ = try? await app.importSleeperLeague(rootLeagueID: leagueID)
    }
}

// MARK: - Shared rows

// One player line, tap-through to the in-app profile when we matched it.
struct ImportedPlayerRow: View {
    let player: ImportedPlayer
    var slot: String? = nil

    var body: some View {
        HStack(spacing: FFSpace.m) {
            if let slot {
                Text(slot)
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textSecondary)
                    .frame(width: 40, alignment: .leading)
            }
            Circle()
                .fill(FFColor.positionTint(player.position))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.name)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                    .lineLimit(1)
                Text(playerMeta)
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
            Spacer()
            if player.appID != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .playerLink(player.appID)
    }

    private var playerMeta: String {
        [player.position, player.team].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Standings

struct ImportedStandingsSection: View {
    let season: ImportedSeason

    var body: some View {
        ScrollView {
            VStack(spacing: FFSpace.s) {
                ForEach(Array(season.standings.enumerated()), id: \.element.rosterID) { idx, team in
                    HStack(spacing: FFSpace.m) {
                        Text("\(idx + 1)")
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.textSecondary)
                            .frame(width: 24)
                        SleeperAvatar(id: team.avatar, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: FFSpace.xs) {
                                Text(team.teamName)
                                    .font(.ffHeadline)
                                    .foregroundStyle(FFColor.textPrimary)
                                    .lineLimit(1)
                                if team.rosterID == season.championRosterID {
                                    Image(systemName: "trophy.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(FFColor.warning)
                                }
                            }
                            Text(team.ownerName)
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(team.record)
                                .font(.ffStatSmall)
                                .foregroundStyle(FFColor.textPrimary)
                            Text("\(fmt(team.pointsFor)) PF")
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                        }
                    }
                    .ffCard(padding: FFSpace.m)
                }
            }
            .padding(FFSpace.l)
        }
    }
}

// MARK: - Rosters

struct ImportedRostersSection: View {
    let season: ImportedSeason
    @State private var selectedRosterID: Int?

    private var team: ImportedTeam? {
        if let id = selectedRosterID, let t = season.teamsByRoster[id] { return t }
        return season.standings.first
    }

    var body: some View {
        VStack(spacing: FFSpace.s) {
            teamPicker
            ScrollView {
                if let team {
                    rosterCard(team)
                        .padding(.horizontal, FFSpace.l)
                        .padding(.bottom, FFSpace.l)
                }
            }
        }
    }

    private var teamPicker: some View {
        Menu {
            ForEach(season.standings) { t in
                Button {
                    selectedRosterID = t.rosterID
                } label: {
                    if t.rosterID == team?.rosterID {
                        Label(t.teamName, systemImage: "checkmark")
                    } else {
                        Text(t.teamName)
                    }
                }
            }
        } label: {
            HStack(spacing: FFSpace.s) {
                SleeperAvatar(id: team?.avatar, size: 24)
                Text(team?.teamName ?? "Select team").font(.ffHeadline)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
                Spacer()
            }
            .foregroundStyle(FFColor.textPrimary)
            .ffCard(padding: FFSpace.m)
            .padding(.horizontal, FFSpace.l)
        }
    }

    private func rosterCard(_ team: ImportedTeam) -> some View {
        let lookup = season.playerLookup   // built once per render, not per row
        let slots = season.starterSlotLabels
        let starters = team.starters
        let benchIDs = team.players.filter { !starters.contains($0) && !team.reserve.contains($0) && !team.taxi.contains($0) }
        let reserveIDs = team.reserve + team.taxi
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack(spacing: FFSpace.s) {
                Text(team.ownerName).font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                Spacer()
                FFPill { Text(team.record) }
                FFPill { Text("\(fmt(team.pointsFor)) PF") }
            }

            Text("Starters").ffEyebrow().padding(.top, FFSpace.xs)
            ForEach(Array(starters.enumerated()), id: \.offset) { idx, pid in
                ImportedPlayerRow(
                    player: resolvedPlayer(pid, lookup),
                    slot: idx < slots.count ? slotLabel(slots[idx]) : nil
                )
                .ffHairlineBottom()
            }

            if !benchIDs.isEmpty {
                Text("Bench").ffEyebrow().padding(.top, FFSpace.s)
                ForEach(benchIDs, id: \.self) { pid in
                    ImportedPlayerRow(player: resolvedPlayer(pid, lookup), slot: "BN").ffHairlineBottom()
                }
            }

            if !reserveIDs.isEmpty {
                Text("IR / Taxi").ffEyebrow().padding(.top, FFSpace.s)
                ForEach(reserveIDs, id: \.self) { pid in
                    ImportedPlayerRow(player: resolvedPlayer(pid, lookup), slot: "IR").ffHairlineBottom()
                }
            }
        }
        .ffCard()
    }

    // Rosters store raw Sleeper ids; bios were resolved at import time into
    // season.players. "0" is Sleeper's empty-slot placeholder. The caller passes
    // the lookup so it's built once per render, not per row.
    private func resolvedPlayer(_ sleeperID: String, _ lookup: [String: ImportedPlayer]) -> ImportedPlayer {
        if sleeperID == "0" {
            return ImportedPlayer(sleeperID: "0", appID: nil, name: "Empty", position: "", team: "")
        }
        return lookup[sleeperID]
            ?? ImportedPlayer(sleeperID: sleeperID, appID: nil, name: sleeperID, position: "", team: "")
    }

    private func slotLabel(_ raw: String) -> String {
        switch raw {
        case "SUPER_FLEX": return "SFLX"
        case "REC_FLEX":   return "RFLX"
        case "WRRB_FLEX":  return "W/R"
        case "FLEX":       return "FLEX"
        case "IDP_FLEX":   return "IDP"
        default:           return raw
        }
    }
}

// MARK: - Matchups

struct ImportedMatchupsSection: View {
    let season: ImportedSeason
    @State private var selectedWeek: Int?

    private var weeks: [Int] { season.weeks }
    private var week: Int { selectedWeek ?? defaultWeek }

    private var defaultWeek: Int {
        let scored = season.matchups.filter { $0.points > 0 }.map(\.week)
        return scored.max() ?? weeks.last ?? 1
    }

    var body: some View {
        VStack(spacing: FFSpace.s) {
            weekPicker
            ScrollView {
                VStack(spacing: FFSpace.s) {
                    ForEach(Array(season.matchupPairs(week: week).enumerated()), id: \.offset) { _, pair in
                        matchupCard(pair.a, pair.b)
                    }
                }
                .padding(FFSpace.l)
            }
        }
    }

    private var weekPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FFSpace.s) {
                ForEach(weeks, id: \.self) { w in
                    Button {
                        selectedWeek = w
                    } label: {
                        Text("W\(w)")
                            .font(.ffCaption)
                            .foregroundStyle(w == week ? .white : FFColor.textSecondary)
                            .padding(.horizontal, FFSpace.m)
                            .padding(.vertical, FFSpace.s)
                            .background(
                                Capsule().fill(w == week ? AnyShapeStyle(FFGradient.brand) : AnyShapeStyle(FFColor.surface))
                            )
                            .overlay(Capsule().strokeBorder(FFColor.border, lineWidth: w == week ? 0 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, FFSpace.l)
        }
    }

    @ViewBuilder
    private func matchupCard(_ a: ImportedMatchup, _ b: ImportedMatchup?) -> some View {
        let teamA = season.teamsByRoster[a.rosterID]
        let teamB = b.flatMap { season.teamsByRoster[$0.rosterID] }
        let aWins = (b != nil) && a.points > (b?.points ?? 0)
        let bWins = (b != nil) && (b?.points ?? 0) > a.points
        VStack(spacing: FFSpace.s) {
            matchupRow(team: teamA, points: a.points, winner: aWins)
            if let b {
                Divider().overlay(FFColor.border)
                matchupRow(team: teamB, points: b.points, winner: bWins)
            } else {
                Text("BYE").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            }
        }
        .ffCard(padding: FFSpace.m)
    }

    private func matchupRow(team: ImportedTeam?, points: Double, winner: Bool) -> some View {
        HStack(spacing: FFSpace.m) {
            SleeperAvatar(id: team?.avatar, size: 28)
            Text(team?.teamName ?? "—")
                .font(.ffBody)
                .foregroundStyle(winner ? FFColor.textPrimary : FFColor.textSecondary)
                .lineLimit(1)
            Spacer()
            Text(fmt(points))
                .font(.ffStatSmall)
                .foregroundStyle(winner ? FFColor.positive : FFColor.textPrimary)
        }
    }
}

// MARK: - Transactions

struct ImportedTransactionsSection: View {
    let season: ImportedSeason

    var body: some View {
        ScrollView {
            LazyVStack(spacing: FFSpace.s) {
                if season.transactions.isEmpty {
                    Text("No transactions recorded for this season.")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textSecondary)
                        .padding(.top, FFSpace.xxl)
                }
                ForEach(season.transactions) { tx in
                    transactionCard(tx)
                }
            }
            .padding(FFSpace.l)
        }
    }

    @ViewBuilder
    private func transactionCard(_ tx: ImportedTransaction) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack(spacing: FFSpace.s) {
                FFPill(isFilled: tx.type == "trade") { Text(tx.typeLabel.uppercased()) }
                FFPill { Text("WEEK \(tx.week)") }
                if let bid = tx.waiverBid, bid > 0 {
                    FFPill { Text("$\(bid)") }
                }
                Spacer()
                if let date = tx.createdAt {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }

            if tx.type == "trade" {
                tradeBody(tx)
            } else {
                moveBody(tx)
            }
        }
        .ffCard(padding: FFSpace.m)
    }

    // Trade: show what each involved team received.
    @ViewBuilder
    private func tradeBody(_ tx: ImportedTransaction) -> some View {
        ForEach(tx.rosterIDs, id: \.self) { rid in
            let received = tx.adds.filter { $0.rosterID == rid }
            let picks = tx.picks.filter { $0.toRosterID == rid }
            if !received.isEmpty || !picks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(teamName(rid)).font(.ffCaption).foregroundStyle(FFColor.accent)
                    ForEach(received, id: \.player.sleeperID) { mv in
                        Text("+ \(mv.player.name)").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                            .playerLink(mv.player.appID)
                    }
                    ForEach(Array(picks.enumerated()), id: \.offset) { _, p in
                        Text("+ \(p.season) round \(p.round) pick")
                            .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func moveBody(_ tx: ImportedTransaction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(tx.adds, id: \.player.sleeperID) { mv in
                HStack(spacing: FFSpace.s) {
                    Text("+").font(.ffHeadline).foregroundStyle(FFColor.positive)
                    Text(mv.player.name).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                    Text("→ \(teamName(mv.rosterID))").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                    Spacer()
                }
                .playerLink(mv.player.appID)
            }
            ForEach(tx.drops, id: \.player.sleeperID) { mv in
                HStack(spacing: FFSpace.s) {
                    Text("–").font(.ffHeadline).foregroundStyle(FFColor.negative)
                    Text(mv.player.name).font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    Spacer()
                }
                .playerLink(mv.player.appID)
            }
        }
    }

    private func teamName(_ rid: Int) -> String {
        season.teamsByRoster[rid]?.teamName ?? "Team \(rid)"
    }
}

// MARK: - Draft

struct ImportedDraftSection: View {
    let season: ImportedSeason

    private var rounds: [Int] { Array(Set(season.draftPicks.map(\.round))).sorted() }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FFSpace.m) {
                if season.draftPicks.isEmpty {
                    Text("No draft results available for this season.")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textSecondary)
                        .padding(.top, FFSpace.xxl)
                }
                ForEach(rounds, id: \.self) { round in
                    VStack(alignment: .leading, spacing: FFSpace.xs) {
                        Text("Round \(round)").ffEyebrow()
                        ForEach(season.draftPicks.filter { $0.round == round }) { pick in
                            HStack(spacing: FFSpace.m) {
                                Text(pickLabel(pick))
                                    .font(.ffStatSmall)
                                    .foregroundStyle(FFColor.textSecondary)
                                    .frame(width: 48, alignment: .leading)
                                Circle().fill(FFColor.positionTint(pick.player.position)).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(pick.player.name).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                                    Text(teamName(pick.rosterID)).font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .playerLink(pick.player.appID)
                            .ffHairlineBottom()
                        }
                    }
                    .ffCard(padding: FFSpace.m)
                }
            }
            .padding(FFSpace.l)
        }
    }

    private func pickLabel(_ pick: ImportedDraftPick) -> String {
        let slot = pick.draftSlot > 0 ? String(format: "%02d", pick.draftSlot) : "—"
        return "\(pick.round).\(slot)"
    }

    private func teamName(_ rid: Int?) -> String {
        guard let rid, let t = season.teamsByRoster[rid] else { return "—" }
        return t.teamName
    }
}

// Shared 2-decimal formatter for points.
private func fmt(_ value: Double) -> String {
    String(format: "%.2f", value)
}
