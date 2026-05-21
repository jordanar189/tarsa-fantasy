import SwiftUI
import PhotosUI

// Team branding editor: name, accent color, and logo. Available to the team's
// owner (and the commissioner). Logo images reuse the league's chat-images
// storage bucket.
struct TeamCustomizationSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let team: FantasyTeam
    let onSave: (League) -> Void

    @State private var name: String
    @State private var colorHex: String?
    @State private var logoURL: String?
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var uploading = false
    @State private var saving = false
    @State private var error: String? = nil

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
                        colorCard
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
        }
    }

    private var accent: Color {
        colorHex.flatMap { Color(hexString: $0) } ?? FFColor.accent
    }

    private var logoCard: some View {
        VStack(spacing: FFSpace.m) {
            ZStack {
                Circle().fill(accent.opacity(0.18))
                if let logoURL, let url = URL(string: logoURL) {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        ProgressView().tint(accent)
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(Circle())
                } else {
                    Text(name.initialsFromName)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(accent)
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
            guard let updated = try await app.setTeamCustomization(
                teamID: team.id, name: name, logoURL: logoURL, colorHex: colorHex
            ) else { dismiss(); return }
            onSave(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
