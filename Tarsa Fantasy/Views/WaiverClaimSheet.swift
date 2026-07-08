import SwiftUI

// Modal sheet for adding a free agent or submitting a waiver claim.
// - If `isOnWaivers` is true, submitting creates a waiver_claim that will be
//   resolved at the next process tick in priority order.
// - Otherwise, it's an instant free-agent add (and optionally drops a player
//   to make room). If the league has commissioner_approval on and the user
//   isn't the commissioner, the add goes into pending_approval instead.
struct WaiverClaimSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let team: FantasyTeam
    let addPlayer: PlayerSummary
    let isOnWaivers: Bool
    let waiverUntil: Date?
    let onComplete: (League?) -> Void

    @State private var dropPlayerID: String? = nil
    @State private var bid: Int = 0
    @State private var saving: Bool = false
    @State private var error: String? = nil

    private var isFAAB: Bool { league.waiverSettings.mode == .faab }
    // Season budget minus won bids. Dollars tied up in other pending claims
    // are enforced server-side; this is the headline number owners think in.
    private var faabRemaining: Int {
        max(0, league.waiverSettings.faabBudget - team.faabSpent)
    }

    // IR players occupy extra capacity, so only active (non-IR) players count
    // against the roster limit.
    private var activeRosterCount: Int {
        let taxiReserved = league.rosterConfig.taxi > 0 ? Set(team.taxi) : Set<String>()
        let reserved = Set(team.ir).union(taxiReserved)
        return team.roster.filter { !reserved.contains($0) }.count
    }

    private var rosterFull: Bool {
        activeRosterCount >= league.rosterConfig.totalSize
    }

    private var dropRequired: Bool { rosterFull }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.xl) {
                        addingCard
                        if isOnWaivers && isFAAB {
                            bidSection
                        }
                        if dropRequired {
                            dropSection(required: true)
                        } else {
                            dropSection(required: false)
                        }
                        if league.waiverSettings.commissionerApproval && league.creatorID != team.ownerID && !isOnWaivers {
                            infoBanner(
                                "Commissioner approval is on — this add/drop will be held until the league creator approves it."
                            )
                        }
                        if isOnWaivers {
                            infoBanner(
                                "On waivers until \((waiverUntil ?? Date()).shortRelative). Claims process at "
                                + "\(league.waiverSettings.processDayLabel) "
                                + String(format: "%02d:00 UTC", league.waiverSettings.processHour)
                                + (isFAAB ? " — highest bid wins."
                                          : ", in waiver-priority order.")
                            )
                        }
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
            .navigationTitle(isOnWaivers ? "Submit claim" : "Add player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(submitLabel) { Task { await submit() } }
                        .foregroundStyle(canSubmit ? FFColor.accent : FFColor.textTertiary)
                        .disabled(!canSubmit || saving)
                }
            }
        }
        .hostsPlayerProfileSheet()
    }

    private var submitLabel: String { isOnWaivers ? "Claim" : "Add" }

    private var canSubmit: Bool {
        if dropRequired && dropPlayerID == nil { return false }
        if isOnWaivers && isFAAB && bid > faabRemaining { return false }
        return true
    }

    // Blind FAAB bid with the remaining season budget alongside. The server
    // re-validates against budget minus bids already pending on other claims.
    private var bidSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("YOUR BID").ffEyebrow()
            HStack(spacing: FFSpace.m) {
                Text("$\(bid)")
                    .font(.ffStatMedium)
                    .foregroundStyle(bid > faabRemaining ? FFColor.negative : FFColor.accent)
                Stepper("", value: $bid, in: 0...max(0, faabRemaining))
                    .labelsHidden()
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("$\(faabRemaining)").font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                    Text("REMAINING").ffEyebrow()
                }
            }
            .ffCard()
            Text("Bids are blind. Ties go to the earlier waiver position. $0 bids are allowed.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textTertiary)
        }
    }

    private var addingCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(isOnWaivers ? "CLAIMING" : "ADDING").ffEyebrow()
            HStack(spacing: FFSpace.m) {
                PlayerAvatar(url: addPlayer.headshotURL, fallback: addPlayer.name.initialsFromName, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(addPlayer.name).font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                    HStack(spacing: 6) {
                        PositionPill(position: addPlayer.position)
                        Text(addPlayer.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    }
                }
                .playerLink(addPlayer.id)
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(addPlayer.points.fpString)").font(.ffStatMedium).foregroundStyle(FFColor.accent)
                    Text("PTS").ffEyebrow()
                }
            }
            .ffCard()
        }
    }

    @ViewBuilder
    private func dropSection(required: Bool) -> some View {
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let week = Fantasy.currentWeek(players: players)
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(required ? "DROP (REQUIRED)" : "DROP (OPTIONAL)").ffEyebrow()
                Spacer()
                if !required, dropPlayerID != nil {
                    Button("Clear") { dropPlayerID = nil }
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textSecondary)
                }
            }
            VStack(spacing: 0) {
                if team.roster.isEmpty {
                    Text("Your roster is empty — no drop needed.")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                        .padding(FFSpace.l)
                } else {
                    ForEach(team.roster, id: \.self) { pid in
                        dropRow(pid, players: players, week: week)
                    }
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
            if required {
                Text("Your roster is full (\(activeRosterCount)/\(league.rosterConfig.totalSize)). Pick someone to drop.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
    }

    private func dropRow(_ pid: String, players: [String: Player], week: Int) -> some View {
        let p = players[pid]
        let summary = p.map { Fantasy.summary($0, scoring: league.scoring) }
        let locked = Fantasy.isPlayerLocked(playerID: pid, week: week, players: players)
        let isSelected = dropPlayerID == pid
        // Row tap selects the drop (no-op when locked); tapping the name opens
        // the player profile (descendant tap takes precedence over the row).
        return HStack(spacing: FFSpace.m) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? FFColor.accent : FFColor.textTertiary)
            if let summary {
                PlayerAvatar(url: summary.headshotURL, fallback: summary.name.initialsFromName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.name)
                        .font(.ffBody)
                        .foregroundStyle(locked ? FFColor.textTertiary : FFColor.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        PositionPill(position: summary.position)
                        Text(summary.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        if locked {
                            Text("• locked").font(.ffCaption).foregroundStyle(FFColor.warning)
                        }
                    }
                }
                .playerLink(pid)
                Spacer()
                Text(summary.points.fpString)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textSecondary)
            } else {
                Text(pid).font(.ffBody).foregroundStyle(FFColor.textSecondary)
                Spacer()
            }
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
        .contentShape(Rectangle())
        .onTapGesture {
            if locked { return }
            dropPlayerID = (isSelected ? nil : pid)
        }
    }

    private func infoBanner(_ text: String) -> some View {
        Text(text)
            .font(.ffCaption)
            .foregroundStyle(FFColor.textSecondary)
            .padding(FFSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FFColor.accentSoft, in: RoundedRectangle(cornerRadius: FFRadius.s))
    }

    private func submit() async {
        saving = true; defer { saving = false }
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        let week = Fantasy.currentWeek(players: players)
        if Fantasy.isPlayerLocked(playerID: addPlayer.id, week: week, players: players) {
            self.error = "This player's game is in progress."
            return
        }
        if let drop = dropPlayerID,
           Fantasy.isPlayerLocked(playerID: drop, week: week, players: players) {
            self.error = "Your selected drop is locked."
            return
        }
        do {
            if isOnWaivers {
                _ = try await app.submitWaiverClaim(
                    leagueID: league.id, teamID: team.id,
                    addPlayerID: addPlayer.id, dropPlayerID: dropPlayerID,
                    bid: isFAAB ? bid : nil
                )
                onComplete(nil)
            } else {
                let updated = try await app.addFreeAgent(
                    league: league, team: team,
                    addPlayerID: addPlayer.id, dropPlayerID: dropPlayerID
                )
                onComplete(updated)
            }
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
