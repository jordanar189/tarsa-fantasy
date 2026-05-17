import SwiftUI

// League-scoped live chat. Owns its own ScrollViewReader + composer so it
// renders as a full-screen surface (parent should NOT wrap this in another
// ScrollView). Subscribes to LeagueChatListener on appear; messages from
// other users land via NotificationCenter and append in place.
struct LeagueChatView: View {
    @Environment(AppState.self) private var app
    let league: League

    @State private var messages: [LeagueMessage] = []
    @State private var draft: String = ""
    @State private var sending: Bool = false
    @State private var loaded: Bool = false
    @State private var error: String? = nil
    @State private var usernamesByID: [String: String] = [:]
    @FocusState private var composerFocused: Bool

    private var myUserID: String? { app.session?.userID }

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
            handleInserted(note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .leagueChatMessageDeleted)) { note in
            handleDeleted(note)
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
                        Text(displayName(for: m))
                            .font(.ffCaption.bold())
                            .foregroundStyle(FFColor.textSecondary)
                        Text(m.createdAt.formatted(.dateTime.hour().minute()))
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                        if !isMine { Spacer(minLength: 0) }
                    }
                }
                Text(m.content)
                    .font(.ffBody)
                    .foregroundStyle(isMine ? FFColor.bg : FFColor.textPrimary)
                    .padding(.horizontal, FFSpace.m)
                    .padding(.vertical, FFSpace.s)
                    .background(
                        isMine ? FFColor.accent : FFColor.surface,
                        in: RoundedRectangle(cornerRadius: FFRadius.m)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.m)
                            .strokeBorder(
                                isMine ? Color.clear : FFColor.border,
                                lineWidth: 1
                            )
                    )
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = m.content
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                        if isMine || isCommissioner {
                            Button(role: .destructive) {
                                Task { await delete(m) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
            }
            .frame(maxWidth: 260, alignment: isMine ? .trailing : .leading)

            if !isMine { Spacer(minLength: FFSpace.xxl) }
        }
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

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: FFSpace.s) {
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
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? FFColor.accent : FFColor.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend || sending)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .background(FFColor.bg)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func initialLoad() async {
        loaded = false
        messages = await app.leagueMessages(leagueID: league.id)
        cacheUsernames(from: messages)
        loaded = true
        await LeagueChatListener.shared.start(leagueID: league.id)
    }

    private func send() async {
        let text = draft
        draft = ""
        sending = true
        defer { sending = false }
        do {
            let posted = try await app.sendLeagueMessage(leagueID: league.id, content: text)
            // Realtime echoes our INSERT — append locally only if it hasn't
            // already landed, so we don't double-render.
            if !messages.contains(where: { $0.id == posted.id }) {
                messages.append(posted)
            }
            if let name = posted.username { usernamesByID[posted.userID] = name }
        } catch {
            draft = text   // restore so the user doesn't lose what they typed
            self.error = error.localizedDescription
        }
    }

    private func delete(_ m: LeagueMessage) async {
        await app.deleteLeagueMessage(id: m.id)
        // Realtime DELETE will also fire — local removal here keeps the
        // UI snappy in case the network lags.
        messages.removeAll { $0.id == m.id }
    }

    private func handleInserted(_ note: Notification) {
        guard let lid = note.userInfo?["leagueID"] as? String, lid == league.id,
              let msg = note.userInfo?["message"] as? LeagueMessage else { return }
        if messages.contains(where: { $0.id == msg.id }) { return }
        // Realtime payloads don't include the username; pull from cache.
        var hydrated = msg
        if hydrated.username == nil, let name = usernamesByID[msg.userID] {
            hydrated = LeagueMessage(
                id: msg.id, leagueID: msg.leagueID, userID: msg.userID,
                username: name, content: msg.content, createdAt: msg.createdAt
            )
        }
        messages.append(hydrated)
    }

    private func handleDeleted(_ note: Notification) {
        guard let lid = note.userInfo?["leagueID"] as? String, lid == league.id,
              let id = note.userInfo?["id"] as? String else { return }
        messages.removeAll { $0.id == id }
    }

    private func cacheUsernames(from list: [LeagueMessage]) {
        for m in list {
            if let name = m.username { usernamesByID[m.userID] = name }
        }
    }
}
