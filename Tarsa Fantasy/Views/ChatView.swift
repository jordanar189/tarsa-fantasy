import SwiftUI

// Top-level chat tab. Renders the league-scoped chat for whichever
// league the user picks via the toolbar menu. Sim leagues are excluded —
// chat is real-leagues only, mirroring the previous in-league behavior.
struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var selectedLeagueID: String? = nil
    @State private var league: League? = nil
    @State private var loading: Bool = false

    private var chatEligibleLeagues: [LeagueSummary] {
        app.leagueSummaries.filter { !$0.isTest }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar { leaguePickerToolbar }
            .task { await app.reloadLeagues() }
            .task(id: selectedLeagueID) { await loadLeague() }
            .onAppear { syncSelection() }
            .onChange(of: chatEligibleLeagues) { _, _ in syncSelection() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if chatEligibleLeagues.isEmpty {
            emptyState
        } else if let league {
            // .id forces a fresh view (and fresh @State) when the user
            // swaps leagues, so drafts/usernames don't leak across chats.
            LeagueChatView(league: league)
                .id(league.id)
        } else if loading {
            ProgressView().tint(FFColor.accent)
        } else {
            pickPrompt
        }
    }

    private var emptyState: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No leagues yet")
                .font(.ffTitle)
                .foregroundStyle(FFColor.textPrimary)
            Text("Join or create a league to start chatting with your leaguemates.")
                .font(.ffBody)
                .foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, FFSpace.xxl)
    }

    private var pickPrompt: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("Pick a league to chat with")
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
        }
    }

    @ToolbarContentBuilder
    private var leaguePickerToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if !chatEligibleLeagues.isEmpty {
                Menu {
                    ForEach(chatEligibleLeagues) { lg in
                        Button {
                            selectedLeagueID = lg.id
                        } label: {
                            if lg.id == selectedLeagueID {
                                Label(lg.name, systemImage: "checkmark")
                            } else {
                                Text(lg.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentLeagueLabel)
                            .font(.ffHeadline)
                            .foregroundStyle(FFColor.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
        }
    }

    private var currentLeagueLabel: String {
        chatEligibleLeagues.first(where: { $0.id == selectedLeagueID })?.name ?? "Chat"
    }

    private func syncSelection() {
        if let id = selectedLeagueID,
           chatEligibleLeagues.contains(where: { $0.id == id }) {
            return
        }
        selectedLeagueID = chatEligibleLeagues.first?.id
    }

    private func loadLeague() async {
        guard let id = selectedLeagueID else {
            league = nil
            return
        }
        if league?.id == id { return }
        loading = true
        defer { loading = false }
        league = await app.league(id)
    }
}

#Preview {
    ChatView().environment(AppState.preview)
}
