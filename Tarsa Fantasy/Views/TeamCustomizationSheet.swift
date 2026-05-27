import SwiftUI
import PhotosUI

// Team branding editor: name, abbreviation, accent color, logo, and per-player
// nicknames. Available to the team's owner (and the commissioner). Logo images
// reuse the league's chat-images storage bucket. Nicknames apply only to
// players currently on the roster; they're archived automatically (kept in
// history) when a player is dropped.
struct TeamCustomizationSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let team: FantasyTeam
    let onSave: (League) -> Void

    @State private var name: String
    @State private var abbreviation: String
    @State private var colorHex: String?
    @State private var logoURL: String?
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var uploading = false
    @State private var saving = false
    @State private var error: String? = nil

    // Per-player nickname edits, keyed by player ID. Seeded from the league's
    // active nicknames on appear; `originalNicknames` lets save() push only
    // what actually changed.
    @State private var nicknames: [String: String] = [:]
    @State private var originalNicknames: [String: String] = [:]

    // Per-player value edits, keyed by player ID. Seeded from leagueValues on
    // appear; `originalValues` lets save() push only what changed.
    @State private var values: [String: PlayerValue] = [:]
    @State private var originalValues: [String: PlayerValue] = [:]

    // Curated accent palette (kept readable on the dark surfaces).
    private static let palette: [String] = [
        "#FF5A5F", "#FF8C42", "#FFC300", "#3DDC97",
        "#1FB6FF", "#5B6CFF", "#9B5DE5", "#F15BB5",
        "#2EC4B6", "#E0E0E0"
    ]

    init(league: League, team: FantasyTeam, onSave: @escaping (League) -> Void) {
        self.league = league
        self.team = team
        self.onSave = onSave
        _name = State(initialValue: team.name)
        _abbreviation = State(initialValue: team.abbreviation ?? "")
        _colorHex = State(initialValue: team.colorHex)
        _logoURL = State(initialValue: team.logoURL)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: FFSpace.l) {
                        if let error {
                            Text(error)
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.negative)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        logoCard
                        nameCard
                        abbreviationCard
                        colorCard
                        nicknamesCard
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.vertical, FFSpace.l)
                }
            }
            .navigationTitle("Customize team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .foregroundStyle(FFColor.accent)
                        .disabled(saving || uploading)
                }
            }
            .onChange(of: pickerItem) { _, item in
                Task { await uploadLogo(item) }
            }
            .task {
                await app.loadLeagueNicknames(leagueID: league.id)
                await app.loadLeagueValues(leagueID: league.id)
                let currentNicks = app.leagueNicknames[team.id] ?? [:]
                nicknames = currentNicks
                originalNicknames = currentNicks
                let currentValues = app.leagueValues[team.id] ?? [:]
                values = currentValues
                originalValues = currentValues
            }
        }
    }

    private var accent: Color {
        colorHex.flatMap { Color(hexString: $0) } ?? FFColor.accent
    }

    private var logoCard: some View {
        VStack(spacing: FFSpace.m) {
            ZStack {
                if let logoURL, let url = URL(string: logoURL) {
                    Circle().fill(accent.opacity(0.18))
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView().tint(accent)
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                } else {
                    // Show the same designed default the rest of the app uses
                    // so the owner previews exactly what others will see.
                    DefaultTeamCrest(accent: accent, size: 84)
                }
                if uploading {
                    Circle().fill(FFColor.bg.opacity(0.5))
                    ProgressView().tint(accent)
                }
            }
            .frame(width: 84, height: 84)
            .overlay(Circle().strokeBorder(accent.opacity(0.5), lineWidth: 2))

            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Text(logoURL == nil ? "Upload logo" : "Change logo")
                    .font(.ffCaption.bold())
                    .foregroundStyle(FFColor.accent)
            }
            if logoURL != nil {
                Button("Remove logo") { logoURL = nil }
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .ffCard()
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("TEAM NAME").ffEyebrow()
            TextField("", text: $name, prompt: Text("Team name").foregroundColor(FFColor.textTertiary))
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
                .padding(.horizontal, FFSpace.m).padding(.vertical, 12)
                .background(FFColor.surfaceElevated, in: RoundedRectangle(cornerRadius: FFRadius.s))
        }
        .ffCard()
    }

    private var abbreviationCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("ABBREVIATION").ffEyebrow()
            TextField("", text: $abbreviation,
                      prompt: Text("e.g. NYG").foregroundColor(FFColor.textTertiary))
                .font(.ffStatSmall)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .foregroundStyle(FFColor.textPrimary)
                .padding(.horizontal, FFSpace.m).padding(.vertical, 12)
                .background(FFColor.surfaceElevated, in: RoundedRectangle(cornerRadius: FFRadius.s))
                .onChange(of: abbreviation) { _, new in
                    // Keep it short and tag-like for the compact contexts it
                    // appears in (scoreboard, bracket, standings).
                    let cleaned = new.uppercased()
                        .filter { !$0.isWhitespace }
                    abbreviation = String(cleaned.prefix(4))
                }
            Text("Shown in standings, scoreboards, and the playoff bracket.")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
    }

    private var colorCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("ACCENT COLOR").ffEyebrow()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: FFSpace.m) {
                swatch(hex: nil) // default
                ForEach(Self.palette, id: \.self) { hex in
                    swatch(hex: hex)
                }
            }
        }
        .ffCard()
    }

    private func swatch(hex: String?) -> some View {
        let color = hex.flatMap { Color(hexString: $0) } ?? FFColor.accent
        let selected = colorHex == hex
        return Button {
            colorHex = hex
        } label: {
            ZStack {
                Circle().fill(color)
                if hex == nil {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 16))
                        .foregroundStyle(FFColor.bg)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(FFColor.bg)
                }
            }
            .frame(height: 40)
            .overlay(
                Circle().strokeBorder(selected ? FFColor.textPrimary : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Nicknames

    private var rosterPlayers: [Player] {
        let snapshot = Fantasy.playersFor(league: league,
                                          snapshot: app.players(season: league.season))
        return team.roster.compactMap { snapshot[$0] }
    }

    @ViewBuilder
    private var nicknamesCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("PLAYER NICKNAMES & VALUES").ffEyebrow()
            if team.roster.isEmpty {
                Text("Draft or add players to give them nicknames and values.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                    .padding(.vertical, FFSpace.s)
            } else {
                Text("Nicknames and value ratings show across the league. Both reset if you drop the player (nickname history is kept).")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
                VStack(spacing: 0) {
                    ForEach(rosterPlayers) { p in
                        nicknameRow(p)
                    }
                }
            }
        }
        .ffCard()
    }

    private func nicknameRow(_ p: Player) -> some View {
        let binding = Binding<String>(
            get: { nicknames[p.id] ?? "" },
            set: { nicknames[p.id] = $0 }
        )
        return VStack(spacing: FFSpace.s) {
            HStack(spacing: FFSpace.m) {
                PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name).font(.ffCaption).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                    TextField("", text: binding,
                              prompt: Text("Add a nickname").foregroundColor(FFColor.textTertiary))
                        .font(.ffBody)
                        .foregroundStyle(FFColor.accent)
                        .autocorrectionDisabled()
                }
                Spacer()
                if !(nicknames[p.id] ?? "").isEmpty {
                    Button {
                        nicknames[p.id] = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            valuePicker(for: p)
                .padding(.leading, 34 + FFSpace.m)
        }
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func valuePicker(for p: Player) -> some View {
        HStack(spacing: 6) {
            ForEach(PlayerValue.allCases) { v in
                let selected = values[p.id] == v
                Button {
                    values[p.id] = selected ? nil : v
                } label: {
                    Text(v.short)
                        .font(.ffMicro.bold())
                        .tracking(0.8)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(
                            selected ? valueColor(v).opacity(0.22) : FFColor.surfaceElevated,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    selected ? valueColor(v).opacity(0.6) : FFColor.border,
                                    lineWidth: 1
                                )
                        )
                        .foregroundStyle(selected ? valueColor(v) : FFColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func valueColor(_ v: PlayerValue) -> Color {
        switch v {
        case .high:   return FFColor.positive
        case .medium: return FFColor.warning
        case .low:    return FFColor.negative
        }
    }

    // MARK: - Upload + save

    private func uploadLogo(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        uploading = true
        defer { uploading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let (finalData, finalType): (Data, String)
            if let image = UIImage(data: data), let jpg = image.jpegData(compressionQuality: 0.85) {
                finalData = jpg; finalType = "image/jpeg"
            } else {
                finalData = data; finalType = "image/jpeg"
            }
            logoURL = try await app.uploadTeamLogo(
                leagueID: league.id, data: finalData, contentType: finalType
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            // Push nickname + value changes first so the refetched league
            // reflects them; only send the ones that actually changed.
            for p in team.roster {
                let new = (nicknames[p] ?? "").trimmingCharacters(in: .whitespaces)
                let old = (originalNicknames[p] ?? "").trimmingCharacters(in: .whitespaces)
                if new != old {
                    try await app.setPlayerNickname(
                        leagueID: league.id, teamID: team.id, playerID: p, nickname: new
                    )
                }
                let newV = values[p]
                let oldV = originalValues[p]
                if newV != oldV {
                    try await app.setPlayerValue(
                        leagueID: league.id, teamID: team.id, playerID: p, value: newV
                    )
                }
            }
            guard let updated = try await app.setTeamCustomization(
                teamID: team.id, name: name, logoURL: logoURL, colorHex: colorHex,
                abbreviation: abbreviation
            ) else { dismiss(); return }
            onSave(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
