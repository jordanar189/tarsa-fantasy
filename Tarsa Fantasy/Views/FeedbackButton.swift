import SwiftUI
import PhotosUI

// Floating, app-wide feedback entry point shown only to testers and admins.
// Pinned to a screen edge and draggable so it can be moved out of the way;
// release snaps it back to the nearest side. Tapping opens FeedbackSheet
// (compose for everyone, plus a review inbox for admins).
//
// Rendered as a full-bleed overlay: only the button itself is hit-testable,
// so taps on empty space fall through to the content underneath.
struct FeedbackButton: View {
    @Environment(AppState.self) private var app
    @State private var showingSheet = false
    @State private var center: CGPoint? = nil
    @GestureState private var dragTranslation: CGSize = .zero

    private let size: CGFloat = 52
    private let margin: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let base = center ?? defaultCenter(in: geo.size)
            let live = clamp(
                CGPoint(x: base.x + dragTranslation.width, y: base.y + dragTranslation.height),
                in: geo.size
            )
            // Gestures are attached to the icon BEFORE offset/frame so the hit
            // target stays the 52pt circle. (Attaching them after .position()
            // would make the gesture capture the whole screen.)
            icon
                .contentShape(Circle())
                .onTapGesture { showingSheet = true }
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .updating($dragTranslation) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            let dropped = clamp(
                                CGPoint(x: base.x + value.translation.width,
                                        y: base.y + value.translation.height),
                                in: geo.size
                            )
                            // Snap horizontally to whichever edge is closer.
                            let snappedX = dropped.x < geo.size.width / 2
                                ? margin + size / 2
                                : geo.size.width - margin - size / 2
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                center = CGPoint(x: snappedX, y: dropped.y)
                            }
                        }
                )
                .offset(x: live.x - size / 2, y: live.y - size / 2)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .sheet(isPresented: $showingSheet) {
            FeedbackSheet()
        }
    }

    private var icon: some View {
        ZStack {
            Circle()
                .fill(FFGradient.brand)
                .shadow(color: FFBrand.violet.opacity(0.35), radius: 10, y: 4)
            Image(systemName: "exclamationmark.bubble.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .opacity(0.92)
        .accessibilityLabel("Send feedback")
    }

    private func defaultCenter(in container: CGSize) -> CGPoint {
        CGPoint(x: container.width - margin - size / 2, y: container.height * 0.6)
    }

    // Keep the button fully on screen, below the nav bar and above the tab bar.
    private func clamp(_ p: CGPoint, in c: CGSize) -> CGPoint {
        let half = size / 2
        let minY = half + 64
        let maxY = c.height - half - 96
        return CGPoint(
            x: min(max(p.x, half + margin), c.width - half - margin),
            y: min(max(p.y, minY), max(minY, maxY))
        )
    }
}

// MARK: - Sheet

private struct FeedbackSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .send

    enum Tab: String, CaseIterable, Identifiable {
        case send, review
        var id: String { rawValue }
        var label: String { self == .send ? "Send" : "Review" }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                VStack(spacing: FFSpace.l) {
                    if app.isAdmin {
                        SegmentedTabPicker(items: Tab.allCases, selection: $tab) {
                            Text($0.label)
                        }
                        .padding(.horizontal, FFSpace.l)
                        .padding(.top, FFSpace.l)
                    }
                    if tab == .send || !app.isAdmin {
                        FeedbackComposeView { dismiss() }
                    } else {
                        FeedbackReviewView()
                    }
                }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
        }
    }
}

// MARK: - Compose

private struct FeedbackComposeView: View {
    @Environment(AppState.self) private var app
    let onSubmitted: () -> Void

    @State private var text: String = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var pending: [PendingImage] = []
    @State private var submitting = false
    @State private var sent = false
    @State private var error: String? = nil

    private var canSubmit: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FFSpace.l) {
                if sent {
                    confirmation
                } else {
                    form
                }
            }
            .padding(FFSpace.l)
        }
        .onChange(of: pickerItems) { _, items in
            Task { await loadPicked(items) }
        }
        .alert("Couldn't send feedback", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { }
        } message: {
            Text(error ?? "")
        }
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("What's on your mind?").ffEyebrow()
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Describe the bug, idea, or anything that felt off…")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textTertiary)
                        .padding(.horizontal, FFSpace.m)
                        .padding(.vertical, FFSpace.s + 2)
                }
                TextEditor(text: $text)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(.horizontal, FFSpace.s)
                    .padding(.vertical, FFSpace.xs)
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }

        if !pending.isEmpty {
            attachments
        }

        PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: 4,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Label("Add screenshot", systemImage: "photo.on.rectangle.angled")
                .font(.ffHeadline)
                .foregroundStyle(FFColor.accent)
        }
        .disabled(submitting)

        Button {
            Task { await submit() }
        } label: {
            if submitting {
                ProgressView().tint(FFColor.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FFSpace.s)
            } else {
                Text("Send feedback")
            }
        }
        .ffPrimaryButton(disabled: !canSubmit || submitting)
        .disabled(!canSubmit || submitting)
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FFSpace.s) {
                ForEach(pending) { item in
                    ZStack(alignment: .topTrailing) {
                        if let ui = UIImage(data: item.data) {
                            Image(uiImage: ui)
                                .resizable().scaledToFill()
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: FFRadius.s))
                        }
                        Button {
                            pending.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(FFColor.textPrimary, FFColor.bg)
                        }
                        .offset(x: 6, y: -6)
                    }
                }
            }
        }
    }

    private var confirmation: some View {
        VStack(spacing: FFSpace.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(FFColor.positive)
            Text("Thanks for the feedback!")
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
            Text("The team will see it in the review inbox.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FFSpace.xxl)
    }

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        var loaded: [PendingImage] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // Normalize to JPEG for CDN/AsyncImage compatibility (matches the
            // chat image path).
            if let image = UIImage(data: data), let jpg = image.jpegData(compressionQuality: 0.85) {
                loaded.append(PendingImage(data: jpg, contentType: "image/jpeg"))
            } else {
                loaded.append(PendingImage(data: data, contentType: "image/jpeg"))
            }
        }
        pending = loaded
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        do {
            var urls: [String] = []
            for item in pending {
                let url = try await app.uploadFeedbackImage(
                    data: item.data, contentType: item.contentType
                )
                urls.append(url)
            }
            _ = try await app.submitFeedback(content: text, imageURLs: urls)
            withAnimation { sent = true }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            onSubmitted()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private struct PendingImage: Identifiable, Equatable {
        let id = UUID()
        let data: Data
        let contentType: String
    }
}

// MARK: - Review (admin)

private struct FeedbackReviewView: View {
    @Environment(AppState.self) private var app
    @State private var items: [FeedbackItem] = []
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
                        FeedbackCard(item: item) { newStatus in
                            await updateStatus(item, to: newStatus)
                        }
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
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No feedback yet.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FFSpace.xxl)
    }

    private func reload() async {
        items = await app.feedbackInbox()
        loaded = true
    }

    private func updateStatus(_ item: FeedbackItem, to status: FeedbackStatus) async {
        do {
            _ = try await app.setFeedbackStatus(id: item.id, status: status)
            await reload()
        } catch {
            // Non-fatal; the list reload on next open will reflect server truth.
        }
    }
}

private struct FeedbackCard: View {
    let item: FeedbackItem
    let onStatusChange: (FeedbackStatus) async -> Void
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(item.username)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Spacer()
                statusPill
            }
            Text(item.createdAt.formatted(.dateTime.month().day().hour().minute()))
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)

            if !item.content.isEmpty {
                Text(item.content)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !item.imageURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FFSpace.s) {
                        ForEach(item.imageURLs, id: \.self) { urlStr in
                            if let url = URL(string: urlStr) {
                                thumbnail(url)
                            }
                        }
                    }
                }
            }

            Button {
                Task {
                    working = true
                    await onStatusChange(item.status == .open ? .resolved : .open)
                    working = false
                }
            } label: {
                if working {
                    ProgressView().tint(FFColor.accent)
                        .frame(maxWidth: .infinity)
                } else {
                    Label(
                        item.status == .open ? "Mark resolved" : "Reopen",
                        systemImage: item.status == .open ? "checkmark.circle" : "arrow.uturn.backward"
                    )
                }
            }
            .ffSecondaryButton()
            .disabled(working)
        }
        .ffCard()
    }

    private var statusPill: some View {
        FFPill(isFilled: item.status == .resolved) {
            Text(item.status == .open ? "OPEN" : "RESOLVED")
        }
        .foregroundStyle(item.status == .open ? FFColor.warning : FFColor.positive)
    }

    private func thumbnail(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                ZStack { FFColor.surfaceElevated; ProgressView().tint(FFColor.textTertiary) }
            default:
                ZStack {
                    FFColor.surfaceElevated
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: FFRadius.s))
    }
}
