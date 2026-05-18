import SwiftUI

// Modal popup that shows a single fantasy team's roster (starters + bench)
// with season fantasy points. Presented from the Overview tab's standings /
// scoreboard when a team name is tapped, so users can scout any team without
// hopping to a separate roster screen. Owner/commish get an "Edit roster"
// shortcut that hands off to RosterEditorView via the onEdit callback (the
// parent owns sequencing so the two sheets don't fight).
struct TeamRosterSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let team: FantasyTeam
    let onEdit: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    rosterCard
                        .padding(.horizontal, FFSpace.l)
                        .padding(.vertical, FFSpace.l)
                }
            }
            .navigationTitle(team.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
        }
    }

    private var rosterCard: some View {
        let players  = Fantasy.playersFor(league: league,
                                          snapshot: app.players(season: league.season))
        let config   = league.rosterConfig
        let (starters, bench) = Fantasy.resolveLineup(
            team: team, players: players, config: config, scoring: league.scoring
        )
        let uid       = app.session?.userID
        let isMine    = team.ownerID == uid
        let isCommish = league.creatorID == uid

        return VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack(spacing: FFSpace.s) {
                Text(team.name).font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                if isMine {
                    Text("YOU").ffEyebrow(color: FFColor.accent)
                } else if team.ownerID == nil {
                    Text("OPEN").ffEyebrow(color: FFColor.warning)
                }
                Spacer()
                Text("\(team.roster.count)/\(config.totalSize)")
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textTertiary)
            }

            if team.roster.isEmpty {
                Text("No players yet.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(.vertical, FFSpace.m)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(zip(config.starterSlots, starters).enumerated()), id: \.offset) { _, pair in
                        lineupRow(slot: pair.0, playerID: pair.1, players: players)
                    }
                }

                if !bench.isEmpty {
                    Text("Bench").ffEyebrow().padding(.top, FFSpace.s)
                    VStack(spacing: 0) {
                        ForEach(bench, id: \.self) { pid in
                            lineupRow(slot: .bench, playerID: pid, players: players)
                        }
                    }
                }
            }

            if isMine || isCommish {
                Button {
                    dismiss()
                    onEdit()
                } label: {
                    HStack {
                        Image(systemName: isMine ? "square.and.pencil" : "shield.lefthalf.filled")
                            .font(.system(size: 13, weight: .semibold))
                        Text(isMine ? "Edit roster" : "Edit roster (commish)")
                    }
                    .frame(maxWidth: .infinity)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.accent)
                    .padding(.vertical, 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.s)
                            .strokeBorder(FFColor.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, FFSpace.s)
            }
        }
        .ffCard()
        .prefetchAvatars(urls: team.roster.compactMap { players[$0]?.headshotURL })
    }

    private func lineupRow(slot: LineupSlot, playerID: String,
                           players: [String: Player]) -> some View {
        let player = playerID.isEmpty ? nil : players[playerID]
        let summary = player.map { Fantasy.summary($0, scoring: league.scoring) }
        return HStack(spacing: FFSpace.m) {
            Text(slot.label)
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
                .frame(width: 40, alignment: .leading)
            if let summary, let player {
                PlayerAvatar(url: player.headshotURL, fallback: player.name.initialsFromName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: summary.position)
                        Text(summary.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    }
                }
                Spacer()
                Text(summary.points.fpString)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textPrimary)
            } else {
                emptyAvatar(size: 32)
                Text("Empty")
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textTertiary)
                Spacer()
            }
        }
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func emptyAvatar(size: CGFloat) -> some View {
        ZStack {
            Circle().fill(FFColor.surfaceElevated)
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(FFColor.textTertiary)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 0.5))
    }
}
