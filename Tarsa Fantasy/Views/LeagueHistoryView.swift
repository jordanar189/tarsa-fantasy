import SwiftUI

// Past-season archives for a league chain. Walks parent_league_id from
// the current league upward, so a freshly rolled-over child still sees
// the previous years' standings. Tapping a standings row opens a
// head-to-head sheet versus that team's owner across all archived seasons.
struct LeagueHistoryView: View {
    @Environment(AppState.self) private var app
    let league: League

    @State private var archives: [LeagueSeasonArchive] = []
    @State private var allTime: [AllTimeFranchiseRecord] = []
    @State private var matrix: [String: [String: H2HRecord]] = [:]
    @State private var loaded: Bool = false
    @State private var matchupSheet: HeadToHeadContext? = nil
    @State private var showingMatrix: Bool = false

    struct HeadToHeadContext: Identifiable {
        let id = UUID()
        let opponentUserID: String?
        let opponentTeamID: String?
        let opponentLabel: String
    }

    private var myTeamID: String? {
        league.teams.first(where: { $0.ownerID == app.session?.userID })?.id
    }

    var body: some View {
        VStack(spacing: FFSpace.l) {
            if !loaded {
                ProgressView().tint(FFColor.accent).padding(.vertical, FFSpace.xl)
            } else if archives.isEmpty {
                Text("No seasons archived yet. The commissioner can complete the current season from settings to start the history.")
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, FFSpace.xl)
            } else {
                if archives.count >= 2, !allTime.isEmpty {
                    allTimeCard
                }
                ForEach(archives) { archive in
                    archiveCard(archive)
                }
            }
        }
        .task(id: league.id) {
            archives = await app.leagueHistory(leagueID: league.id)
            loaded = true
            let history = await app.allTimeHistory(leagueID: league.id)
            allTime = history.records
            matrix = history.matrix
        }
        .sheet(item: $matchupSheet) { ctx in
            HeadToHeadSheet(
                league: league,
                opponentUserID: ctx.opponentUserID,
                opponentLabel: ctx.opponentLabel,
                myTeamID: myTeamID,
                opponentTeamID: ctx.opponentTeamID
            )
        }
        .sheet(isPresented: $showingMatrix) {
            HeadToHeadMatrixSheet(franchises: allTime, matrix: matrix)
        }
    }

    // MARK: - All-time franchise records

    private var allTimeCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("ALL-TIME").ffEyebrow()
                Spacer()
                if !matrix.isEmpty {
                    Button {
                        showingMatrix = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.grid.3x3")
                                .font(.system(size: 11, weight: .semibold))
                            Text("H2H grid")
                        }
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(spacing: 0) {
                ForEach(allTime) { rec in
                    allTimeRow(rec)
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.s)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
            Text("Career records across every archived season, tracked by franchise even when a team changes hands.")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
    }

    private func allTimeRow(_ rec: AllTimeFranchiseRecord) -> some View {
        let isMe = rec.ownerID != nil && rec.ownerID == app.session?.userID
        return HStack(spacing: FFSpace.s) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(rec.name)
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                        .lineLimit(1)
                    if isMe { Text("YOU").ffEyebrow(color: FFColor.accent) }
                }
                Text("\(rec.seasons) season\(rec.seasons == 1 ? "" : "s") · \(rec.pointsFor.fpString) PF")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
            Spacer()
            if rec.championships > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(FFColor.accent)
                    Text("\(rec.championships)")
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.accent)
                }
            }
            ColoredRecord(wins: rec.wins, losses: rec.losses, ties: rec.ties, font: .ffStatSmall)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    private func archiveCard(_ a: LeagueSeasonArchive) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(String(a.season)).font(.ffTitle).foregroundStyle(FFColor.textPrimary)
                Spacer()
                if let name = a.scoringLeaderTeamName {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("SCORING LEADER").ffEyebrow(color: FFColor.textTertiary)
                        Text(name).font(.ffStatSmall).foregroundStyle(FFColor.accent)
                    }
                }
            }
            if let champ = a.championTeamName {
                HStack(spacing: FFSpace.s) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(FFColor.accent)
                    Text("Champion").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    Text(champ).font(.ffHeadline).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, FFSpace.m).padding(.vertical, FFSpace.s)
                .background(FFColor.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: FFRadius.s))
            }
            VStack(spacing: 0) {
                ForEach(a.standings) { row in
                    standingsRow(row, archive: a)
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.s)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
        .ffCard()
    }

    private func standingsRow(_ row: StandingsRow, archive: LeagueSeasonArchive) -> some View {
        // Standings reference the archived season's team ids — resolve the
        // owner through the archive's chain-wide map, falling back to the
        // current league's teams for pre-map archives.
        let ownerID = archive.ownerByTeamID[row.id]
            ?? league.teams.first(where: { $0.id == row.id })?.ownerID
        let isMe = ownerID == app.session?.userID
        // Lineage matching works even for unclaimed/re-owned teams, so the
        // sheet only needs the archived team id; the owner is a bonus.
        let canOpenHeadToHead = !isMe
        return Button {
            matchupSheet = HeadToHeadContext(
                opponentUserID: ownerID,
                opponentTeamID: row.id,
                opponentLabel: row.name
            )
        } label: {
            HStack {
                Text("\(row.rank)")
                    .font(.ffStatSmall)
                    .foregroundStyle(isMe ? FFColor.accent : FFColor.textSecondary)
                    .frame(width: 28, alignment: .leading)
                Text(row.name)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                if isMe {
                    Text("YOU").ffEyebrow(color: FFColor.accent)
                }
                Spacer()
                ColoredRecord(wins: row.wins, losses: row.losses, ties: row.ties, font: .ffStatSmall)
                    .frame(width: 56, alignment: .trailing)
                Text(row.pointsFor.fpString)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textPrimary)
                    .frame(width: 60, alignment: .trailing)
                if canOpenHeadToHead {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.vertical, FFSpace.m)
            .ffHairlineBottom()
        }
        .buttonStyle(.plain)
        .disabled(!canOpenHeadToHead)
    }
}

struct HeadToHeadSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let league: League
    let opponentUserID: String?
    let opponentLabel: String
    var myTeamID: String? = nil
    var opponentTeamID: String? = nil

    @State private var entries: [HeadToHeadEntry] = []
    @State private var loaded: Bool = false

    private var record: (w: Int, l: Int, t: Int) {
        var w = 0, l = 0, t = 0
        for e in entries {
            switch e.result {
            case "W": w += 1
            case "L": l += 1
            default:  t += 1
            }
        }
        return (w, l, t)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: FFSpace.l) {
                        header
                        if !loaded {
                            ProgressView().tint(FFColor.accent).padding(.top, FFSpace.xl)
                        } else if entries.isEmpty {
                            Text("No archived matchups vs \(opponentLabel) yet.")
                                .font(.ffBody)
                                .foregroundStyle(FFColor.textSecondary)
                                .padding(.top, FFSpace.xl)
                        } else {
                            matchupsList
                        }
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.vertical, FFSpace.l)
                }
            }
            .navigationTitle("Head to head")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(FFColor.accent)
                }
            }
            .task(id: opponentTeamID ?? opponentUserID) {
                guard let me = app.session?.userID else { loaded = true; return }
                entries = await app.headToHead(
                    leagueID: league.id, meUserID: me,
                    opponentUserID: opponentUserID ?? "",
                    myTeamID: myTeamID, opponentTeamID: opponentTeamID
                )
                loaded = true
            }
        }
    }

    private var header: some View {
        let r = record
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("VS").ffEyebrow()
            Text(opponentLabel)
                .font(.ffTitle)
                .foregroundStyle(FFColor.textPrimary)
            HStack(spacing: FFSpace.l) {
                column(label: "W", value: "\(r.w)", color: FFColor.positive)
                column(label: "L", value: "\(r.l)", color: FFColor.negative)
                if r.t > 0 {
                    column(label: "T", value: "\(r.t)", color: FFColor.warning)
                }
            }
        }
        .ffCard()
    }

    private func column(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            Text(value).font(.ffStatLarge).foregroundStyle(color)
        }
    }

    private var matchupsList: some View {
        VStack(spacing: 0) {
            ForEach(entries) { e in
                matchupRow(e)
            }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private func matchupRow(_ e: HeadToHeadEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(String(e.season)) · Week \(e.week)")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                Text("\(e.myPoints.fpString) – \(e.opponentPoints.fpString)")
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textPrimary)
            }
            Spacer()
            Text(e.result)
                .font(.ffMicro.bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(resultColor(e.result).opacity(0.18), in: Capsule())
                .foregroundStyle(resultColor(e.result))
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    private func resultColor(_ r: String) -> Color {
        switch r {
        case "W": return FFColor.positive
        case "L": return FFColor.negative
        default:  return FFColor.warning
        }
    }
}

// Career head-to-head grid: every franchise's record against every other,
// aggregated across all archived seasons. Rows read left-to-right ("row
// team's record vs the column team").
struct HeadToHeadMatrixSheet: View {
    @Environment(\.dismiss) private var dismiss
    let franchises: [AllTimeFranchiseRecord]
    let matrix: [String: [String: H2HRecord]]

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView([.vertical, .horizontal]) {
                    grid
                        .padding(FFSpace.l)
                }
            }
            .navigationTitle("Head-to-head grid")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(FFColor.accent)
                }
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: FFSpace.s, verticalSpacing: 0) {
            GridRow {
                Text("")
                    .frame(width: 110, alignment: .leading)
                ForEach(franchises) { f in
                    Text(shortLabel(f.name))
                        .font(.ffMicro.bold()).tracking(0.5)
                        .foregroundStyle(FFColor.textTertiary)
                        .frame(width: 52)
                }
            }
            .padding(.vertical, FFSpace.s)
            ForEach(franchises) { row in
                GridRow {
                    Text(row.name)
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textPrimary)
                        .lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                    ForEach(franchises) { col in
                        cell(row: row, col: col)
                            .frame(width: 52)
                    }
                }
                .padding(.vertical, FFSpace.s)
                .ffHairlineBottom()
            }
        }
    }

    @ViewBuilder
    private func cell(row: AllTimeFranchiseRecord, col: AllTimeFranchiseRecord) -> some View {
        if row.id == col.id {
            Text("—").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
        } else if let r = matrix[row.id]?[col.id], r.wins + r.losses + r.ties > 0 {
            Text(r.label)
                .font(.ffStatSmall)
                .foregroundStyle(r.wins > r.losses ? FFColor.positive
                                 : r.wins < r.losses ? FFColor.negative
                                 : FFColor.textSecondary)
        } else {
            Text("·").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
        }
    }

    // Compact column header from a team name: initials of up to three words
    // ("Rocky Top Rollers" → "RTR"), or the first three letters of a
    // single-word name.
    private func shortLabel(_ name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2 {
            return words.prefix(3).compactMap { $0.first.map(String.init) }
                .joined().uppercased()
        }
        return String(name.prefix(3)).uppercased()
    }
}
