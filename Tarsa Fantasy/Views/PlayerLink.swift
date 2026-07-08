import SwiftUI

// Makes any view tap-to-open the player profile. Apply to a player's name (or
// name+avatar) anywhere in the app: `.playerLink(playerID)`. A nil/empty id is
// a no-op so empty lineup slots and unmatched rows stay inert. Uses .plain so
// it doesn't restyle the wrapped content, and works nested beside other rows.
//
// By default the tap opens the app-wide profile sheet hosted by ContentView
// (app.showPlayer). That host can't present over another sheet, so any screen
// that is itself presented as a sheet should add `.hostsPlayerProfileSheet()`
// to its content — that installs a local sheet host and routes the links inside
// it there instead (sheet-over-sheet, which SwiftUI handles correctly).
struct PlayerLinkModifier: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(\.playerProfilePresenter) private var presenter
    let playerID: String?

    func body(content: Content) -> some View {
        // Single, stable view type regardless of playerID so SwiftUI keeps the
        // wrapped content's identity when an empty slot fills in (no layout
        // flash). A nil/empty id makes the tap a no-op.
        let active = !(playerID ?? "").isEmpty
        return content
            .contentShape(Rectangle())
            .onTapGesture {
                guard active, let playerID else { return }
                if let presenter { presenter(playerID) } else { app.showPlayer(playerID) }
            }
            .accessibilityAddTraits(active ? .isButton : [])
    }
}

extension View {
    func playerLink(_ playerID: String?) -> some View {
        modifier(PlayerLinkModifier(playerID: playerID))
    }

    // Install a local player-profile sheet host. Use on the content of any view
    // that is presented as a sheet and contains `.playerLink`s, so taps open the
    // profile on top of that sheet rather than failing against the root host.
    func hostsPlayerProfileSheet() -> some View {
        modifier(PlayerProfileSheetHost())
    }
}

private struct PlayerProfileSheetHost: ViewModifier {
    @State private var playerID: String?

    func body(content: Content) -> some View {
        content
            .environment(\.playerProfilePresenter) { playerID = $0 }
            .sheet(item: $playerID.asIdentifiable) { id in
                PlayerDetailView(playerID: id.id)
                    .presentationDetents([.large])
            }
    }
}

private struct PlayerProfilePresenterKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var playerProfilePresenter: ((String) -> Void)? {
        get { self[PlayerProfilePresenterKey.self] }
        set { self[PlayerProfilePresenterKey.self] = newValue }
    }
}

// MARK: - NFL team links

// The team twin of `.playerLink`: makes an NFL team abbreviation (or logo)
// tap-to-open TeamProfileView. Same presenter/host split — screens that are
// themselves sheets add `.hostsTeamProfileSheet()`.
struct TeamLinkModifier: ViewModifier {
    @Environment(AppState.self) private var app
    @Environment(\.teamProfilePresenter) private var presenter
    let abbr: String?

    func body(content: Content) -> some View {
        let active = !(abbr ?? "").isEmpty
        return content
            .contentShape(Rectangle())
            .onTapGesture {
                guard active, let abbr else { return }
                if let presenter { presenter(abbr) } else { app.showTeam(abbr) }
            }
            .accessibilityAddTraits(active ? .isButton : [])
    }
}

extension View {
    func teamLink(_ abbr: String?) -> some View {
        modifier(TeamLinkModifier(abbr: abbr))
    }

    func hostsTeamProfileSheet() -> some View {
        modifier(TeamProfileSheetHost())
    }
}

private struct TeamProfileSheetHost: ViewModifier {
    @State private var abbr: String?

    func body(content: Content) -> some View {
        content
            .environment(\.teamProfilePresenter) { abbr = $0 }
            .sheet(item: $abbr.asIdentifiable) { id in
                TeamProfileLoaderView(abbr: id.id)
            }
    }
}

// Resolves an abbreviation to its NFLTeamMeta (cached in the data actor)
// before showing the profile — links only carry the abbr string.
struct TeamProfileLoaderView: View {
    @Environment(AppState.self) private var app
    let abbr: String

    @State private var meta: NFLTeamMeta? = nil

    var body: some View {
        Group {
            if let meta {
                TeamProfileView(team: meta)
            } else {
                ZStack {
                    FFColor.bg.ignoresSafeArea()
                    ProgressView().tint(FFColor.accent)
                }
            }
        }
        .task(id: abbr) {
            meta = await app.nflTeams().first(where: { $0.abbr == abbr })
        }
        .presentationDetents([.large])
    }
}

private struct TeamProfilePresenterKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var teamProfilePresenter: ((String) -> Void)? {
        get { self[TeamProfilePresenterKey.self] }
        set { self[TeamProfilePresenterKey.self] = newValue }
    }
}
