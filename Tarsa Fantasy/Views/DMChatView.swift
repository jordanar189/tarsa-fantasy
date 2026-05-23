import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// 1:1 direct message thread. Mirrors LeagueChatView's composer + bubble
// rendering but talks to the dm_messages table. No reactions in v1 — DMs
// are conversational, not group reactions.
struct DMChatView: View {
    @Environment(AppState.self) private var app
    let thread: DMThread
    let otherUsername: String

    @State private var messages: [DMMessage] = []
    @State private var draft: String = ""
    @State private var sending: Bool = false
    @State private var loaded: Bool = false
    @State private var error: String? = nil
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var pendingImage: PendingImage? = nil
    @State private var showingGIFPicker = false
    @FocusState private var composerFocused: Bool

    private var myUserID: String? { app.session?.userID }
    private var otherUserID: String { thread.otherUserID(me: myUserID ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider().background(FFColor.border)
            composer
        }
        .background(FFColor.bg)
        .navigationTitle(otherUsername)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: ChatRoute.profile(otherUserID)) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(FFColor.textPrimary)
                }
            }
        }
        .task(id: thread.id) { await initialLoad() }
        .onDisappear {
            Task { await DMChatListener.shared.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dmMessageInserted)) { note in
            handleInserted(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .dmMessageDeleted)) { note in
            handleDeleted(note)
        }
        .onChange(of: pickerItem) { _, item in
            Task { await loadPickedImage(item) }
        }
        .sheet(isPresented: $showingGIFPicker) {
            GIFPickerSheet { url in
                showingGIFPicker = false
                Task { await sendGIF(url) }
            }
        }
        .alert("Couldn't send", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: FFSpace.s) {
                    if !loaded {
                        ProgressView().tint(FFColor.accent).padding(.top, FFSpace.xxl)
                    } else if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            messageGroup(at: index, message: message)
                                .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, FFSpace.l)
                .padding(.top, FFSpace.l)
                .padding(.bottom, FFSpace.s)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "paperplane")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No messages yet")
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
            Text("Say hi to \(otherUsername).")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FFSpace.xxxl)
    }

    @ViewBuilder
    private func messageGroup(at index: Int, message m: DMMessage) -> some View {
        let prev = index > 0 ? messages[index - 1] : nil
        let isMine = m.senderID == myUserID
        let groupedWithPrev = prev?.senderID == m.senderID
            && (prev.map { m.createdAt.timeIntervalSince($0.createdAt) < 300 } ?? false)
        let showDaySeparator = prev.map { !Calendar.current.isDate(m.createdAt, inSameDayAs: $0.createdAt) } ?? true

        VStack(spacing: FFSpace.s) {
            if showDaySeparator {
                daySeparator(m.createdAt)
            }
            messageRow(m, isMine: isMine, grouped: groupedWithPrev && !showDaySeparator)
        }
    }

    private func daySeparator(_ date: Date) -> some View {
        Text(daySeparatorText(date))
            .font(.ffMicro).tracking(0.8)
            .foregroundStyle(FFColor.textTertiary)
            .padding(.vertical, FFSpace.s)
    }

    private func daySeparatorText(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "TODAY" }
        if cal.isDateInYesterday(date) { return "YESTERDAY" }
        return date.formatted(.dateTime.weekday(.wide).month().day()).uppercased()
    }

    @ViewBuilder
    private func messageRow(_ m: DMMessage, isMine: Bool, grouped: Bool) -> some View {
        HStack(alignment: .top, spacing: FFSpace.s) {
            if isMine { Spacer(minLength: FFSpace.xxl) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if !grouped {
                    Text(m.createdAt.formatted(.dateTime.hour().minute()))
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
                }
                messageBubble(m, isMine: isMine)
            }
            .frame(maxWidth: 260, alignment: isMine ? .trailing : .leading)

            if !isMine { Spacer(minLength: FFSpace.xxl) }
        }
    }

    @ViewBuilder
    private func messageBubble(_ m: DMMessage, isMine: Bool) -> some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: FFSpace.s) {
            if let imageURL = m.imageURL, let url = URL(string: imageURL) {
                chatImage(url: url)
            }
            if !m.content.isEmpty {
                Text(m.content)
                    .font(.ffBody)
                    .foregroundStyle(isMine ? FFColor.bg : FFColor.textPrimary)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, m.imageURL != nil && m.content.isEmpty ? 0 : FFSpace.m)
        .padding(.vertical, m.imageURL != nil && m.content.isEmpty ? 0 : FFSpace.s)
        .background(
            (m.imageURL != nil && m.content.isEmpty)
                ? Color.clear
                : (isMine ? FFColor.accent : FFColor.surface),
            in: RoundedRectangle(cornerRadius: FFRadius.m)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(
                    (isMine || (m.imageURL != nil && m.content.isEmpty))
                        ? Color.clear
                        : FFColor.border,
                    lineWidth: 1
                )
        )
        .contextMenu {
            if !m.content.isEmpty {
                Button {
                    UIPasteboard.general.string = m.content
                } label: { Label("Copy", systemImage: "doc.on.doc") }
            }
            if let urlStr = m.imageURL, let url = URL(string: urlStr) {
                Button {
                    UIPasteboard.general.url = url
                } label: { Label("Copy image link", systemImage: "link") }
            }
            if m.senderID == myUserID {
                Button(role: .destructive) {
                    Task { await deleteMessage(m) }
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    @ViewBuilder
    private func chatImage(url: URL) -> some View {
        if url.pathExtension.lowercased() == "gif" {
            AnimatedImageView(url: url)
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: FFRadius.m))
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        FFColor.surfaceElevated
                        ProgressView().tint(FFColor.textTertiary)
                    }
                    .frame(width: 220, height: 220)
                case .success(let image):
                    image.resizable().scaledToFill()
                        .frame(width: 220, height: 220)
                        .clipped()
                case .failure:
                    ZStack {
                        FFColor.surfaceElevated
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    .frame(width: 220, height: 220)
                @unknown default:
                    Color.clear.frame(width: 220, height: 220)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: FFRadius.m))
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: FFSpace.s) {
            if let pending = pendingImage {
                pendingImagePreview(pending)
            }
            HStack(alignment: .bottom, spacing: FFSpace.s) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(FFColor.accent)
                        .padding(.bottom, 6)
                }
                .disabled(sending)

                Button {
                    composerFocused = false
                    showingGIFPicker = true
                } label: {
                    Text("GIF")
                        .font(.ffMicro.bold())
                        .foregroundStyle(FFColor.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.s)
                                .strokeBorder(FFColor.accent, lineWidth: 1.5)
                        )
                        .padding(.bottom, 6)
                }
                .buttonStyle(.plain)
                .disabled(sending)

                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
                    .focused($composerFocused)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                    .padding(.horizontal, FFSpace.m)
                    .padding(.vertical, FFSpace.s)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.m)
                            .strokeBorder(FFColor.border, lineWidth: 1)
                    )

                Button {
                    Task { await send() }
                } label: {
                    if sending {
                        ProgressView()
                            .tint(FFColor.accent)
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? FFColor.accent : FFColor.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend || sending)
            }
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .background(FFColor.bg)
    }

    private func pendingImagePreview(_ pending: PendingImage) -> some View {
        HStack {
            ZStack(alignment: .topTrailing) {
                if let ui = UIImage(data: pending.data) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: FFRadius.s))
                }
                Button {
                    pendingImage = nil
                    pickerItem = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(FFColor.textPrimary, FFColor.bg)
                }
                .offset(x: 6, y: -6)
            }
            Spacer()
        }
    }

    private var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || pendingImage != nil
    }

    // MARK: - Actions

    private func initialLoad() async {
        loaded = false
        messages = await app.dmMessages(threadID: thread.id)
        loaded = true
        await DMChatListener.shared.start(threadID: thread.id)
    }

    private func loadPickedImage(_ item: PhotosPickerItem?) async {
        guard let item else {
            pendingImage = nil
            return
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            // Convert to JPEG for broad Supabase storage / CDN compatibility.
            // HEIC and other exotic formats may not render via AsyncImage over HTTPS.
            let (finalData, finalType): (Data, String)
            if let image = UIImage(data: data), let jpg = image.jpegData(compressionQuality: 0.85) {
                finalData = jpg
                finalType = "image/jpeg"
            } else {
                finalData = data
                finalType = item.supportedContentTypes
                    .first(where: { $0.preferredMIMEType?.hasPrefix("image/") == true })?
                    .preferredMIMEType ?? "image/jpeg"
            }
            pendingImage = PendingImage(data: finalData, contentType: finalType)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send() async {
        let text = draft
        let pending = pendingImage
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pending != nil else {
            return
        }
        draft = ""
        pendingImage = nil
        sending = true
        defer { sending = false }
        do {
            var imageURL: String? = nil
            if let pending {
                imageURL = try await app.uploadDMImage(
                    threadID: thread.id,
                    data: pending.data,
                    contentType: pending.contentType
                )
            }
            let posted = try await app.sendDMMessage(
                threadID: thread.id, content: text, imageURL: imageURL
            )
            if !messages.contains(where: { $0.id == posted.id }) {
                messages.append(posted)
            }
            pickerItem = nil
        } catch {
            draft = text
            pendingImage = pending
            self.error = error.localizedDescription
        }
    }

    // GIFs are GIPHY-hosted, so there's nothing to upload — the URL goes
    // straight into an image-only DM.
    private func sendGIF(_ urlString: String) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let posted = try await app.sendDMMessage(
                threadID: thread.id, content: "", imageURL: urlString
            )
            if !messages.contains(where: { $0.id == posted.id }) {
                messages.append(posted)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteMessage(_ m: DMMessage) async {
        await app.deleteDMMessage(id: m.id)
        messages.removeAll { $0.id == m.id }
    }

    private func handleInserted(_ note: Notification) {
        guard let tid = note.userInfo?["threadID"] as? String, tid == thread.id,
              let msg = note.userInfo?["message"] as? DMMessage else { return }
        if messages.contains(where: { $0.id == msg.id }) { return }
        messages.append(msg)
    }

    private func handleDeleted(_ note: Notification) {
        guard let tid = note.userInfo?["threadID"] as? String, tid == thread.id,
              let id = note.userInfo?["id"] as? String else { return }
        messages.removeAll { $0.id == id }
    }

    private struct PendingImage: Equatable {
        let data: Data
        let contentType: String
    }
}
