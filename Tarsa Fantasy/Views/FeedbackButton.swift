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
                    // Everyone who can open this sheet (testers + admins) gets
                    // the Review tab; the list itself shows admins everything
                    // and testers only their own submissions.
                    SegmentedTabPicker(items: Tab.allCases, selection: $tab) {
                        Text($0.label)
                    }
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.l)
                    if tab == .send {
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

// MARK: - Review

// Status filter shown above the review list.
private enum FeedbackFilter: String, CaseIterable, Identifiable {
    case all, open, resolved
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:      return "All"
        case .open:     return "Open"
        case .resolved: return "Resolved"
        }
    }
    func matches(_ item: FeedbackItem) -> Bool {
        switch self {
        case .all:      return true
        case .open:     return item.status == .open
        case .resolved: return item.status == .resolved
        }
    }
}

private struct FeedbackReviewView: View {
    @Environment(AppState.self) private var app
    @State private var items: [FeedbackItem] = []
    @State private var loaded = false
    @State private var filter: FeedbackFilter = .all

    private var visibleItems: [FeedbackItem] {
        items.filter { filter.matches($0) }
    }

    var body: some View {
        VStack(spacing: FFSpace.m) {
            SegmentedTabPicker(items: FeedbackFilter.allCases, selection: $filter) {
                Text($0.label)
            }
            .padding(.horizontal, FFSpace.l)

            ScrollView {
                LazyVStack(spacing: FFSpace.s) {
                    if !loaded {
                        ProgressView().tint(FFColor.accent).padding(.top, FFSpace.xxl)
                    } else if visibleItems.isEmpty {
                        empty
                    } else {
                        ForEach(visibleItems) { item in
                            NavigationLink {
                                FeedbackDetailView(item: item) { updated in
                                    apply(updated)
                                }
                            } label: {
                                FeedbackRowCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(FFSpace.l)
            }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private var empty: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text(filter == .all ? "No feedback yet." : "Nothing here.")
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

    // Patch a single row in place after the detail screen mutates its status,
    // so returning to the list reflects the change without a full refetch.
    private func apply(_ updated: FeedbackItem) {
        if let idx = items.firstIndex(where: { $0.id == updated.id }) {
            items[idx] = updated
        }
    }
}

// Compact, tappable summary row for the review list.
private struct FeedbackRowCard: View {
    let item: FeedbackItem

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(item.username)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Spacer()
                FeedbackStatusPill(status: item.status)
            }
            Text(item.createdAt.formatted(.dateTime.month().day().hour().minute()))
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)

            if !item.content.isEmpty {
                Text(item.content)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: FFSpace.m) {
                if !item.imageURLs.isEmpty {
                    Label("\(item.imageURLs.count)", systemImage: "photo")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .ffCard()
    }
}

private struct FeedbackStatusPill: View {
    let status: FeedbackStatus
    var body: some View {
        FFPill(isFilled: status == .resolved) {
            Text(status == .open ? "OPEN" : "RESOLVED")
        }
        .foregroundStyle(status == .open ? FFColor.warning : FFColor.positive)
    }
}

// MARK: - Detail + discussion

private struct FeedbackDetailView: View {
    @Environment(AppState.self) private var app
    let item: FeedbackItem
    let onChange: (FeedbackItem) -> Void

    @State private var status: FeedbackStatus
    @State private var comments: [FeedbackComment] = []
    @State private var commentsLoaded = false
    @State private var draft: String = ""
    @State private var sending = false
    @State private var statusWorking = false
    @State private var gallery: ImageGallery? = nil
    @State private var error: String? = nil

    init(item: FeedbackItem, onChange: @escaping (FeedbackItem) -> Void) {
        self.item = item
        self.onChange = onChange
        _status = State(initialValue: item.status)
    }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: FFSpace.l) {
                    requestCard
                    statusControl
                    discussion
                }
                .padding(FFSpace.l)
            }
        }
        .navigationTitle("Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .fullScreenCover(item: $gallery) { g in
            FullScreenImageViewer(urls: g.urls, startIndex: g.index)
        }
        .task { await loadComments() }
    }

    // MARK: Request

    private var requestCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(item.username)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Spacer()
                FeedbackStatusPill(status: status)
            }
            Text(item.createdAt.formatted(.dateTime.month().day().year().hour().minute()))
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
                        ForEach(Array(item.imageURLs.enumerated()), id: \.offset) { idx, urlStr in
                            if let url = URL(string: urlStr) {
                                Button {
                                    gallery = ImageGallery(urls: item.imageURLs, index: idx)
                                } label: {
                                    thumbnail(url)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .ffCard()
    }

    @ViewBuilder
    private var statusControl: some View {
        if app.isAdmin {
            Button {
                Task { await toggleStatus() }
            } label: {
                if statusWorking {
                    ProgressView().tint(FFColor.accent).frame(maxWidth: .infinity)
                } else {
                    Label(
                        status == .open ? "Mark resolved" : "Reopen",
                        systemImage: status == .open ? "checkmark.circle" : "arrow.uturn.backward"
                    )
                }
            }
            .ffSecondaryButton()
            .disabled(statusWorking)
        }
    }

    // MARK: Discussion

    private var discussion: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack { Text("Discussion").ffEyebrow(); Spacer() }

            if !commentsLoaded {
                ProgressView().tint(FFColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FFSpace.l)
            } else if comments.isEmpty {
                Text("No comments yet. Start the conversation below.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
                    .padding(.vertical, FFSpace.s)
            } else {
                ForEach(comments) { comment in
                    CommentBubble(comment: comment, isMine: comment.userID == app.session?.userID)
                }
            }

            composer

            if let error {
                Text(error)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.warning)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: FFSpace.s) {
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Add a comment…")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textTertiary)
                        .padding(.horizontal, FFSpace.m)
                        .padding(.vertical, FFSpace.s + 2)
                }
                TextField("", text: $draft, axis: .vertical)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                    .lineLimit(1...5)
                    .padding(.horizontal, FFSpace.s)
                    .padding(.vertical, FFSpace.s)
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )

            Button {
                Task { await send() }
            } label: {
                if sending {
                    ProgressView().tint(.white)
                        .frame(width: 38, height: 38)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(canSend ? AnyShapeStyle(FFGradient.brand)
                                            : AnyShapeStyle(FFColor.borderStrong),
                                    in: Circle())
                }
            }
            .disabled(!canSend || sending)
        }
        .padding(.top, FFSpace.xs)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Actions

    private func loadComments() async {
        comments = await app.feedbackComments(feedbackID: item.id)
        commentsLoaded = true
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            let comment = try await app.addFeedbackComment(feedbackID: item.id, content: text)
            comments.append(comment)
            draft = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggleStatus() async {
        let next: FeedbackStatus = status == .open ? .resolved : .open
        statusWorking = true
        defer { statusWorking = false }
        do {
            _ = try await app.setFeedbackStatus(id: item.id, status: next)
            status = next
            onChange(FeedbackItem(
                id: item.id, userID: item.userID, username: item.username,
                content: item.content, imageURLs: item.imageURLs,
                status: next, createdAt: item.createdAt
            ))
        } catch {
            self.error = error.localizedDescription
        }
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
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.45), in: Circle())
                .padding(6)
        }
    }
}

private struct CommentBubble: View {
    let comment: FeedbackComment
    let isMine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: FFSpace.s) {
                Text(comment.username)
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.accent)
                Text(comment.createdAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
            Text(comment.content)
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(FFSpace.m)
        .background(
            isMine ? AnyShapeStyle(FFColor.accentSoft) : AnyShapeStyle(FFColor.surface),
            in: RoundedRectangle(cornerRadius: FFRadius.m)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }
}
