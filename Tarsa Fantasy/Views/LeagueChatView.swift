import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// League-scoped live chat. Owns its own ScrollViewReader + composer so it
// renders as a full-screen surface (parent should NOT wrap this in another
// ScrollView). Subscribes to LeagueChatListener on appear; messages and
// reactions from other users land via NotificationCenter and update in
// place.
struct LeagueChatView: View {
    @Environment(AppState.self) private var app
    let league: League

    @State private var messages: [LeagueMessage] = []
    @State private var reactions: [String: [LeagueMessageReaction]] = [:]
    @State private var responses: [String: [MessageResponse]] = [:]
    @State private var draft: String = ""
    @State private var sending: Bool = false
    @State private var loaded: Bool = false
    @State private var error: String? = nil
    @State private var usernamesByID: [String: String] = [:]
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var pendingImage: PendingImage? = nil
    @State private var showingGIFPicker = false
    @State private var composeSheet: ComposeSheet? = nil
    @State private var addOptionTarget: LeagueMessage? = nil
    @State private var newOption: String = ""
    @FocusState private var composerFocused: Bool

    private var myUserID: String? { app.session?.userID }

    // Quick-react row shown at the top of each message's context menu.
    // Keep this list short — context menus get cramped past 5-6 entries.
    private static let quickReactions = ["👍", "❤️", "😂", "🔥", "🏈", "💀"]

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider().background(FFColor.border)
            composer
        }
        .background(FFColor.bg)
        .task(id: league.id) {
            await initialLoad()
        }
        .onDisappear {
            Task { await LeagueChatListener.shared.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .leagueChatMessageInserted)) { note in
            handleMessageInserted(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .leagueChatMessageUpdated)) { note in
            handleMessageUpdated(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .leagueChatMessageDeleted)) { note in
            handleMessageDeleted(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .leagueChatReactionInserted)) { note in
            handleReactionInserted(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .leagueChatReactionDeleted)) { note in
            handleReactionDeleted(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .leagueChatResponseChanged)) { note in
            handleResponseChanged(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .leagueChatResponseDeleted)) { note in
            handleResponseDeleted(note)
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
        .sheet(item: $composeSheet) { sheet in
            switch sheet {
            case .poll:
                PollBuilderSheet { payload in
                    composeSheet = nil
                    Task { await sendStructured(kind: .poll, payload: payload) }
                }
            case .pickem:
                PickemBuilderSheet(league: league) { payload in
                    composeSheet = nil
                    Task { await sendStructured(kind: .pickem, payload: payload) }
                }
            case .tradeblock:
                TradeBlockBuilderSheet(league: league) { payload in
                    composeSheet = nil
                    Task { await sendStructured(kind: .tradeblock, payload: payload) }
                }
            }
        }
        .alert("Add option", isPresented: Binding(
            get: { addOptionTarget != nil },
            set: { if !$0 { addOptionTarget = nil; newOption = "" } }
        )) {
            TextField("Option", text: $newOption)
            Button("Cancel", role: .cancel) { addOptionTarget = nil; newOption = "" }
            Button("Add") {
                let text = newOption
                let target = addOptionTarget
                addOptionTarget = nil
                newOption = ""
                if let target { Task { await addOption(to: target, text: text) } }
            }
        } message: {
            Text("Add a new option to this poll.")
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
                    // Sentinel for autoscroll.
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
                // Initial scroll-to-bottom; tiny delay so the layout has
                // measured the message list height before we scroll.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No messages yet")
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
            Text("Say hi to your leaguemates.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FFSpace.xxxl)
    }

    // Renders a message grouped with the previous one if it's from the
    // same author within a short window (no repeated headers).
    @ViewBuilder
    private func messageGroup(at index: Int, message m: LeagueMessage) -> some View {
        let prev = index > 0 ? messages[index - 1] : nil
        let isMine = m.userID == myUserID
        let groupedWithPrev = prev?.userID == m.userID
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
    private func messageRow(_ m: LeagueMessage, isMine: Bool, grouped: Bool) -> some View {
        HStack(alignment: .top, spacing: FFSpace.s) {
            if isMine { Spacer(minLength: FFSpace.xxl) }

            if !isMine {
                // Avatar slot — placeholder circle with initials. Hidden
                // when grouped to keep transcripts compact.
                if grouped {
                    Color.clear.frame(width: 32, height: 32)
                } else {
                    avatarCircle(for: m)
                }
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if !grouped {
                    HStack(spacing: 6) {
                        if isMine { Spacer(minLength: 0) }
                        // Username tap → profile. NavigationLink resolves
                        // against the host stack's ChatRoute destinations.
                        NavigationLink(value: ChatRoute.profile(m.userID)) {
                            Text(displayName(for: m))
                                .font(.ffCaption.bold())
                                .foregroundStyle(FFColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(m.userID == myUserID)
                        Text(m.createdAt.formatted(.dateTime.hour().minute()))
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                        if !isMine { Spacer(minLength: 0) }
                    }
                }
                messageBubble(m, isMine: isMine)
                reactionStrip(for: m, isMine: isMine)
            }
            .frame(maxWidth: 260, alignment: isMine ? .trailing : .leading)

            if !isMine { Spacer(minLength: FFSpace.xxl) }
        }
    }

    @ViewBuilder
    private func messageBubble(_ m: LeagueMessage, isMine: Bool) -> some View {
        if m.kind == .text {
            textBubble(m, isMine: isMine)
                .contextMenu { messageMenu(for: m) }
        } else {
            StructuredMessageCard(
                message: m,
                responses: responses[m.id] ?? [],
                myUserID: myUserID,
                nameFor: { uid in resolveName(uid) },
                onRespond: { slot, choice in Task { await respond(slot, choice, on: m) } },
                onAddOption: { addOptionTarget = m }
            )
            .contextMenu { messageMenu(for: m) }
        }
    }

    private func textBubble(_ m: LeagueMessage, isMine: Bool) -> some View {
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

    @ViewBuilder
    private func messageMenu(for m: LeagueMessage) -> some View {
        // Quick-react submenu — keeps the top-level menu uncluttered.
        // Tapping an emoji here toggles that reaction on the message.
        Menu("Add reaction") {
            ForEach(Self.quickReactions, id: \.self) { emoji in
                Button {
                    Task { await toggleReaction(emoji, on: m) }
                } label: { Text(emoji) }
            }
        }
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
        if m.userID == myUserID || isCommissioner {
            Button(role: .destructive) {
                Task { await deleteMessage(m) }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func reactionStrip(for m: LeagueMessage, isMine: Bool) -> some View {
        let groups = reactionGroups(for: m.id)
        if !groups.isEmpty {
            HStack(spacing: 4) {
                if isMine { Spacer(minLength: 0) }
                ForEach(groups, id: \.emoji) { group in
                    reactionPill(group: group, on: m)
                }
                if !isMine { Spacer(minLength: 0) }
            }
            .padding(.top, 2)
        }
    }

    private func reactionPill(group: ReactionGroup, on m: LeagueMessage) -> some View {
        Button {
            Task { await toggleReaction(group.emoji, on: m) }
        } label: {
            HStack(spacing: 4) {
                Text(group.emoji).font(.system(size: 13))
                Text("\(group.count)")
                    .font(.ffMicro.bold())
                    .foregroundStyle(group.includesMe ? FFColor.accent : FFColor.textSecondary)
            }
            .padding(.horizontal, FFSpace.s)
            .padding(.vertical, 3)
            .background(
                group.includesMe ? FFColor.accentSoft : FFColor.surfaceElevated,
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    group.includesMe ? FFColor.accent.opacity(0.6) : FFColor.border,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    private func avatarCircle(for m: LeagueMessage) -> some View {
        let name = displayName(for: m)
        return ZStack {
            Circle().fill(FFColor.surfaceElevated)
            Text(name.initialsFromName)
                .font(.ffCaption.bold())
                .foregroundStyle(FFColor.textSecondary)
        }
        .frame(width: 32, height: 32)
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 1))
    }

    private func displayName(for m: LeagueMessage) -> String {
        if let cached = usernamesByID[m.userID] { return cached }
        if let name = m.username, !name.isEmpty { return name }
        // Fallback: try matching to a team owner by name in this league.
        if let team = league.teams.first(where: { $0.ownerID == m.userID }) {
            return team.name
        }
        return "Member"
    }

    private var isCommissioner: Bool {
        league.creatorID == myUserID
    }

    // MARK: - Reactions data shaping

    private struct ReactionGroup {
        let emoji: String
        let count: Int
        let includesMe: Bool
    }

    // Aggregates the raw per-(message,user,emoji) rows into [(emoji, count,
    // includesMe)] for display, ordered by emoji insertion order.
    private func reactionGroups(for messageID: String) -> [ReactionGroup] {
        guard let list = reactions[messageID], !list.isEmpty else { return [] }
        var orderedEmojis: [String] = []
        var byEmoji: [String: [LeagueMessageReaction]] = [:]
        for r in list {
            if byEmoji[r.emoji] == nil {
                byEmoji[r.emoji] = []
                orderedEmojis.append(r.emoji)
            }
            byEmoji[r.emoji]?.append(r)
        }
        return orderedEmojis.map { e in
            let group = byEmoji[e] ?? []
            return ReactionGroup(
                emoji: e,
                count: group.count,
                includesMe: group.contains(where: { $0.userID == myUserID })
            )
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: FFSpace.s) {
            if let pending = pendingImage {
                pendingImagePreview(pending)
            }
            HStack(alignment: .bottom, spacing: FFSpace.s) {
                Menu {
                    Button { composerFocused = false; composeSheet = .poll } label: {
                        Label("Poll", systemImage: "chart.bar")
                    }
                    Button { composerFocused = false; composeSheet = .pickem } label: {
                        Label("Pick 'em", systemImage: "football")
                    }
                    Button { composerFocused = false; composeSheet = .tradeblock } label: {
                        Label("Trade block", systemImage: "arrow.left.arrow.right")
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(FFColor.accent)
                        .padding(.bottom, 6)
                }
                .disabled(sending)

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
        let load = await app.leagueChat(leagueID: league.id)
        messages = load.messages
        reactions = load.reactions
        responses = load.responses
        cacheUsernames(from: messages)
        loaded = true
        await LeagueChatListener.shared.start(leagueID: league.id)
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
        // Clear visible composer state; pickerItem is left alone until the
        // request succeeds so a failed send can be retried without re-picking.
        draft = ""
        pendingImage = nil
        sending = true
        defer { sending = false }
        do {
            var imageURL: String? = nil
            if let pending {
                imageURL = try await app.uploadChatImage(
                    leagueID: league.id,
                    data: pending.data,
                    contentType: pending.contentType
                )
            }
            let posted = try await app.sendLeagueMessage(
                leagueID: league.id, content: text, imageURL: imageURL
            )
            // Realtime echoes our INSERT — append locally only if it hasn't
            // already landed, so we don't double-render.
            if !messages.contains(where: { $0.id == posted.id }) {
                messages.append(posted)
            }
            if let name = posted.username { usernamesByID[posted.userID] = name }
            pickerItem = nil
        } catch {
            // Restore composer state so the user doesn't lose their input.
            draft = text
            pendingImage = pending
            self.error = error.localizedDescription
        }
    }

    private func sendStructured(kind: MessageKind, payload: ChatPayload) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let posted = try await app.sendStructuredMessage(
                leagueID: league.id, kind: kind, payload: payload
            )
            if !messages.contains(where: { $0.id == posted.id }) {
                messages.append(posted)
            }
            if let name = posted.username { usernamesByID[posted.userID] = name }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // Optimistically records my selection for one slot, then persists it. A nil
    // choice clears the slot (un-voting). Realtime echoes the change for
    // everyone else (and reconciles mine).
    private func respond(_ slot: Int, _ choice: Int?, on m: LeagueMessage) async {
        guard let uid = myUserID else { return }
        let previous = responses[m.id] ?? []
        var updated = previous.filter { !($0.userID == uid && $0.slot == slot) }
        if let choice {
            updated.append(MessageResponse(messageID: m.id, userID: uid, slot: slot, choice: choice))
        }
        responses[m.id] = updated
        do {
            if let choice {
                try await app.respondToMessage(messageID: m.id, slot: slot, choice: choice)
            } else {
                try await app.clearResponse(messageID: m.id, slot: slot)
            }
        } catch {
            responses[m.id] = previous
            self.error = error.localizedDescription
        }
    }

    // Appends an option to a poll that allows it. Optimistically patches the
    // local payload; the realtime UPDATE reconciles for everyone (incl. us).
    private func addOption(to m: LeagueMessage, text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            try await app.addPollOption(messageID: m.id, option: clean)
            guard let idx = messages.firstIndex(where: { $0.id == m.id }) else { return }
            var p = messages[idx].payload ?? ChatPayload()
            var opts = p.options ?? []
            if !opts.contains(where: { $0.lowercased() == clean.lowercased() }) {
                opts.append(clean)
                p.options = opts
                messages[idx] = replacingPayload(messages[idx], with: p)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func replacingPayload(_ m: LeagueMessage, with payload: ChatPayload) -> LeagueMessage {
        LeagueMessage(
            id: m.id, leagueID: m.leagueID, userID: m.userID,
            username: m.username, content: m.content, imageURL: m.imageURL,
            createdAt: m.createdAt, kind: m.kind, payload: payload
        )
    }

    // Resolves a user ID to a display name for voter lists, reusing the chat's
    // username cache and falling back to a team owner's name in this league.
    private func resolveName(_ uid: String) -> String {
        if uid == myUserID { return "You" }
        if let cached = usernamesByID[uid] { return cached }
        if let team = league.teams.first(where: { $0.ownerID == uid }) { return team.name }
        return "Member"
    }

    // GIFs are hosted by GIPHY, so unlike photos there's nothing to upload —
    // the URL goes straight into an image-only message.
    private func sendGIF(_ urlString: String) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        do {
            let posted = try await app.sendLeagueMessage(
                leagueID: league.id, content: "", imageURL: urlString
            )
            if !messages.contains(where: { $0.id == posted.id }) {
                messages.append(posted)
            }
            if let name = posted.username { usernamesByID[posted.userID] = name }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteMessage(_ m: LeagueMessage) async {
        await app.deleteLeagueMessage(id: m.id)
        // Realtime DELETE will also fire — local removal here keeps the
        // UI snappy in case the network lags.
        messages.removeAll { $0.id == m.id }
        reactions[m.id] = nil
        responses[m.id] = nil
    }

    private func toggleReaction(_ emoji: String, on m: LeagueMessage) async {
        guard let uid = myUserID else { return }
        // Optimistic local update so the pill responds immediately.
        let existing = reactions[m.id] ?? []
        let mine = existing.first(where: { $0.userID == uid && $0.emoji == emoji })
        if let mine {
            reactions[m.id] = existing.filter { $0 != mine }
        } else {
            let new = LeagueMessageReaction(messageID: m.id, userID: uid, emoji: emoji)
            reactions[m.id] = existing + [new]
        }
        do {
            _ = try await app.toggleReaction(messageID: m.id, emoji: emoji)
        } catch {
            // Roll back on failure.
            reactions[m.id] = existing
            self.error = error.localizedDescription
        }
    }

    private func handleMessageInserted(_ note: Notification) {
        guard let lid = note.userInfo?["leagueID"] as? String, lid == league.id,
              let msg = note.userInfo?["message"] as? LeagueMessage else { return }
        if messages.contains(where: { $0.id == msg.id }) { return }
        // Realtime payloads don't include the username; pull from cache.
        var hydrated = msg
        if hydrated.username == nil, let name = usernamesByID[msg.userID] {
            hydrated = LeagueMessage(
                id: msg.id, leagueID: msg.leagueID, userID: msg.userID,
                username: name, content: msg.content,
                imageURL: msg.imageURL, createdAt: msg.createdAt,
                kind: msg.kind, payload: msg.payload
            )
        }
        messages.append(hydrated)
    }

    // A message's payload changed (e.g. a member added a poll option). Replace
    // it in place, keeping the locally-known username and original timestamp
    // (realtime payloads don't carry the joined profile).
    private func handleMessageUpdated(_ note: Notification) {
        guard let lid = note.userInfo?["leagueID"] as? String, lid == league.id,
              let msg = note.userInfo?["message"] as? LeagueMessage,
              let idx = messages.firstIndex(where: { $0.id == msg.id }) else { return }
        let existing = messages[idx]
        messages[idx] = LeagueMessage(
            id: msg.id, leagueID: msg.leagueID, userID: msg.userID,
            username: existing.username ?? msg.username,
            content: msg.content, imageURL: msg.imageURL,
            createdAt: existing.createdAt, kind: msg.kind, payload: msg.payload
        )
    }

    private func handleMessageDeleted(_ note: Notification) {
        guard let lid = note.userInfo?["leagueID"] as? String, lid == league.id,
              let id = note.userInfo?["id"] as? String else { return }
        messages.removeAll { $0.id == id }
        reactions[id] = nil
        responses[id] = nil
    }

    private func handleReactionInserted(_ note: Notification) {
        guard let lid = note.userInfo?["leagueID"] as? String, lid == league.id,
              let reaction = note.userInfo?["reaction"] as? LeagueMessageReaction else { return }
        // Only track reactions for messages we have loaded.
        guard messages.contains(where: { $0.id == reaction.messageID }) else { return }
        var list = reactions[reaction.messageID] ?? []
        if !list.contains(reaction) {
            list.append(reaction)
            reactions[reaction.messageID] = list
        }
    }

    private func handleReactionDeleted(_ note: Notification) {
        guard let lid = note.userInfo?["leagueID"] as? String, lid == league.id,
              let reaction = note.userInfo?["reaction"] as? LeagueMessageReaction else { return }
        guard var list = reactions[reaction.messageID] else { return }
        list.removeAll { $0 == reaction }
        reactions[reaction.messageID] = list.isEmpty ? nil : list
    }

    private func handleResponseChanged(_ note: Notification) {
        guard let lid = note.userInfo?["leagueID"] as? String, lid == league.id,
              let response = note.userInfo?["response"] as? MessageResponse else { return }
        guard messages.contains(where: { $0.id == response.messageID }) else { return }
        var list = responses[response.messageID] ?? []
        list.removeAll { $0.userID == response.userID && $0.slot == response.slot }
        list.append(response)
        responses[response.messageID] = list
    }

    private func handleResponseDeleted(_ note: Notification) {
        guard let lid = note.userInfo?["leagueID"] as? String, lid == league.id,
              let response = note.userInfo?["response"] as? MessageResponse else { return }
        guard var list = responses[response.messageID] else { return }
        list.removeAll { $0.userID == response.userID && $0.slot == response.slot }
        responses[response.messageID] = list.isEmpty ? nil : list
    }

    private func cacheUsernames(from list: [LeagueMessage]) {
        for m in list {
            if let name = m.username { usernamesByID[m.userID] = name }
        }
    }

    private struct PendingImage: Equatable {
        let data: Data
        let contentType: String
    }
}

// Which structured-card builder sheet the composer's "+" menu is presenting.
enum ComposeSheet: Identifiable {
    case poll, pickem, tradeblock
    var id: Int {
        switch self {
        case .poll:       return 0
        case .pickem:     return 1
        case .tradeblock: return 2
        }
    }
}
