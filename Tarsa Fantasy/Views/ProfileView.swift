import SwiftUI

// Public user profile. Renders for either the signed-in user (no friend
// actions; shows their friend list and pending requests) or another user
// (shows the appropriate friend action + a Message button that creates or
// re-opens a DM thread). Navigates to DMChatView when the user taps
// Message.
struct ProfileView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let userID: String

    @State private var profile: Profile? = nil
    @State private var loading: Bool = true
    @State private var actionInFlight: Bool = false
    @State private var error: String? = nil
    @State private var openingThread: DMThread? = nil
    @State private var testerWorking: Bool = false

    private var isMe: Bool { userID == app.session?.userID }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: FFSpace.xl) {
                    header
                    if isMe {
                        myProfileSections
                    } else {
                        otherProfileSections
                    }
                    if let error {
                        Text(error)
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.warning)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, FFSpace.l)
                .padding(.top, FFSpace.l)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(profile?.username ?? "Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .task(id: userID) { await load() }
        .navigationDestination(item: $openingThread) { thread in
            DMChatView(thread: thread, otherUsername: profile?.username ?? "Direct message")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: FFSpace.m) {
            avatar
            if loading && profile == nil {
                ProgressView().tint(FFColor.accent)
            } else {
                Text(profile?.username ?? "Unknown user")
                    .font(.ffTitle)
                    .foregroundStyle(FFColor.textPrimary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FFSpace.l)
    }

    private var avatar: some View {
        let name = profile?.username ?? "?"
        return ZStack {
            Circle().fill(FFColor.surfaceElevated)
            Text(name.initialsFromName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(FFColor.textPrimary)
        }
        .frame(width: 96, height: 96)
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 1))
    }

    @ViewBuilder
    private var otherProfileSections: some View {
        actionButtons
        if app.isAdmin {
            adminTesterSection
        }
    }

    @ViewBuilder
    private var adminTesterSection: some View {
        let isTester = profile?.isTester ?? false
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack { Text("Admin").ffEyebrow(); Spacer() }
            VStack(alignment: .leading, spacing: FFSpace.s) {
                HStack(spacing: FFSpace.s) {
                    Image(systemName: isTester ? "checkmark.seal.fill" : "seal")
                        .foregroundStyle(isTester ? FFColor.positive : FFColor.textTertiary)
                    Text(isTester ? "Tester" : "Not a tester")
                        .font(.ffHeadline)
                        .foregroundStyle(FFColor.textPrimary)
                    Spacer()
                }
                Text("Testers see the in-app feedback button everywhere.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
                Button {
                    Task { await toggleTester(to: !isTester) }
                } label: {
                    if testerWorking {
                        ProgressView().tint(FFColor.accent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            isTester ? "Remove tester role" : "Make tester",
                            systemImage: isTester ? "person.badge.minus" : "person.badge.plus"
                        )
                    }
                }
                .ffSecondaryButton()
                .disabled(testerWorking)
            }
            .ffCard()
        }
    }

    @ViewBuilder
    private var myProfileSections: some View {
        pendingRequestsSection
        friendsSection
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: FFSpace.s) {
            friendActionButton
            Button {
                Task { await openDM() }
            } label: {
                if actionInFlight {
                    ProgressView().tint(FFColor.bg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, FFSpace.s)
                } else {
                    Label("Message", systemImage: "paperplane.fill")
                }
            }
            .ffPrimaryButton()
        }
    }

    @ViewBuilder
    private var friendActionButton: some View {
        let status = app.friendshipStatus(otherUserID: userID)
        switch status {
        case .none:
            Button {
                Task { await sendRequest() }
            } label: {
                Label("Add friend", systemImage: "person.crop.circle.badge.plus")
            }
            .ffSecondaryButton()
            .disabled(actionInFlight)
        case .requestSent:
            Button {
                Task { await cancelOrRemove() }
            } label: {
                Label("Request sent · Cancel", systemImage: "clock")
            }
            .ffSecondaryButton()
            .disabled(actionInFlight)
        case .requestReceived:
            HStack(spacing: FFSpace.s) {
                Button {
                    Task { await acceptRequest() }
                } label: {
                    Label("Accept", systemImage: "checkmark")
                }
                .ffPrimaryButton()
                .disabled(actionInFlight)

                Button {
                    Task { await cancelOrRemove() }
                } label: {
                    Label("Decline", systemImage: "xmark")
                }
                .ffSecondaryButton()
                .disabled(actionInFlight)
            }
        case .friends:
            Button(role: .destructive) {
                Task { await cancelOrRemove() }
            } label: {
                Label("Friends · Remove", systemImage: "checkmark.circle.fill")
            }
            .ffSecondaryButton()
            .disabled(actionInFlight)
        }
    }

    @ViewBuilder
    private var pendingRequestsSection: some View {
        let received = app.friendships.filter {
            $0.state == .pending && $0.requestedBy != app.session?.userID
        }
        if !received.isEmpty {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                HStack { Text("Friend requests").ffEyebrow(); Spacer() }
                ForEach(received, id: \.id) { f in
                    let otherID = f.otherUserID(me: app.session?.userID ?? "")
                    NavigationLink(value: ChatRoute.profile(otherID)) {
                        PendingRequestRow(userID: otherID)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var friendsSection: some View {
        let accepted = app.friendships.filter { $0.state == .accepted }
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack { Text("Friends").ffEyebrow(); Spacer() }
            if accepted.isEmpty {
                Text("No friends yet. Open a leaguemate's profile to send a friend request.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
                    .padding(.vertical, FFSpace.s)
            } else {
                ForEach(accepted, id: \.id) { f in
                    let otherID = f.otherUserID(me: app.session?.userID ?? "")
                    NavigationLink(value: ChatRoute.profile(otherID)) {
                        FriendRow(userID: otherID)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        loading = true
        defer { loading = false }
        profile = await app.profile(userID: userID)
        // Make sure the cached friendships are fresh — the friend action
        // button derives from app.friendshipStatus and we want it to
        // reflect server reality on every appearance.
        await app.reloadFriendsAndDMs()
    }

    private func sendRequest() async {
        actionInFlight = true
        defer { actionInFlight = false }
        do {
            _ = try await app.sendFriendRequest(toUserID: userID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func acceptRequest() async {
        actionInFlight = true
        defer { actionInFlight = false }
        do {
            _ = try await app.acceptFriendRequest(fromUserID: userID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancelOrRemove() async {
        actionInFlight = true
        defer { actionInFlight = false }
        do {
            try await app.removeFriendship(withUserID: userID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openDM() async {
        actionInFlight = true
        defer { actionInFlight = false }
        do {
            openingThread = try await app.openDMThread(withUserID: userID)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggleTester(to newValue: Bool) async {
        testerWorking = true
        defer { testerWorking = false }
        do {
            _ = try await app.setTesterRole(userID: userID, isTester: newValue)
            // Re-fetch so the toggle reflects server truth.
            profile = await app.profile(userID: userID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PendingRequestRow: View {
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
        .frame(width: 36, height: 36)
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 1))
    }
}

private struct FriendRow: View {
    @Environment(AppState.self) private var app
    let userID: String
    @State private var profile: Profile? = nil

    var body: some View {
        HStack(spacing: FFSpace.m) {
            avatar
            Text(profile?.username ?? "…")
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

    private var avatar: some View {
        let name = profile?.username ?? "?"
        return ZStack {
            Circle().fill(FFColor.surfaceElevated)
            Text(name.initialsFromName)
                .font(.ffCaption.bold())
                .foregroundStyle(FFColor.textSecondary)
        }
        .frame(width: 36, height: 36)
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 1))
    }
}
