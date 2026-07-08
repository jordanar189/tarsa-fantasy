import SwiftUI

struct JoinLeagueView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    var initialCode: String? = nil
    let onJoined: (String) -> Void

    @State private var code: String = ""
    @State private var league: League? = nil
    @State private var error: String? = nil
    @State private var lookingUp: Bool = false
    @State private var claiming: Bool = false
    @State private var didAutoLookup: Bool = false
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                if let league {
                    teamPicker(league)
                } else {
                    codeEntry
                }
            }
            .navigationTitle("Join league")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
            }
            .task {
                guard !didAutoLookup, let initial = initialCode else {
                    // Manual entry: put the cursor in the code field right
                    // away instead of making the user tap it first.
                    codeFocused = true
                    return
                }
                didAutoLookup = true
                code = String(initial.uppercased()
                    .filter { $0.isLetter || $0.isNumber }
                    .prefix(6))
                if code.count == 6 { await lookup() }
            }
        }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: FFSpace.xxl) {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                Text("JOIN A LEAGUE").ffEyebrow(color: FFColor.accent)
                Text("Paste an invite link, or enter\nthe six-character code.")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(FFColor.textPrimary)
                    .lineSpacing(-2)
            }

            VStack(alignment: .leading, spacing: FFSpace.s) {
                TextField("", text: $code, prompt:
                    Text("ABC123").foregroundColor(FFColor.textTertiary)
                )
                .focused($codeFocused)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .tracking(8)
                .multilineTextAlignment(.center)
                .foregroundStyle(FFColor.accent)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(code.count == 6 ? FFColor.accent : FFColor.border, lineWidth: 1)
                )
                .onChange(of: code) { _, new in
                    // Allow pasting a full invite link, not just the code.
                    if let url = URL(string: new), let extracted = JoinLink.code(from: url) {
                        code = String(extracted.prefix(6))
                    } else {
                        code = String(new.uppercased()
                            .filter { $0.isLetter || $0.isNumber }
                            .prefix(6))
                    }
                }
                if let error {
                    Text(error).font(.ffCaption).foregroundStyle(FFColor.negative)
                }
            }

            Button {
                Task { await lookup() }
            } label: {
                Group {
                    if lookingUp { ProgressView().tint(FFColor.bg) }
                    else { Text("Find league") }
                }
            }
            .ffPrimaryButton(disabled: code.count != 6)
            .disabled(code.count != 6 || lookingUp)

            Spacer()
        }
        .padding(.horizontal, FFSpace.xxl)
        .padding(.top, FFSpace.xxl)
    }

    @ViewBuilder
    private func teamPicker(_ lg: League) -> some View {
        let unclaimed = lg.teams.filter { $0.ownerID == nil }
        ScrollView {
            VStack(alignment: .leading, spacing: FFSpace.xxl) {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("LEAGUE").ffEyebrow(color: FFColor.accent)
                    Text(lg.name)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(FFColor.textPrimary)
                    HStack(spacing: FFSpace.s) {
                        FFPill { Text(String(lg.season)) }
                        FFPill { Text(lg.scoring.label.uppercased()) }
                        FFPill { Text("\(lg.teams.count) TEAMS") }
                    }
                }

                if unclaimed.isEmpty {
                    VStack(spacing: FFSpace.s) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(FFColor.textTertiary)
                        Text("Every team in this league is already claimed.")
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    VStack(alignment: .leading, spacing: FFSpace.s) {
                        Text("Pick your team").ffEyebrow()
                        VStack(spacing: 0) {
                            ForEach(unclaimed) { team in
                                Button {
                                    Task { await claim(team) }
                                } label: {
                                    HStack {
                                        Text(team.name)
                                            .font(.ffHeadline)
                                            .foregroundStyle(FFColor.textPrimary)
                                        Spacer()
                                        Image(systemName: claiming ? "hourglass" : "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(FFColor.accent)
                                    }
                                    .padding(.horizontal, FFSpace.l)
                                    .padding(.vertical, FFSpace.l)
                                    .ffHairlineBottom()
                                }
                                .buttonStyle(.plain)
                                .disabled(claiming)
                            }
                        }
                        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.m)
                                .strokeBorder(FFColor.border, lineWidth: 1)
                        )
                    }
                }

                if let error {
                    Text(error).font(.ffCaption).foregroundStyle(FFColor.negative)
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.top, FFSpace.xxl)
        }
    }

    private func lookup() async {
        lookingUp = true; error = nil
        defer { lookingUp = false }
        do {
            guard let found = try await app.lookupLeague(byCode: code) else {
                error = "No league found with that code."; return
            }
            if found.teams.contains(where: { $0.ownerID == app.session?.userID }) {
                dismiss(); onJoined(found.id); return
            }
            league = found
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func claim(_ team: FantasyTeam) async {
        claiming = true; error = nil
        defer { claiming = false }
        do {
            _ = try await app.claimTeam(teamID: team.id)
            if let id = league?.id { dismiss(); onJoined(id) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
