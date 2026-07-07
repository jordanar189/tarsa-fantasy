import SwiftUI

// Setup sheet that promotes a read-only Sleeper import into a live, playable
// Tarsa league. The user names the league and picks which Sleeper team is
// theirs; everything else (scoring, roster slots, current rosters, prior-season
// history) carries over from the import. On success the league becomes the
// focused league and the rest of the app takes over.
struct SleeperActivateView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let leagueID: String                 // imported (Sleeper) league id
    var onActivated: (String) -> Void = { _ in }

    @State private var name = ""
    @State private var myRosterID: Int?
    @State private var working = false
    @State private var error: String?

    private var imported: ImportedLeague? { app.importedSleeperLeague(id: leagueID) }
    private var latest: ImportedSeason? { imported?.latest }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                if let latest {
                    form(latest: latest)
                } else {
                    Text("This import is no longer available.")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textSecondary)
                }
                if working { workingOverlay }
            }
            .navigationTitle("Activate league")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                        .disabled(working)
                }
            }
            .onAppear {
                if name.isEmpty { name = imported?.name ?? "" }
            }
        }
    }

    @ViewBuilder
    private func form(latest: ImportedSeason) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FFSpace.l) {
                intro
                summary(latest: latest)
                nameField
                teamPicker(latest: latest)
                if let error {
                    Text(error).font(.ffCaption).foregroundStyle(FFColor.negative)
                }
                activateButton
            }
            .padding(FFSpace.l)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: FFSpace.xs) {
            Text("Make it your league")
                .font(.ffTitle)
                .foregroundStyle(FFColor.textPrimary)
            Text("Bring this league into Tarsa for real: current rosters, scoring and roster slots come over, prior seasons land in history, and you can draft, set lineups, trade and run waivers here. Invite your leaguemates with the join code to claim their teams.")
                .font(.ffBody)
                .foregroundStyle(FFColor.textSecondary)
        }
    }

    private func summary(latest: ImportedSeason) -> some View {
        let cfg = SleeperPromotion.rosterConfig(from: latest.rosterPositions)
        let scoring = SleeperPromotion.scoring(fromLabel: latest.scoringLabel)
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack(spacing: FFSpace.s) {
                FFPill { Text(String(latest.seasonYear)) }
                FFPill { Text(scoring.label.uppercased()) }
                FFPill { Text("\(latest.teams.count) TEAMS") }
            }
            Text("Starters: \(starterSummary(cfg))")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textTertiary)
            carryoverSummary(latest: latest)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard(padding: FFSpace.m)
    }

    // Honest pre-promotion accounting: what carries over exactly, what maps
    // approximately, and what this app doesn't model yet — so nobody
    // discovers a rule change after the league is live.
    @ViewBuilder
    private func carryoverSummary(latest: ImportedSeason) -> some View {
        let scoring = SleeperPromotion.scoring(fromLabel: latest.scoringLabel)
        let custom = SleeperPromotion.scoringSettings(from: latest.scoringSettings, fallback: scoring)
        let waivers = SleeperPromotion.waiverSettings(
            waiverType: latest.waiverType, waiverBudget: latest.waiverBudget)
        let isDynasty = SleeperPromotion.isDynasty(leagueType: latest.leagueType)
        let isKeeper = latest.leagueType == 1
        let hasIDP = latest.rosterPositions.contains { $0 == "IDP_FLEX" || $0 == "DL" || $0 == "LB" || $0 == "DB" }

        VStack(alignment: .leading, spacing: 4) {
            carryLine("checkmark.circle.fill", positive: true,
                      latest.scoringSettings == nil
                        ? "Scoring: \(scoring.label) preset (this archive predates exact-weights import — re-import to carry custom weights)"
                        : (custom == nil ? "Scoring: \(scoring.label) preset (exact match)"
                                         : "Scoring: custom per-stat weights carried over"))
            carryLine("checkmark.circle.fill", positive: true,
                      waivers.mode == .faab
                        ? "Waivers: FAAB, $\(waivers.faabBudget) budget"
                        : "Waivers: rolling priority")
            if isDynasty {
                carryLine("checkmark.circle.fill", positive: true,
                          "Dynasty: rosters carry over every season")
            }
            if isKeeper {
                carryLine("exclamationmark.triangle.fill", positive: false,
                          "Keeper rules aren't supported yet — promotes as a redraft league")
            }
            if hasIDP {
                carryLine("exclamationmark.triangle.fill", positive: false,
                          "IDP slots aren't supported — they map to FLEX")
            }
            carryLine("exclamationmark.triangle.fill", positive: false,
                      "Future draft-pick trades don't carry over; past seasons import as history only")
        }
        .padding(.top, 2)
    }

    private func carryLine(_ icon: String, positive: Bool, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(positive ? FFColor.positive : FFColor.warning)
            Text(text)
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
        }
    }

    private func starterSummary(_ cfg: RosterConfig) -> String {
        var parts: [String] = []
        func add(_ n: Int, _ label: String) { if n > 0 { parts.append("\(n) \(label)") } }
        add(cfg.qb, "QB"); add(cfg.rb, "RB"); add(cfg.wr, "WR"); add(cfg.te, "TE")
        add(cfg.flex, "FLEX"); add(cfg.superflex, "SFLX")
        add(cfg.wrFlex, "W/R"); add(cfg.recFlex, "W/T")
        add(cfg.k, "K"); add(cfg.def, "DEF")
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("League name").ffEyebrow()
            TextField("", text: $name, prompt: Text("League name").foregroundColor(FFColor.textTertiary))
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
                .padding(FFSpace.m)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                .overlay(RoundedRectangle(cornerRadius: FFRadius.s).strokeBorder(FFColor.border, lineWidth: 1))
        }
    }

    private func teamPicker(latest: ImportedSeason) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("Which team is yours?").ffEyebrow()
            VStack(spacing: FFSpace.s) {
                ForEach(latest.standings) { team in
                    Button {
                        myRosterID = team.rosterID
                    } label: {
                        HStack(spacing: FFSpace.m) {
                            SleeperAvatar(id: team.avatar, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(team.teamName)
                                    .font(.ffHeadline)
                                    .foregroundStyle(FFColor.textPrimary)
                                    .lineLimit(1)
                                Text(team.ownerName)
                                    .font(.ffMicro)
                                    .foregroundStyle(FFColor.textTertiary)
                            }
                            Spacer()
                            Image(systemName: myRosterID == team.rosterID ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18))
                                .foregroundStyle(myRosterID == team.rosterID ? FFColor.accent : FFColor.textTertiary)
                        }
                        .ffCard(padding: FFSpace.m)
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.m)
                                .strokeBorder(FFColor.accent, lineWidth: myRosterID == team.rosterID ? 1.5 : 0)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var activateButton: some View {
        Button {
            Task { await activate() }
        } label: {
            Text("Create live league")
        }
        .ffPrimaryButton(disabled: myRosterID == nil || working)
        .disabled(myRosterID == nil || working)
    }

    private var workingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: FFSpace.m) {
                ProgressView().tint(.white).scaleEffect(1.2)
                Text("Setting up your league…")
                    .font(.ffHeadline)
                    .foregroundStyle(.white)
                Text("Creating teams, copying rosters and archiving past seasons.")
                    .font(.ffCaption)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            .padding(FFSpace.xxl)
            .frame(maxWidth: 300)
            .background(FFColor.surfaceElevated, in: RoundedRectangle(cornerRadius: FFRadius.l))
        }
    }

    private func activate() async {
        guard let rosterID = myRosterID else { return }
        working = true; error = nil
        defer { working = false }
        do {
            let league = try await app.promoteSleeperLeague(
                importedID: leagueID, myRosterID: rosterID, name: name
            )
            onActivated(league.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
