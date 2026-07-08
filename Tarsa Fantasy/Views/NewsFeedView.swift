import SwiftUI

// League-wide NFL headlines (player_news, mirrored hourly from ESPN).
// Rows open the article in the browser; tagged players render as chips
// that open the player profile.
struct NewsFeedView: View {
    @Environment(AppState.self) private var app

    @State private var items: [PlayerNewsItem] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(spacing: FFSpace.m) {
                if !loaded {
                    ProgressView().tint(FFColor.accent).padding(.top, FFSpace.xxl)
                } else if items.isEmpty {
                    emptyState
                } else {
                    ForEach(items) { item in
                        NewsCard(item: item, players: app.displaySelectedPlayers())
                    }
                }
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.bottom, 40)
        }
        .refreshable { await reload() }
        .task {
            guard !loaded else { return }
            await reload()
        }
    }

    private func reload() async {
        items = await app.news(limit: 50)
        loaded = true
    }

    private var emptyState: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "newspaper")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No headlines yet")
                .font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
            Text("News lands here within the hour once the season is rolling. Pull to refresh.")
                .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, FFSpace.xxl)
        .frame(maxWidth: .infinity)
    }
}

// One headline card, shared by the feed and the player page.
struct NewsCard: View {
    let item: PlayerNewsItem
    var players: [String: Player] = [:]
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            articleBody
            if !compact, !item.playerIDs.isEmpty {
                playerChips
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffCard()
    }

    @ViewBuilder
    private var articleBody: some View {
        // The whole headline block links out; player chips below keep their
        // own in-app taps.
        let content = VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: FFSpace.m) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.headline)
                        .font(.ffHeadline)
                        .foregroundStyle(FFColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    if !compact, let desc = item.description, !desc.isEmpty {
                        Text(desc)
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textSecondary)
                            .lineLimit(3)
                    }
                    Text(item.published.shortRelative)
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
                if !compact, let img = item.imageURL, let u = URL(string: img) {
                    AsyncImage(url: u) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            FFColor.surfaceElevated
                        }
                    }
                    .frame(width: 72, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: FFRadius.s))
                }
            }
        }
        if let url = item.url.flatMap(URL.init(string:)) {
            Link(destination: url) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var playerChips: some View {
        HStack(spacing: FFSpace.s) {
            ForEach(item.playerIDs.prefix(3), id: \.self) { pid in
                if let p = players[pid] {
                    HStack(spacing: 4) {
                        PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName, size: 18)
                        Text(p.name).font(.ffMicro).foregroundStyle(FFColor.textSecondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(FFColor.surfaceElevated, in: Capsule())
                    .playerLink(pid)
                }
            }
        }
    }
}
