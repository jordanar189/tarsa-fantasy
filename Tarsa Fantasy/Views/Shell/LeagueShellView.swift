import SwiftUI
import UIKit

// The league-focused experience: a five-tab bottom bar (Team · Matchup ·
// League · Moves · Players) with a Sleeper-style pull-up league chat that
// peeks above the bar. The chat is a custom panel rather than a sheet so its
// bottom edge rests on top of the tab bar — pulling it up grows it upward and
// never covers the bar.
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
    @State private var visited: Set<AppTab> = [.team]

    // Chat peek header height; the small gap left above an expanded panel.
    private let peekHeight: CGFloat = 56
    private let topGap: CGFloat = 8

    private static let tabOrder: [AppTab] = [.team, .matchup, .league, .moves, .players]

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

            CustomTabBar(selection: $app.tab, badges: [.moves: app.movesBadgeCount])
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
        // Opening the panel means the user has seen the transcript; closing it
        // covers anything that arrived while it was open. Either edge clears
        // the peek's unread badge and stamps last-seen.
        .onChange(of: chatExpanded) { _, _ in
            if let id = app.selectedLeagueID { app.markChatSeen(leagueID: id) }
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

    // All tab roots are kept alive once visited (so per-tab state survives
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
        case .team:    LineupTabView()
        case .matchup: MatchupTabRootView()
        case .league:  LeagueHubView()
        case .moves:   MovesTabRootView()
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
