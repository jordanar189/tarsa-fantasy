import SwiftUI

// Team renames + kicking owners. Rename/kick apply immediately (they're
// per-team RPCs, not part of the root's Save batch), so this page owns its
// own edit state and threads results back through onSave.
struct MembersSettingsPage: View {
    @Environment(AppState.self) private var app

    let league: League
    let rosterConfig: RosterConfig
    let onSave: (League) -> Void
    @Binding var error: String?

    @State private var editingTeamID: String? = nil
    @State private var editingTeamName: String = ""
    @State private var teamToKick: TeamRef? = nil

    struct TeamRef: Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        SettingsPageScaffold(title: "Members") {
            Section {
                ForEach(league.teams) { team in
                    memberRow(team)
                }
            } header: {
                Text("Members").ffEyebrow()
            } footer: {
                Text("Kicking removes the owner but keeps the team and its roster intact, so a new manager can claim it with the join code.")
                    .foregroundStyle(FFColor.textTertiary)
            }
            .listRowBackground(FFColor.surface)
        }
        .alert(item: $teamToKick) { ref in
            Alert(
                title: Text("Kick \(ref.name)?"),
                message: Text("The owner is removed from the league. The team stays and can be re-claimed with the join code. The roster is kept."),
                primaryButton: .destructive(Text("Kick")) {
                    Task { await kick(teamID: ref.id) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private func memberRow(_ team: FantasyTeam) -> some View {
        let isMine    = team.ownerID == app.session?.userID
        let isOpen    = team.ownerID == nil
        let isEditing = editingTeamID == team.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: FFSpace.s) {
                if isEditing {
                    TextField("Team name", text: $editingTeamName)
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                        .submitLabel(.done)
                        .onSubmit { Task { await commitRename(teamID: team.id) } }
                } else {
                    Text(team.name)
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                }
                if isMine { CommissionerBadge(compact: true) }
                if isOpen {
                    Text("OPEN")
                        .ffEyebrow(color: FFColor.warning)
                }
                Spacer()
                if isEditing {
                    Button("Save") { Task { await commitRename(teamID: team.id) } }
                        .font(.ffCaption.bold())
                        .foregroundStyle(FFColor.accent)
                } else {
                    Button {
                        editingTeamID = team.id
                        editingTeamName = team.name
                    } label: {
                        Image(systemName: "pencil")
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
            HStack {
                Text("\(team.roster.count)/\(rosterConfig.totalSize) players")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                Spacer()
                if !isMine && !isOpen {
                    Button(role: .destructive) {
                        teamToKick = TeamRef(id: team.id, name: team.name)
                    } label: {
                        Text("Kick").font(.ffCaption.bold())
                            .foregroundStyle(FFColor.negative)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func commitRename(teamID: String) async {
        let name = editingTeamName
        editingTeamID = nil
        do {
            if let updated = try await app.renameTeam(teamID: teamID, name: name) {
                onSave(updated)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func kick(teamID: String) async {
        do {
            if let updated = try await app.kickTeamOwner(teamID: teamID) {
                onSave(updated)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
