import SwiftUI

// Composer for 3+ team trades. Every participating team gets a "sends"
// section (roster + owned picks); toggling an asset routes it to a receiving
// team, changeable per asset. The propose_multi_trade RPC re-validates
// ownership and conservation server-side.
struct MultiTradeBuilderView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let fromTeam: FantasyTeam
    let onDone: (Trade?) -> Void

    // One traded asset and where it's going.
    private struct AssetRoute: Identifiable, Hashable {
        let assetID: String
        let isPick: Bool
        let fromTeamID: String
        var toTeamID: String
        var id: String { assetID }
    }

    @State private var participantIDs: [String] = []
    @State private var routes: [AssetRoute] = []
    @State private var assets: [DraftPickAsset] = []
    @State private var note: String = ""
    @State private var saving: Bool = false
    @State private var error: String? = nil

    private var participants: [FantasyTeam] {
        participantIDs.compactMap { id in league.teams.first(where: { $0.id == id }) }
    }

    private var addableTeams: [FantasyTeam] {
        league.teams.filter { $0.ownerID != nil && !participantIDs.contains($0.id) }
    }

    private var canSend: Bool {
        participantIDs.count >= 3 && !routes.isEmpty
            && routes.allSatisfy { $0.toTeamID != $0.fromTeamID && participantIDs.contains($0.toTeamID) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.xl) {
                        teamsCard
                        ForEach(participants) { team in
                            sendsSection(team: team)
                        }
                        if participantIDs.count < 3 {
                            Text("Add at least \(3 - participantIDs.count) more team\(participantIDs.count == 2 ? "" : "s") — two-team deals live under “Propose a trade”.")
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        noteField
                        if let error {
                            Text(error)
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.negative)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(FFSpace.l)
                }
            }
            .navigationTitle("Multi-team trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") { Task { await send() } }
                        .foregroundStyle(canSend ? FFColor.accent : FFColor.textTertiary)
                        .disabled(!canSend || saving)
                }
            }
            .onAppear {
                if participantIDs.isEmpty { participantIDs = [fromTeam.id] }
            }
            .task {
                assets = await app.pickAssets(leagueID: league.id)
            }
        }
        .hostsPlayerProfileSheet()
    }

    // MARK: - Teams

    private var teamsCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("TEAMS (\(participantIDs.count))").ffEyebrow()
            VStack(spacing: 0) {
                ForEach(participants) { team in
                    HStack {
                        Text(team.name)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                        if team.id == fromTeam.id {
                            Text("YOU").ffEyebrow(color: FFColor.accent)
                        }
                        Spacer()
                        if team.id != fromTeam.id {
                            Button {
                                removeTeam(team.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(FFColor.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
                    .ffHairlineBottom()
                }
                if !addableTeams.isEmpty && participantIDs.count < 8 {
                    Menu {
                        ForEach(addableTeams) { t in
                            Button(t.name) { participantIDs.append(t.id) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(FFColor.accent)
                            Text("Add a team")
                                .font(.ffBody)
                                .foregroundStyle(FFColor.accent)
                            Spacer()
                        }
                        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
                    }
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
        }
    }

    private func removeTeam(_ teamID: String) {
        participantIDs.removeAll { $0 == teamID }
        routes.removeAll { $0.fromTeamID == teamID || $0.toTeamID == teamID }
    }

    // MARK: - Per-team sends

    @ViewBuilder
    private func sendsSection(team: FantasyTeam) -> some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let ownedPicks = assets.filter { $0.ownerTeamID == team.id }
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("\(team.name.uppercased()) SENDS").ffEyebrow()
                Spacer()
                Text("\(routes.filter { $0.fromTeamID == team.id }.count) selected")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
            VStack(spacing: 0) {
                ForEach(team.roster, id: \.self) { pid in
                    assetRow(assetID: pid, isPick: false, team: team,
                             title: players[pid]?.name ?? pid,
                             subtitle: players[pid].map { "\($0.position.uppercased()) · \($0.team.isEmpty ? "FA" : $0.team)" })
                }
                ForEach(ownedPicks) { asset in
                    assetRow(assetID: asset.id, isPick: true, team: team,
                             title: pickLabel(asset), subtitle: nil)
                }
                if team.roster.isEmpty && ownedPicks.isEmpty {
                    Text("Nothing to trade.")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                        .padding(FFSpace.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
        }
    }

    private func assetRow(assetID: String, isPick: Bool, team: FantasyTeam,
                          title: String, subtitle: String?) -> some View {
        let route = routes.first(where: { $0.assetID == assetID })
        let included = route?.fromTeamID == team.id
        return HStack(spacing: FFSpace.m) {
            Image(systemName: included ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(included ? FFColor.accent : FFColor.textTertiary)
            if isPick {
                Image(systemName: "ticket")
                    .font(.system(size: 13))
                    .foregroundStyle(FFColor.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                }
            }
            Spacer()
            if included, let route {
                receiverMenu(for: route)
            }
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
        .contentShape(Rectangle())
        .onTapGesture { toggle(assetID: assetID, isPick: isPick, fromTeamID: team.id) }
    }

    private func receiverMenu(for route: AssetRoute) -> some View {
        let receivers = participants.filter { $0.id != route.fromTeamID }
        let current = league.teams.first(where: { $0.id == route.toTeamID })
        return Menu {
            ForEach(receivers) { t in
                Button(t.name) { reroute(assetID: route.assetID, to: t.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                Text(current?.shortLabel ?? "?")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.ffCaption)
            .foregroundStyle(FFColor.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(FFColor.accent.opacity(0.4), lineWidth: 1))
        }
    }

    private func toggle(assetID: String, isPick: Bool, fromTeamID: String) {
        if let idx = routes.firstIndex(where: { $0.assetID == assetID }) {
            routes.remove(at: idx)
        } else {
            routes.append(AssetRoute(
                assetID: assetID, isPick: isPick,
                fromTeamID: fromTeamID,
                toTeamID: defaultReceiver(from: fromTeamID)
            ))
        }
    }

    private func reroute(assetID: String, to teamID: String) {
        guard let idx = routes.firstIndex(where: { $0.assetID == assetID }) else { return }
        routes[idx].toTeamID = teamID
    }

    // Next participating team after the giver, wrapping around.
    private func defaultReceiver(from teamID: String) -> String {
        guard let idx = participantIDs.firstIndex(of: teamID), participantIDs.count > 1 else {
            return teamID
        }
        return participantIDs[(idx + 1) % participantIDs.count]
    }

    private func pickLabel(_ asset: DraftPickAsset) -> String {
        guard asset.originalTeamID != asset.ownerTeamID,
              let origin = league.teams.first(where: { $0.id == asset.originalTeamID })
        else { return asset.shortLabel }
        return "\(asset.shortLabel) (via \(origin.name))"
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("NOTE (OPTIONAL)").ffEyebrow()
            TextField("", text: $note, prompt: Text("Explain the three-way.").foregroundColor(FFColor.textTertiary), axis: .vertical)
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
                .lineLimit(2...5)
                .padding(FFSpace.m)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.s)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
        }
    }

    private func send() async {
        saving = true; defer { saving = false }
        do {
            let sides = participantIDs.map { teamID in
                RemoteService.MultiTradeSide(
                    teamID: teamID,
                    givesPlayerIDs: routes.filter { $0.fromTeamID == teamID && !$0.isPick }.map(\.assetID),
                    givesPickIDs: routes.filter { $0.fromTeamID == teamID && $0.isPick }.map(\.assetID),
                    receivesPlayerIDs: routes.filter { $0.toTeamID == teamID && !$0.isPick }.map(\.assetID),
                    receivesPickIDs: routes.filter { $0.toTeamID == teamID && $0.isPick }.map(\.assetID)
                )
            }
            let trade = try await app.proposeMultiTrade(
                leagueID: league.id, proposerTeamID: fromTeam.id,
                sides: sides, note: note.isEmpty ? nil : note
            )
            onDone(trade)
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
