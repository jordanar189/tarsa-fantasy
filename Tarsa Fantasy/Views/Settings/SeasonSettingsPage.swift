import SwiftUI

// Season lifecycle: complete → archive, roll over into a new season, and
// (for dynasty/keeper leagues) future draft-pick generation. Actions apply
// immediately, so the page owns its own in-flight state; a successful
// rollover dismisses the whole settings sheet via onRolledOver.
struct SeasonSettingsPage: View {
    @Environment(AppState.self) private var app

    let league: League
    let onSave: (League) -> Void
    let onRolledOver: () -> Void
    @Binding var error: String?

    @State private var completing: Bool = false
    @State private var rollingOver: Bool = false
    @State private var rolloverSeason: Int = Calendar.current.component(.year, from: Date())
    @State private var confirmingComplete: Bool = false
    @State private var generatingPicks: Bool = false
    @State private var pickGenResult: String? = nil

    var body: some View {
        SettingsPageScaffold(title: "Season") {
            seasonSection
            if league.isDynasty || league.keeperCount > 0 {
                pickAssetsSection
            }
        }
    }

    private var seasonSection: some View {
        Section {
            if league.seasonCompleted {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(FFColor.positive)
                    Text("Season completed")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    if let at = league.seasonCompletedAt {
                        Text(at.formatted(date: .abbreviated, time: .omitted))
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
                Stepper(value: $rolloverSeason, in: 1990...2100) {
                    HStack {
                        Text("Next season")
                            .font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text(String(rolloverSeason))
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.accent)
                    }
                }
                Button {
                    Task { await performRollover() }
                } label: {
                    HStack {
                        if rollingOver { ProgressView().controlSize(.small).tint(FFColor.bg) }
                        Text(rollingOver ? "Creating…" : "Roll over to \(rolloverSeason)")
                    }
                    .font(.ffCaption.bold())
                    .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
                    .background(FFColor.accent, in: Capsule())
                    .foregroundStyle(FFColor.bg)
                }
                .buttonStyle(.plain)
                .disabled(rollingOver)
            } else {
                Button {
                    confirmingComplete = true
                } label: {
                    HStack {
                        if completing { ProgressView().controlSize(.small).tint(FFColor.accent) }
                        Image(systemName: "flag.checkered")
                        Text(completing ? "Archiving…" : "Complete season")
                    }
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.accent)
                }
                .buttonStyle(.plain)
                .disabled(completing)
                .alert("Complete this season?", isPresented: $confirmingComplete) {
                    Button("Cancel", role: .cancel) {}
                    Button("Complete season") {
                        Task { await performComplete() }
                    }
                } message: {
                    Text("Freezes the final standings + every matchup into the league's history. You can then start a new season that links back to this one.")
                }
            }
        } header: {
            Text("Season").ffEyebrow()
        } footer: {
            Text(league.seasonCompleted
                ? (league.isDynasty
                    ? "Rolling over carries every team and roster into the new season with the same settings; the join code is regenerated."
                    : "Rolling over carries every team and manager into the new season with the same settings; rosters are cleared for a fresh draft and the join code is regenerated.")
                : "Completing a season is permanent — the standings snapshot is the source of truth going forward.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
        .onAppear {
            rolloverSeason = max(rolloverSeason, league.season + 1)
        }
    }

    // MARK: - Draft picks

    private var pickAssetsSection: some View {
        Section {
            Button {
                Task { await generatePicks() }
            } label: {
                HStack {
                    Image(systemName: "ticket")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FFColor.accent)
                    Text("Generate \(league.season + 1) picks (4 rounds)")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    if generatingPicks {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(generatingPicks)
            if let pickGenResult {
                Text(pickGenResult)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }
        } header: {
            Text("Draft picks").ffEyebrow()
        } footer: {
            Text("Creates one tradeable pick per team and round for next season's draft. Safe to run again — existing picks aren't duplicated.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    // MARK: - Actions

    private func performComplete() async {
        completing = true; defer { completing = false }
        do {
            if let updated = try await app.completeLeagueSeason(leagueID: league.id) {
                onSave(updated)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func performRollover() async {
        rollingOver = true; defer { rollingOver = false }
        do {
            _ = try await app.rolloverLeague(
                parentID: league.id, newSeason: rolloverSeason, newName: nil
            )
            await app.reloadLeagues()
            onRolledOver()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func generatePicks() async {
        generatingPicks = true; defer { generatingPicks = false }
        do {
            let created = try await app.ensurePickAssets(
                leagueID: league.id, season: league.season + 1
            )
            pickGenResult = created > 0
                ? "Created \(created) new pick\(created == 1 ? "" : "s")."
                : "All \(league.season + 1) picks already exist."
            Haptics.success()
        } catch {
            pickGenResult = nil
            self.error = "Couldn't generate picks: \(error.localizedDescription)"
        }
    }
}
