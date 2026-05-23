import SwiftUI

// Past-season archives for a league chain. Walks parent_league_id from
// the current league upward, so a freshly rolled-over child still sees
// the previous years' standings. Tapping a standings row opens a
// head-to-head sheet versus that team's owner across all archived seasons.
struct LeagueHistoryView: View {
    @Environment(AppState.self) private var app
    let league: League

    @State private var archives: [LeagueSeasonArchive] = []
    @State private var loaded: Bool = false
    @State private var matchupSheet: HeadToHeadContext? = nil

    struct HeadToHeadContext: Identifiable {
        let id = UUID()
        let opponentUserID: String
        let opponentLabel: String
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
                ForEach(archives) { archive in
                    archiveCard(archive)
                }
            }
        }
        .task(id: league.id) {
            archives = await app.leagueHistory(leagueID: league.id)
            loaded = true
        }
        .sheet(item: $matchupSheet) { ctx in
            HeadToHeadSheet(league: league, opponentUserID: ctx.opponentUserID, opponentLabel: ctx.opponentLabel)
        }
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
                    standingsRow(row, leagueChainID: a.leagueID)
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

    private func standingsRow(_ row: StandingsRow, leagueChainID: String) -> some View {
        let team = league.teams.first(where: { $0.id == row.id })
        let isMe = team?.ownerID == app.session?.userID
        let canOpenHeadToHead = (team?.ownerID != nil) && !isMe
        return Button {
            if let opp = team?.ownerID {
                matchupSheet = HeadToHeadContext(
                    opponentUserID: opp, opponentLabel: row.name
                )
            }
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
    let opponentUserID: String
    let opponentLabel: String

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
            .task(id: opponentUserID) {
                guard let me = app.session?.userID else { loaded = true; return }
                entries = await app.headToHead(
                    leagueID: league.id, meUserID: me, opponentUserID: opponentUserID
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
