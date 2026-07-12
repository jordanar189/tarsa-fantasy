import SwiftUI

// The shared "top of the chat page": a grabber + title row. Used both as the
// collapsed peek (resting on top of the tab bar) and as the header of the
// expanded panel, so pulling the peek up reads as the same page rising.
// `onClose` is nil for the peek and set when expanded (collapse button).
// The collapsed peek also surfaces the latest sender's initials and an
// unread-count pill (AppState.chatPeek, fed by LeagueChatView); both stay
// hidden while expanded — the transcript itself is on screen.
struct LeagueChatTopBar: View {
    @Environment(AppState.self) private var app

    var onClose: (() -> Void)? = nil
    var onOpenInbox: (() -> Void)? = nil

    private var isPeek: Bool { onClose == nil }

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
                if isPeek, let sender = app.chatPeek.latestSenderName {
                    senderAvatar(sender)
                }
                Text("League chat")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                if isPeek, app.chatPeek.unread > 0 {
                    unreadPill(app.chatPeek.unread)
                }
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

    // Miniature of LeagueChatView's initials avatar — same fill/border recipe
    // at peek size, so the peek reads as "that person was talking".
    private func senderAvatar(_ name: String) -> some View {
        ZStack {
            Circle().fill(FFColor.surfaceElevated)
            Text(name.initialsFromName)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(FFColor.textSecondary)
        }
        .frame(width: 20, height: 20)
        .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func unreadPill(_ count: Int) -> some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(.ffMicro.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 16)
            .frame(height: 16)
            .background(FFColor.live, in: Capsule())
            .accessibilityLabel("\(count) unread")
    }
}
