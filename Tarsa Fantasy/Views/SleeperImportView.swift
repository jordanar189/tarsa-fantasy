import SwiftUI

// Sheet for importing a league from Sleeper. Two ways in: look up a user by
// their Sleeper username and pick from their leagues, or paste a league id
// directly. Importing pulls the whole season history, so it can take a few
// seconds — we block the sheet with an overlay while it runs.
struct SleeperImportView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    // Called with the imported league id so the caller can navigate to it.
    var onImported: (String) -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case username, leagueID
        var id: String { rawValue }
        var label: String { self == .username ? "Username" : "League ID" }
    }

    @State private var mode: Mode = .username
    @State private var username = ""
    @State private var leagueID = ""
    @State private var season = Calendar.current.component(.year, from: Date())
    @State private var foundUser: SleeperUserBrief?
    @State private var leagues: [SleeperLeagueBrief] = []
    @State private var searching = false
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: FFSpace.l) {
                        intro
                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        if mode == .username { usernameSection } else { leagueIDSection }

                        if let error {
                            Text(error)
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.negative)
                        }

                        if !leagues.isEmpty { leagueResults }
                    }
                    .padding(FFSpace.l)
                }
                .scrollDismissesKeyboard(.interactively)

                if importing { importingOverlay }
            }
            .navigationTitle("Import from Sleeper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
            }
            .task {
                if let s = await app.sleeperCurrentSeason(), s > 0 { season = s }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: FFSpace.xs) {
            Text("Bring a league over")
                .font(.ffTitle)
                .foregroundStyle(FFColor.textPrimary)
            Text("Pull in rosters, standings, matchups, the draft and every prior season — then activate it as a live Tarsa league to draft, set lineups and trade here.")
                .font(.ffBody)
                .foregroundStyle(FFColor.textSecondary)
        }
    }

    // MARK: - Username flow

    private var usernameSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.m) {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                Text("Sleeper username").ffEyebrow()
                TextField("", text: $username, prompt: Text("username").foregroundColor(FFColor.textTertiary))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                    .padding(FFSpace.m)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                    .overlay(RoundedRectangle(cornerRadius: FFRadius.s).strokeBorder(FFColor.border, lineWidth: 1))
                    .onSubmit { Task { await searchUser() } }
            }

            HStack {
                Text("Season").ffEyebrow()
                Spacer()
                Stepper(value: $season, in: 2017...(Calendar.current.component(.year, from: Date()) + 1)) {
                    Text(String(season))
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.textPrimary)
                }
                .fixedSize()
            }
            .ffCard(padding: FFSpace.m)

            Button {
                Task { await searchUser() }
            } label: {
                if searching { ProgressView().tint(.white) } else { Text("Find leagues") }
            }
            .ffPrimaryButton(disabled: username.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || searching)
        }
    }

    // MARK: - League id flow

    private var leagueIDSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.m) {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                Text("Sleeper league ID").ffEyebrow()
                TextField("", text: $leagueID, prompt: Text("e.g. 992179949000000000").foregroundColor(FFColor.textTertiary))
                    .keyboardType(.numberPad)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                    .padding(FFSpace.m)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                    .overlay(RoundedRectangle(cornerRadius: FFRadius.s).strokeBorder(FFColor.border, lineWidth: 1))
                Text("Find it in the Sleeper app under League Settings, or in a league URL.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }

            Button {
                Task { await runImport(id: leagueID) }
            } label: {
                Text("Import league")
            }
            .ffPrimaryButton(disabled: leagueID.trimmingCharacters(in: .whitespaces).isEmpty || importing)
            .disabled(leagueID.trimmingCharacters(in: .whitespaces).isEmpty || importing)
        }
    }

    // MARK: - Results

    private var leagueResults: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack(spacing: FFSpace.s) {
                if let user = foundUser {
                    SleeperAvatar(id: user.avatar, size: 22)
                    Text(user.displayName).ffEyebrow()
                }
                Spacer()
            }
            .padding(.top, FFSpace.s)

            ForEach(leagues) { lg in
                Button {
                    Task { await runImport(id: lg.id) }
                } label: {
                    HStack(spacing: FFSpace.m) {
                        SleeperAvatar(id: lg.avatar, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lg.name).font(.ffHeadline).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                            HStack(spacing: FFSpace.s) {
                                FFPill { Text(lg.season) }
                                FFPill { Text("\(lg.totalRosters) TEAMS") }
                            }
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(FFColor.accent)
                    }
                    .ffCard()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: FFSpace.l) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text("Importing league + history…")
                    .font(.ffHeadline)
                    .foregroundStyle(.white)
                Text("Pulling every season's rosters, matchups and transactions. This can take a moment.")
                    .font(.ffCaption)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            .padding(FFSpace.xxl)
            .frame(maxWidth: 300)
            .background(FFColor.surfaceElevated, in: RoundedRectangle(cornerRadius: FFRadius.l))
        }
    }

    // MARK: - Actions

    private func searchUser() async {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        searching = true; error = nil; leagues = []; foundUser = nil
        defer { searching = false }
        do {
            let user = try await app.sleeperUser(username: name)
            foundUser = user
            let found = try await app.sleeperLeagues(userID: user.id, season: season)
            leagues = found
            if found.isEmpty {
                error = "No NFL leagues for \(user.displayName) in \(String(season))."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runImport(id: String) async {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        importing = true; error = nil
        defer { importing = false }
        do {
            let league = try await app.importSleeperLeague(rootLeagueID: trimmed)
            onImported(league.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// Small circular Sleeper avatar with a graceful placeholder.
struct SleeperAvatar: View {
    let id: String?
    var size: CGFloat = 32

    var body: some View {
        AsyncImage(url: SleeperService.avatarURL(id)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Circle().fill(FFColor.surfaceElevated)
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 0.5))
    }
}
