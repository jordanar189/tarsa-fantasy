import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(AppState.self) private var app

    init() {
        // Nav bar: use dynamic UIColors that resolve to dark or light per the
        // current trait collection. SwiftUI's parent preferredColorScheme
        // override flips the trait so these surfaces follow along automatically.
        let bgDynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 1)
                : UIColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        }
        let titleDynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.91, green: 0.92, blue: 0.95, alpha: 1)
                : UIColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1)
        }

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = bgDynamic
        navAppearance.shadowColor = .clear
        navAppearance.titleTextAttributes = [.foregroundColor: titleDynamic]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: titleDynamic]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
    }

    var body: some View {
        @Bindable var app = app
        Group {
            if app.session == nil {
                AuthGateView()
            } else if app.selectedLeagueID == nil {
                // No league in focus → the overview/landing screen, where you
                // pick, create, or join a league (and reach DMs).
                LeagueOverviewView()
            } else {
                mainTabs
            }
        }
        .preferredColorScheme(app.theme.preferredColorScheme)
        .tint(FFColor.accent)
        .sheet(item: $app.presentedPlayerID.asIdentifiable) { id in
            PlayerDetailView(playerID: id.id)
                .presentationDetents([.large])
        }
    }

    private var mainTabs: some View {
        LeagueShellView()
            // Pinned to the top edge so it doesn't shift any content.
            .overlay(alignment: .top) {
                TopRefreshIndicator(isActive: app.isRefreshingSeason)
            }
            .overlay {
                if let error = app.bootstrapError {
                    bootstrapErrorOverlay(error)
                }
            }
            // App-wide feedback button, shown only to testers/admins.
            .overlay {
                if app.canGiveFeedback {
                    FeedbackButton()
                }
            }
    }

    private func bootstrapErrorOverlay(_ error: String) -> some View {
        VStack(spacing: FFSpace.m) {
            FFBrandMark(size: .small)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(FFColor.warning)
            Text("Couldn't load NFL data")
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
            Text(error)
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, FFSpace.l)
            Button("Retry") {
                Task { await app.bootstrap(force: true) }
            }
            .ffPrimaryButton()
            .padding(.horizontal, FFSpace.xl)
        }
        .padding(FFSpace.xxl)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.l))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.l)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
        .padding(40)
    }
}

// The league-focused experience: a custom bottom tab bar (League · Lineup ·
// Matchup · Players) with a Sleeper-style pull-up league chat that peeks above
// the bar. The chat is a custom panel rather than a sheet so its bottom edge
// rests on top of the tab bar — pulling it up grows it upward and never covers
// the bar.
struct LeagueShellView: View {
    @Environment(AppState.self) private var app

    @State private var chatExpanded = false
    @State private var bodyMounted = false      // chat content lives only while open
    @State private var isDragging = false
    @State private var dragOffset: CGFloat = 0   // positive = dragged up = taller
    @State private var keyboardHeight: CGFloat = 0
    // Seeded with the cold-start default so the first tab renders on frame one
    // (onAppear inserts the live value a tick later for any other entry point).
    @State private var visited: Set<AppTab> = [.league]

    // Chat peek header height; the small gap left above an expanded panel.
    private let peekHeight: CGFloat = 56
    private let topGap: CGFloat = 8

    private static let tabOrder: [AppTab] = [.league, .lineup, .matchup, .players]

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .bottom) {
            tabContent
                // Reserve room for the tab bar + chat peek so scroll content
                // never hides behind them.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: CustomTabBar.height + peekHeight)
                }

            chatLayer

            CustomTabBar(selection: $app.tab)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .onAppear { visited.insert(app.tab) }
        .onChange(of: app.tab) { _, t in
            visited.insert(t)
            // Switching tabs from the bar (which stays on top of the expanded
            // chat) should drop the chat back down to reveal the new tab.
            if chatExpanded { collapse() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            let dur = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: dur)) { keyboardHeight = frame.height }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            let dur = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: dur)) { keyboardHeight = 0 }
        }
    }

    // All four tab roots are kept alive once visited (so per-tab state survives
    // a switch), shown/hidden by opacity the way a TabView does. Lazy so a tab's
    // data only loads after it's first opened.
    private var tabContent: some View {
        ZStack {
            ForEach(Self.tabOrder, id: \.self) { tab in
                if visited.contains(tab) {
                    tabRoot(tab)
                        .opacity(app.tab == tab ? 1 : 0)
                        .allowsHitTesting(app.tab == tab)
                        .zIndex(app.tab == tab ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private func tabRoot(_ tab: AppTab) -> some View {
        switch tab {
        case .league:  LeagueTabView()
        case .lineup:  LineupTabView()
        case .matchup: MatchupTabView()
        case .players: NFLHubView()
        }
    }

    // The pull-up chat. Anchored so its bottom edge rests on top of the tab bar;
    // it grows upward when expanded and, when the keyboard appears, shrinks from
    // the bottom to sit on the keyboard so the composer stays visible.
    @ViewBuilder
    private var chatLayer: some View {
        if let lg = app.selectedLeague {
            // The reader ignores the bottom safe area (and keyboard), so it
            // spans down to the device's bottom edge and `geo.safeAreaInsets`
            // reports the real home-indicator inset — no UIKit lookup needed.
            GeometryReader { geo in
                let sab = geo.safeAreaInsets.bottom   // home indicator
                let sat = geo.safeAreaInsets.top      // status bar (0 here)
                let available = geo.size.height
                let navPad = CustomTabBar.height + sab
                let expandedH = max(peekHeight, available - navPad - sat - topGap)
                let kb = chatExpanded ? keyboardHeight : 0
                // With the keyboard up, lift the panel's bottom to the keyboard's
                // top edge; otherwise rest it on top of the tab bar.
                let bottomPad = kb > 0 ? max(navPad, kb) : navPad
                let dragged = min(max((chatExpanded ? expandedH : peekHeight) + dragOffset, peekHeight), expandedH)
                // While the keyboard is up, pin the top and let the panel shrink
                // onto the keyboard instead of sliding off the top of the screen.
                let live = kb > 0 ? max(peekHeight, available - sat - topGap - bottomPad) : dragged
                let progress = Double((live - peekHeight) / max(1, expandedH - peekHeight))

                ZStack(alignment: .bottom) {
                    if bodyMounted {
                        Color.black.opacity(0.45 * progress)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { collapse() }
                            .allowsHitTesting(chatExpanded && !isDragging)
                    }
                    chatPanel(lg, height: live, expandedH: expandedH)
                        .padding(.bottom, bottomPad)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private func chatPanel(_ lg: League, height: CGFloat, expandedH: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 18, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: 18
        )
        return VStack(spacing: 0) {
            LeagueChatTopBar(onClose: chatExpanded ? { collapse() } : nil)
                .contentShape(Rectangle())
                .onTapGesture { chatExpanded ? collapse() : expand() }
                .gesture(dragGesture(expandedH: expandedH))
            if bodyMounted {
                Divider().background(FFColor.border)
                LeagueChatView(league: lg)
            }
        }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(FFColor.surface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(FFColor.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: -4)
    }

    private func dragGesture(expandedH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                isDragging = true
                dragOffset = -value.translation.height
                if dragOffset > 4 { bodyMounted = true }
            }
            .onEnded { value in
                isDragging = false
                let predicted = -value.predictedEndTranslation.height
                let target = (chatExpanded ? expandedH : peekHeight) + predicted
                if target > (peekHeight + expandedH) / 2 { expand() } else { collapse() }
            }
    }

    private func expand() {
        bodyMounted = true
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            chatExpanded = true
            dragOffset = 0
        }
    }

    private func collapse() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        // Keep the chat mounted through the close animation, then tear down its
        // realtime listener once the panel has settled.
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            chatExpanded = false
            dragOffset = 0
        } completion: {
            if !chatExpanded { bodyMounted = false }
        }
    }
}

// Custom bottom navigation bar styled to match the app: brand-gradient active
// tab, surface fill, hairline top border. Fills the full width and extends its
// background under the home indicator.
struct CustomTabBar: View {
    @Binding var selection: AppTab

    static let height: CGFloat = 56

    private static let items: [(tab: AppTab, label: String, icon: String)] = [
        (.league,  "League",  "trophy.fill"),
        (.lineup,  "Lineup",  "list.bullet.rectangle.portrait.fill"),
        (.matchup, "Matchup", "person.2.fill"),
        (.players, "Players", "football.fill"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.items, id: \.tab) { item in
                let selected = selection == item.tab
                Button {
                    if selection != item.tab {
                        withAnimation(.easeInOut(duration: 0.15)) { selection = item.tab }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 20, weight: .semibold))
                        Text(item.label)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(
                        selected
                            ? AnyShapeStyle(FFGradient.brand)
                            : AnyShapeStyle(FFColor.textSecondary)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            FFColor.surface
                .overlay(alignment: .top) {
                    Rectangle().fill(FFColor.border).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

// Hosts the selected league's detail screen as a tab root. The league switcher
// bubble lives at the top of LeagueDetailView's content.
struct LeagueTabView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            if let id = app.selectedLeagueID {
                LeagueDetailView(leagueID: id)
            } else {
                Color.clear
            }
        }
    }
}

// The shared "top of the chat page": a grabber + title row. Used both as the
// collapsed peek (resting on top of the tab bar) and as the header of the
// expanded panel, so pulling the peek up reads as the same page rising.
// `onClose` is nil for the peek and set when expanded (collapse button).
struct LeagueChatTopBar: View {
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(FFColor.borderStrong)
                .frame(width: 38, height: 5)
                .padding(.top, 8)
            HStack(spacing: FFSpace.s) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FFColor.accent)
                Text("League chat")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
        .background(FFColor.surface)
    }
}

#Preview {
    ContentView().environment(AppState.preview)
}
