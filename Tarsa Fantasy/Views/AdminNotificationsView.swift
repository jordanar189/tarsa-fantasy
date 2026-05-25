import SwiftUI
import PhotosUI

// Admin-only console for composing push notifications: title, body, optional
// image, audience (everyone or specific users), and immediate-or-scheduled
// delivery. A History tab shows past/queued sends and can cancel scheduled
// ones. Reached from the Admin section of the signed-in user's profile.
struct AdminNotificationsView: View {
    @State private var tab: Tab = .compose

    enum Tab: String, CaseIterable, Identifiable {
        case compose, history
        var id: String { rawValue }
        var label: String { self == .compose ? "Compose" : "History" }
    }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            VStack(spacing: FFSpace.l) {
                SegmentedTabPicker(items: Tab.allCases, selection: $tab) { Text($0.label) }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.l)
                if tab == .compose {
                    ComposeNotificationView()
                } else {
                    NotificationHistoryView()
                }
            }
        }
        .navigationTitle("Push notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
    }
}

// MARK: - Compose

private struct ComposeNotificationView: View {
    @Environment(AppState.self) private var app

    @State private var title = ""
    @State private var bodyText = ""
    @State private var audience: Audience = .all
    @State private var selectedUsers: [Profile] = []
    @State private var scheduleLater = false
    @State private var scheduledDate = Date().addingTimeInterval(3600)
    @State private var openLineupOnTap = false
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var imageData: Data? = nil
    @State private var submitting = false
    @State private var confirmation: String? = nil
    @State private var error: String? = nil

    enum Audience: String, CaseIterable, Identifiable {
        case all, specific
        var id: String { rawValue }
        var label: String { self == .all ? "Everyone" : "Specific users" }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSend: Bool {
        !trimmedTitle.isEmpty
        && (audience == .all || !selectedUsers.isEmpty)
        && !submitting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FFSpace.l) {
                titleField
                bodyField
                imageSection
                audienceSection
                scheduleSection
                tapActionSection
                sendButton
                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.positive)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(FFSpace.l)
        }
        .onChange(of: pickerItem) { _, item in Task { await loadImage(item) } }
        .alert("Couldn't send", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { }
        } message: {
            Text(error ?? "")
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("Title").ffEyebrow()
            TextField("e.g. Set your lineup", text: $title)
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
                .padding(FFSpace.s)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
        }
    }

    private var bodyField: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("Message").ffEyebrow()
            ZStack(alignment: .topLeading) {
                if bodyText.isEmpty {
                    Text("Lineups lock at kickoff — make sure yours is set.")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textTertiary)
                        .padding(.horizontal, FFSpace.m)
                        .padding(.vertical, FFSpace.s + 2)
                }
                TextEditor(text: $bodyText)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100)
                    .padding(.horizontal, FFSpace.s)
                    .padding(.vertical, FFSpace.xs)
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("Image (optional)").ffEyebrow()
            if let data = imageData, let ui = UIImage(data: data) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: ui)
                        .resizable().scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: FFRadius.m))
                    Button {
                        imageData = nil
                        pickerItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(FFColor.textPrimary, FFColor.bg)
                    }
                    .padding(FFSpace.s)
                }
            }
            PhotosPicker(
                selection: $pickerItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label(imageData == nil ? "Add image" : "Replace image",
                      systemImage: "photo.on.rectangle.angled")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.accent)
            }
            .disabled(submitting)
        }
    }

    private var audienceSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("Audience").ffEyebrow()
            Picker("Audience", selection: $audience) {
                ForEach(Audience.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if audience == .specific {
                UserMultiSelect(selected: $selectedUsers)
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Toggle(isOn: $scheduleLater) {
                Text("Schedule for later")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
            }
            .tint(FFColor.accent)
            if scheduleLater {
                DatePicker(
                    "Send at",
                    selection: $scheduledDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
            }
        }
        .padding(FFSpace.m)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
    }

    private var tapActionSection: some View {
        Toggle(isOn: $openLineupOnTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Open Lineup on tap")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Text("Tapping the notification jumps to the Lineup tab.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }
        }
        .tint(FFColor.accent)
        .padding(FFSpace.m)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
    }

    private var sendButton: some View {
        Button {
            Task { await send() }
        } label: {
            if submitting {
                ProgressView().tint(FFColor.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FFSpace.s)
            } else {
                Text(scheduleLater ? "Schedule notification" : "Send now")
            }
        }
        .ffPrimaryButton(disabled: !canSend)
        .disabled(!canSend)
    }

    private func loadImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        // Normalize to JPEG for CDN/AsyncImage compatibility (matches chat/feedback).
        if let image = UIImage(data: data), let jpg = image.jpegData(compressionQuality: 0.85) {
            imageData = jpg
        } else {
            imageData = data
        }
    }

    private func send() async {
        submitting = true
        defer { submitting = false }
        do {
            var imageURL: String? = nil
            if let data = imageData {
                imageURL = try await app.uploadNotificationImage(data: data, contentType: "image/jpeg")
            }
            let targets: [String]? = audience == .all ? nil : selectedUsers.map(\.id)
            let when: Date? = scheduleLater ? scheduledDate : nil
            _ = try await app.sendNotification(
                title: trimmedTitle,
                body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                imageURL: imageURL,
                deepLink: openLineupOnTap ? "tarsafantasy://lineup" : nil,
                targetUserIDs: targets,
                scheduledAt: when
            )
            withAnimation { confirmation = when == nil ? "Sent." : "Scheduled." }
            // Reset the form for the next message.
            title = ""
            bodyText = ""
            selectedUsers = []
            imageData = nil
            pickerItem = nil
            scheduleLater = false
            openLineupOnTap = false
            audience = .all
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - User multi-select

private struct UserMultiSelect: View {
    @Environment(AppState.self) private var app
    @Binding var selected: [Profile]

    @State private var query = ""
    @State private var results: [Profile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            if !selected.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FFSpace.xs) {
                        ForEach(selected) { p in
                            HStack(spacing: 4) {
                                Text(p.username).font(.ffCaption)
                                Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                            }
                            .padding(.horizontal, FFSpace.s)
                            .padding(.vertical, 6)
                            .background(FFColor.surfaceElevated, in: Capsule())
                            .foregroundStyle(FFColor.textPrimary)
                            .onTapGesture { selected.removeAll { $0.id == p.id } }
                        }
                    }
                }
            }
            TextField("Search users…", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
                .padding(FFSpace.s)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
                .onChange(of: query) { _, q in Task { await search(q) } }

            ForEach(results) { p in
                let isSel = selected.contains { $0.id == p.id }
                Button {
                    if isSel { selected.removeAll { $0.id == p.id } }
                    else { selected.append(p) }
                } label: {
                    HStack {
                        Text(p.username).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSel ? FFColor.accent : FFColor.textTertiary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func search(_ q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        results = await app.searchUsers(query: trimmed)
    }
}

// MARK: - History

private struct NotificationHistoryView: View {
    @Environment(AppState.self) private var app
    @State private var items: [AdminNotification] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: FFSpace.s) {
                if !loaded {
                    ProgressView().tint(FFColor.accent).padding(.top, FFSpace.xxl)
                } else if items.isEmpty {
                    empty
                } else {
                    ForEach(items) { item in
                        NotificationHistoryCard(item: item) { await cancel(item) }
                    }
                }
            }
            .padding(FFSpace.l)
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private var empty: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "bell.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No notifications yet.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FFSpace.xxl)
    }

    private func reload() async {
        items = await app.adminNotifications()
        loaded = true
    }

    private func cancel(_ item: AdminNotification) async {
        try? await app.cancelNotification(id: item.id)
        await reload()
    }
}

private struct NotificationHistoryCard: View {
    let item: AdminNotification
    let onCancel: () async -> Void
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(item.title)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Spacer()
                statusPill
            }
            if !item.body.isEmpty {
                Text(item.body)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let urlStr = item.imageURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        FFColor.surfaceElevated
                    }
                }
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: FFRadius.s))
            }
            Text(metaLine)
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)

            if item.status == .scheduled {
                Button {
                    Task { working = true; await onCancel(); working = false }
                } label: {
                    if working {
                        ProgressView().tint(FFColor.accent).frame(maxWidth: .infinity)
                    } else {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                }
                .ffSecondaryButton()
                .disabled(working)
            }
        }
        .ffCard()
    }

    private var statusPill: some View {
        FFPill(isFilled: item.status == .sent) {
            Text(item.status.rawValue.uppercased())
        }
        .foregroundStyle(pillColor)
    }

    private var pillColor: Color {
        switch item.status {
        case .sent:                   return FFColor.positive
        case .failed:                 return FFColor.warning
        case .scheduled, .sending:    return FFColor.accent
        case .canceled:               return FFColor.textTertiary
        }
    }

    private var metaLine: String {
        let audience = item.targetAll ? "Everyone" : "\(item.targetUserIDs.count) user\(item.targetUserIDs.count == 1 ? "" : "s")"
        switch item.status {
        case .scheduled:
            if let when = item.scheduledAt {
                return "\(audience) · scheduled \(when.formatted(.dateTime.month().day().hour().minute()))"
            }
            return "\(audience) · queued"
        case .sent:
            return "\(audience) · \(item.sentCount) delivered, \(item.failCount) failed"
        case .sending:
            return "\(audience) · sending…"
        case .failed:
            return "\(audience) · failed"
        case .canceled:
            return "\(audience) · canceled"
        }
    }
}
