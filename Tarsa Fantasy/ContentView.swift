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
        .sheet(item: $app.presentedTeamAbbr.asIdentifiable) { id in
            TeamProfileLoaderView(abbr: id.id)
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

// The league-focused experience: a minimal two-tab bottom bar (Lineup ·
// Players) with a Sleeper-style pull-up league chat that peeks above the bar.
// League and Matchup screens are reached by drilling in from the Lineup tab
// (score-banner tap → Matchup, nav pills → League/Matchup), not as their own
// tabs. The chat is a custom panel rather than a sheet so its bottom edge
// rests on top of the tab bar — pulling it up grows it upward and never covers
// the bar.
struct LeagueShellView: View {
    @Environment(AppState.self) private var app

    @State private var chatExpanded = false
    @State private var showingInbox = false
    @State private var isDragging = false
    @State private var dragOffset: CGFloat = 0   // live drag: positive = dragged up
    @State private var keyboardHeight: CGFloat = 0
    // Device bottom safe area (home indicator), cached so the layout pass doesn't
    // walk the scene graph on every animation frame. Only used to seat the
    // composer on the keyboard, so it's refreshed on appear and on keyboard show.
    @State private var bottomSafeInset: CGFloat = 0
    // Seeded with the cold-start default so the first tab renders on frame one
    // (onAppear inserts the live value a tick later for any other entry point).
    @State private var visited: Set<AppTab> = [.lineup]

    // Chat peek header height; the small gap left above an expanded panel.
    private let peekHeight: CGFloat = 56
    private let topGap: CGFloat = 8

    private static let tabOrder: [AppTab] = [.lineup, .players]

    private static func deviceBottomInset() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .keyWindow?
            .safeAreaInsets.bottom ?? 0
    }

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
        .onAppear {
            visited.insert(app.tab)
            bottomSafeInset = Self.deviceBottomInset()
        }
        .onChange(of: app.tab) { _, t in
            visited.insert(t)
            // Switching tabs from the bar (which stays on top of the expanded
            // chat) should drop the chat back down to reveal the new tab.
            if chatExpanded { collapse() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            let dur = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            bottomSafeInset = Self.deviceBottomInset()
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
        case .lineup:  LineupTabView()
        case .players: NFLHubView()
        }
    }

    // The pull-up chat. The panel is laid out once at full height with its bottom
    // edge resting on top of the tab bar, then slid up/down with `.offset` —
    // dragging only translates a static view (no per-frame relayout or shadow
    // re-render), which keeps the motion smooth instead of stuttering.
    @ViewBuilder
    private var chatLayer: some View {
        if let lg = app.selectedLeague {
            // Reader respects the bottom safe area (so its bottom edge sits on the
            // home indicator = top of the tab bar) but ignores the keyboard so the
            // panel height stays stable while typing.
            GeometryReader { geo in
                let available = geo.size.height
                let fullH = max(peekHeight, available - CustomTabBar.height - topGap)
                let collapseDist = fullH - peekHeight
                let kb = chatExpanded ? keyboardHeight : 0
                // Raise the composer onto the keyboard by shrinking the panel from
                // the bottom (the top stays put, so the header stays reachable).
                // Only changes on keyboard show/hide, never during a drag.
                let keyboardLift = kb > 0 ? max(0, kb - bottomSafeInset - CustomTabBar.height) : 0
                let panelHeight = max(peekHeight, fullH - keyboardLift)
                let bottomPad = CustomTabBar.height + keyboardLift
                // Collapse/expand is a pure translation of the fixed-size panel.
                let offsetY = min(max((chatExpanded ? 0 : collapseDist) - dragOffset, 0), collapseDist)
                let progress = collapseDist > 0 ? max(0, min(1, 1 - offsetY / collapseDist)) : 0

                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.45 * Double(progress))
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { collapse() }
                        .allowsHitTesting(chatExpanded && !isDragging)

                    chatPanel(lg, height: panelHeight, collapseDist: collapseDist)
                        .padding(.bottom, bottomPad)
                        .offset(y: offsetY)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    private func chatPanel(_ lg: League, height: CGFloat, collapseDist: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 18, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: 18
        )
        return VStack(spacing: 0) {
            LeagueChatTopBar(
                onClose: chatExpanded ? { collapse() } : nil,
                onOpenInbox: { showingInbox = true }
            )
                .contentShape(Rectangle())
                .onTapGesture { chatExpanded ? collapse() : expand() }
                .gesture(dragGesture(collapseDist: collapseDist))
            Divider().background(FFColor.border)
            LeagueChatView(league: lg)
        }
        .sheet(isPresented: $showingInbox) { ChatView() }
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(FFColor.surface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(FFColor.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: -4)
    }

    private func dragGesture(collapseDist: CGFloat) -> some Gesture {
        // Measure in the global space, not the panel's local space: the panel is
        // moved by .offset(y:) driven by this same gesture, so a local-space
        // translation would shift with the panel and feed back into itself,
        // making the drag stutter back and forth.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                isDragging = true
                dragOffset = -value.translation.height
            }
            .onEnded { value in
                isDragging = false
                let predicted = -value.predictedEndTranslation.height
                let projected = (chatExpanded ? 0 : collapseDist) - predicted
                if projected < collapseDist / 2 { expand() } else { collapse() }
            }
    }

    private func expand() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            chatExpanded = true
            dragOffset = 0
        }
    }

    private func collapse() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            chatExpanded = false
            dragOffset = 0
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
        (.lineup,  "Lineup",  "list.bullet.rectangle.portrait.fill"),
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

// The shared "top of the chat page": a grabber + title row. Used both as the
// collapsed peek (resting on top of the tab bar) and as the header of the
// expanded panel, so pulling the peek up reads as the same page rising.
// `onClose` is nil for the peek and set when expanded (collapse button).
struct LeagueChatTopBar: View {
    var onClose: (() -> Void)? = nil
    var onOpenInbox: (() -> Void)? = nil

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
                // Direct line to the full inbox (DMs + other leagues) — the
                // only other path is buried in the all-leagues overview.
                if let onOpenInbox {
                    Button(action: onOpenInbox) {
                        Image(systemName: "envelope")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(FFColor.textSecondary)
                            .padding(.trailing, onClose != nil ? FFSpace.s : 0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Messages")
                }
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
