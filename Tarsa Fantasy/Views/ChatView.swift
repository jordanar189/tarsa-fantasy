import SwiftUI

// Top-level chat tab. Surfaces both league chats and 1:1 DMs in a single
// conversation list — tap any row to enter that conversation. Pending
// friend requests appear at the top so they're impossible to miss; the
// toolbar has a "My profile" button (which is also the entry point to
// the user's full friends list) and a "new DM" picker.
struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var path = NavigationPath()
    @State private var showingNewDM = false
    @State private var showingFindPeople = false

    private var chatEligibleLeagues: [LeagueSummary] {
        app.leagueSummaries.filter { !$0.isTest }
    }

    private var conversations: [Conversation] {
        let leagues = chatEligibleLeagues.map(Conversation.league)
        let dms = app.dmInbox.map(Conversation.dm)
        return (leagues + dms).sorted { $0.sortDate > $1.sortDate }
    }

    private var pendingRequestsReceived: [Friendship] {
        guard let me = app.session?.userID else { return [] }
        return app.friendships.filter { $0.state == .pending && $0.requestedBy != me }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if let me = app.session?.userID {
                            path.append(ChatRoute.profile(me))
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(FFColor.textPrimary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFindPeople = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .foregroundStyle(FFColor.textPrimary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewDM = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .foregroundStyle(FFColor.textPrimary)
                    }
                }
            }
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .league(let summary):
                    LeagueRoomLoader(leagueID: summary.id)
                case .dm(let entry):
                    DMChatView(thread: entry.thread, otherUsername: entry.other.username)
                case .profile(let uid):
                    ProfileView(userID: uid)
                }
            }
            .task { await app.reloadFriendsAndDMs() }
            .refreshable {
                await app.reloadLeagues()
                await app.reloadFriendsAndDMs()
            }
            .sheet(isPresented: $showingNewDM) {
                NewDMPickerSheet { otherUserID in
                    showingNewDM = false
                    Task { await openDM(with: otherUserID) }
                }
            }
            .sheet(isPresented: $showingFindPeople) {
                FindPeopleSheet { userID in
                    showingFindPeople = false
                    path.append(ChatRoute.profile(userID))
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if conversations.isEmpty && pendingRequestsReceived.isEmpty {
            empty
        } else {
            ScrollView {
                VStack(spacing: FFSpace.l) {
                    if !pendingRequestsReceived.isEmpty {
                        requestsSection
                    }
                    if !conversations.isEmpty {
                        conversationsSection
                    }
                }
                .padding(FFSpace.l)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: FFSpace.l) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48, weight: .bold))
                .foregroundStyle(FFGradient.brand)
                .shadow(color: FFBrand.violet.opacity(0.30), radius: 14, y: 6)
            VStack(spacing: FFSpace.xs) {
                Text("Quiet on the wire")
                    .font(.ffTitle)
                    .foregroundStyle(FFColor.textPrimary)
                Text("Join a league to start trash talking — or shoot a friend a DM.")
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, FFSpace.xxl)
    }

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("Friend requests · \(pendingRequestsReceived.count)").ffEyebrow()
                Spacer()
            }
            ForEach(pendingRequestsReceived, id: \.id) { f in
                let otherID = f.otherUserID(me: app.session?.userID ?? "")
                Button {
                    path.append(ChatRoute.profile(otherID))
                } label: {
                    FriendRequestRow(userID: otherID)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var conversationsSection: some View {
        VStack(spacing: FFSpace.s) {
            ForEach(conversations) { conv in
                Button {
                    path.append(route(for: conv))
                } label: {
                    ConversationRow(conversation: conv)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func route(for conv: Conversation) -> ChatRoute {
        switch conv {
        case .league(let lg):       return .league(lg)
        case .dm(let entry):        return .dm(entry)
        }
    }

    private func openDM(with otherUserID: String) async {
        do {
            let thread = try await app.openDMThread(withUserID: otherUserID)
            let other = await app.profile(userID: otherUserID)
                ?? Profile(id: otherUserID, username: "Direct message")
            path.append(ChatRoute.dm(DMInboxEntry(thread: thread, other: other)))
        } catch {
            // No surfaced error UI here — the sheet has already dismissed.
            // Worst case the user re-attempts. A toast system would be a
            // proper follow-up but isn't in this codebase yet.
        }
    }
}

// MARK: - Routes

enum ChatRoute: Hashable {
    case league(LeagueSummary)
    case dm(DMInboxEntry)
    case profile(String)
}

// MARK: - Rows

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: FFSpace.m) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: FFSpace.s) {
                    Text(title)
                        .font(.ffHeadline)
                        .foregroundStyle(FFColor.textPrimary)
                        .lineLimit(1)
                    if case .league = conversation {
                        FFPill { Text("LEAGUE") }
                    } else {
                        FFPill { Text("DM") }
                    }
                }
                Text(subtitle)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
    }

    private var title: String {
        switch conversation {
        case .league(let lg):    return lg.name
        case .dm(let entry):     return entry.other.username
        }
    }

    private var subtitle: String {
        switch conversation {
        case .league(let lg):
            return "\(lg.teamCount) members · \(lg.scoring.label)"
        case .dm:
            return "Direct message"
        }
    }

    private var avatar: some View {
        let initials: String = {
            switch conversation {
            case .league(let lg):    return lg.name.initialsFromName
            case .dm(let entry):     return entry.other.username.initialsFromName
            }
        }()
        let symbol: String? = {
            if case .league = conversation { return "trophy.fill" }
            return nil
        }()
        return ZStack {
            if symbol != nil {
                Circle().fill(FFGradient.brand)
            } else {
                Circle().fill(FFColor.surfaceElevated)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.ffCaption.bold())
                    .foregroundStyle(FFColor.textSecondary)
            }
        }
        .frame(width: 42, height: 42)
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 1))
    }
}

private struct FriendRequestRow: View {
    @Environment(AppState.self) private var app
    let userID: String
    @State private var profile: Profile? = nil

    var body: some View {
        HStack(spacing: FFSpace.m) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.username ?? "…")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Text("Wants to be friends")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
        .task(id: userID) { profile = await app.profile(userID: userID) }
    }

    private var avatar: some View {
        let name = profile?.username ?? "?"
        return ZStack {
            Circle().fill(FFColor.surfaceElevated)
            Text(name.initialsFromName)
                .font(.ffCaption.bold())
                .foregroundStyle(FFColor.textSecondary)
        }
        .frame(width: 42, height: 42)
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 1))
    }
}

// MARK: - League room loader

// Loads a League by id so we can mount LeagueChatView (which needs the
// full league object). Stays out of the row tap path so the inbox doesn't
// block on per-league fetches.
private struct LeagueRoomLoader: View {
    @Environment(AppState.self) private var app
    let leagueID: String
    @State private var league: League? = nil

    var body: some View {
        Group {
            if let league {
                LeagueChatView(league: league)
                    .navigationTitle(league.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(FFColor.bg, for: .navigationBar)
            } else {
                ZStack {
                    FFColor.bg.ignoresSafeArea()
                    ProgressView().tint(FFColor.accent)
                }
                .navigationTitle("League chat")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: leagueID) {
            league = await app.league(leagueID)
        }
    }
}

// MARK: - New DM picker

private struct NewDMPickerSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void

    private var friends: [String] {
        guard let me = app.session?.userID else { return [] }
        return app.friendships
            .filter { $0.state == .accepted }
            .map { $0.otherUserID(me: me) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                if friends.isEmpty {
                    empty
                } else {
                    ScrollView {
                        VStack(spacing: FFSpace.s) {
                            ForEach(friends, id: \.self) { uid in
                                Button {
                                    onPick(uid)
                                } label: {
                                    FriendPickerRow(userID: uid)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(FFSpace.l)
                    }
                }
            }
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "person.2")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No friends yet")
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
            Text("Tap a leaguemate's name in a league chat to view their profile and send a friend request.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, FFSpace.xxl)
    }
}

private struct FriendPickerRow: View {
    @Environment(AppState.self) private var app
    let userID: String
    @State private var profile: Profile? = nil

    var body: some View {
        HStack(spacing: FFSpace.m) {
            let name = profile?.username ?? "…"
            ZStack {
                Circle().fill(FFColor.surfaceElevated)
                Text(name.initialsFromName)
                    .font(.ffCaption.bold())
                    .foregroundStyle(FFColor.textSecondary)
            }
            .frame(width: 36, height: 36)
            .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 1))

            Text(name)
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
        .task(id: userID) { profile = await app.profile(userID: userID) }
    }
}

// MARK: - Find people sheet

// Username search across every profile in the system. Tap a result to open
// that user's ProfileView, where the Add Friend / Message actions live.
// Search is debounced (~250ms) and excludes the signed-in user.
private struct FindPeopleSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void

    @State private var query: String = ""
    @State private var results: [Profile] = []
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var isSearching: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                VStack(spacing: FFSpace.l) {
                    searchField
                    content
                }
                .padding(FFSpace.l)
            }
            .navigationTitle("Find people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: FFSpace.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
            TextField("", text: $query, prompt:
                Text("Search by username").foregroundColor(FFColor.textTertiary)
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.ffBody)
            .foregroundStyle(FFColor.textPrimary)
            .onChange(of: query) { _, new in scheduleSearch(new) }
            if !query.isEmpty {
                Button {
                    query = ""
                    results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FFColor.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            hint
        } else if isSearching && results.isEmpty {
            ProgressView().tint(FFColor.accent).padding(.top, FFSpace.xl)
            Spacer()
        } else if results.isEmpty {
            empty
        } else {
            ScrollView {
                VStack(spacing: FFSpace.s) {
                    ForEach(results) { p in
                        Button {
                            onPick(p.id)
                        } label: {
                            FindPeopleRow(profile: p)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var hint: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("Type a username to find anyone on Tarsa.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FFSpace.xxl)
    }

    private var empty: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No matches.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FFSpace.xxl)
    }

    private func scheduleSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let found = await app.searchUsers(query: trimmed)
            if Task.isCancelled { return }
            results = found
            isSearching = false
        }
    }
}

private struct FindPeopleRow: View {
    @Environment(AppState.self) private var app
    let profile: Profile

    private var status: FriendshipStatus { app.friendshipStatus(otherUserID: profile.id) }

    var body: some View {
        HStack(spacing: FFSpace.m) {
            ZStack {
                Circle().fill(FFColor.surfaceElevated)
                Text(profile.username.initialsFromName)
                    .font(.ffCaption.bold())
                    .foregroundStyle(FFColor.textSecondary)
            }
            .frame(width: 36, height: 36)
            .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.username)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                if let label = statusLabel {
                    Text(label)
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
    }

    private var statusLabel: String? {
        switch status {
        case .none:            return nil
        case .friends:         return "Friends"
        case .requestSent:     return "Request sent"
        case .requestReceived: return "Wants to be friends"
        }
    }
}

#Preview {
    ChatView().environment(AppState.preview)
}
