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
        if let playerID, !playerID.isEmpty {
            Button {
                if let presenter { presenter(playerID) } else { app.showPlayer(playerID) }
            } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
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
