import SwiftUI

// Cinematic gamecast view. Score header + dominant field rendering + 2-line
// play description + control row + scrubber. Auto-advance with selectable
// speed (1× / 2× / 4×).
//
// The field is "possession-oriented": flipped horizontally so the team
// with the ball always attacks right. We achieve this by rotating the
// GamecastField+GamecastPlayLayer composite 180° when the defending team
// happens to be on the right in the home/away convention — but in
// practice we don't care about home/away here; the field is laid out
// with posteam-on-left always, and the play overlay translates yardline
// to x-coordinate accordingly.
struct GamecastView: View {
    let game: NFLGame
    let plays: [Play]
    let loaded: Bool
    @Binding var index: Int       // current play index, owned by parent
    let teamsMeta: [String: NFLTeamMeta]

    @State private var playProgress: Double = 1.0
    @State private var autoAdvance: Bool = false
    @State private var speed: Speed = .x1
    @State private var animationToken: Int = 0
    @State private var autoTimerToken: Int = 0

    enum Speed: Int, CaseIterable {
        case x1 = 1, x2 = 2, x4 = 4
        var label: String { "\(rawValue)×" }
        var playDuration: TimeInterval { 1.2 / Double(rawValue) }
        var holdDuration: TimeInterval { 0.6 / Double(rawValue) }
        var next: Speed {
            switch self { case .x1: return .x2; case .x2: return .x4; case .x4: return .x1 }
        }
    }

    private var visiblePlays: [Play] {
        // Skip empty / no_play rows that bloat the index without anything
        // meaningful to show.
        plays.filter { !shouldSkip($0) }
    }

    private func shouldSkip(_ p: Play) -> Bool {
        let t = (p.playType ?? "").lowercased()
        if t == "no_play" { return true }
        if (p.description ?? "").isEmpty { return true }
        return false
    }

    private var currentPlay: Play? {
        guard !visiblePlays.isEmpty else { return nil }
        let clamped = max(0, min(visiblePlays.count - 1, index))
        return visiblePlays[clamped]
    }

    var body: some View {
        VStack(spacing: FFSpace.l) {
            scoreHeader
            if loaded == false {
                ProgressView().tint(FFColor.accent)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if visiblePlays.isEmpty {
                emptyState
            } else {
                fieldStack
                descriptionBlock
                controlRow
                scrubber
            }
        }
        .onChange(of: index) { _, _ in
            replay()
        }
        .onChange(of: autoAdvance) { _, on in
            if on { startAutoAdvance() } else { stopAutoAdvance() }
        }
        .onAppear {
            // Kick off the first play's animation when the tab opens.
            replay()
        }
        .onDisappear { stopAutoAdvance() }
    }

    // MARK: - Score header

    private var scoreHeader: some View {
        let p = currentPlay
        return HStack(spacing: FFSpace.l) {
            teamScore(team: game.away,
                      score: p?.posteamScore != nil && p?.posteam == game.away
                              ? p?.posteamScore : (p?.defteam == game.away ? p?.defteamScore : game.awayScore))
            VStack(spacing: 2) {
                if let p, let q = p.qtr {
                    Text("Q\(q)").font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                    if let clock = formatClock(p.gameSecondsRemaining) {
                        Text(clock).font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                    }
                } else {
                    Text(game.status == .final ? "FINAL" : "—")
                        .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                }
            }
            teamScore(team: game.home,
                      score: p?.posteamScore != nil && p?.posteam == game.home
                              ? p?.posteamScore : (p?.defteam == game.home ? p?.defteamScore : game.homeScore))
        }
        .padding(FFSpace.m)
        .frame(maxWidth: .infinity)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private func teamScore(team: String, score: Int?) -> some View {
        HStack(spacing: 6) {
            if let meta = teamsMeta[team], let urlStr = meta.logoURL,
               let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase { img.resizable().scaledToFit() }
                    else { Color.clear }
                }
                .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(team).font(.ffCaption.bold()).foregroundStyle(FFColor.textPrimary)
                Text("\(score ?? 0)").font(.ffStatMedium).foregroundStyle(FFColor.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Field

    private var fieldStack: some View {
        ZStack {
            GamecastField(posteam: currentPlay?.posteam,
                          defteam: currentPlay?.defteam,
                          teamsMeta: teamsMeta)
            if let p = currentPlay {
                GamecastPlayLayer(play: p,
                                  posteamAttacking: p.posteam,
                                  progress: playProgress,
                                  highlightColor: posteamColor(p.posteam))
                    .id(animationToken)
            }
        }
        .aspectRatio(FieldGeometry.length / FieldGeometry.width, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private func posteamColor(_ team: String?) -> Color {
        if let t = team, let meta = teamsMeta[t],
           let hex = meta.primaryColor, let c = Color(uiColorHex: hex) {
            return c
        }
        return FFColor.accent
    }

    // MARK: - Description

    private var descriptionBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(situationLine).font(.ffMicro).tracking(0.6).foregroundStyle(FFColor.accent)
            Text(currentPlay?.description ?? "—")
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, FFSpace.s)
    }

    private var situationLine: String {
        guard let p = currentPlay else { return "" }
        var bits: [String] = []
        if let d = p.down, let togo = p.ydstogo, d > 0 {
            bits.append("\(ordinal(d)) & \(togo)")
        }
        if let pt = p.posteam, let y = p.yardline100 {
            bits.append("\(pt) \(y <= 50 ? y : 100 - y)")
        }
        if let yds = p.yardsGained {
            bits.append("\(Int(yds) >= 0 ? "+" : "")\(Int(yds)) yd")
        }
        if p.firstDown == true { bits.append("1st DN") }
        if p.touchdown == true { bits.append("TD") }
        if p.fieldGoalResult == "made" { bits.append("FG GOOD") }
        if p.fieldGoalAttempt == true && p.fieldGoalResult != "made" { bits.append("FG NO GOOD") }
        if p.interception == true { bits.append("INT") }
        if p.fumbleLost == true { bits.append("FUM LOST") }
        if p.sack == true { bits.append("SACK") }
        return bits.joined(separator: " · ")
    }

    private func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"; case 2: return "2nd"; case 3: return "3rd"
        default: return "\(n)th"
        }
    }

    // MARK: - Controls

    private var controlRow: some View {
        HStack(spacing: FFSpace.m) {
            controlButton("chevron.left", disabled: index <= 0) {
                index = max(0, index - 1)
            }
            controlButton("arrow.counterclockwise", disabled: false) { replay() }
            controlButton("chevron.right",
                          disabled: index >= visiblePlays.count - 1) {
                index = min(visiblePlays.count - 1, index + 1)
            }
            Spacer()
            // Auto-advance + speed cycle
            Button {
                speed = speed.next
            } label: {
                Text(speed.label)
                    .font(.ffMicro.bold())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(FFColor.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(FFColor.border, lineWidth: 1))
                    .foregroundStyle(FFColor.textSecondary)
            }
            .buttonStyle(.plain)

            Button {
                autoAdvance.toggle()
            } label: {
                Image(systemName: autoAdvance ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(8)
                    .background(autoAdvance ? FFColor.accent : FFColor.surface, in: Circle())
                    .foregroundStyle(autoAdvance ? FFColor.bg : FFColor.textPrimary)
            }
            .buttonStyle(.plain)

            Text("\(index + 1) / \(visiblePlays.count)")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
        }
        .padding(.horizontal, FFSpace.s)
    }

    private func controlButton(_ icon: String, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .padding(8)
                .background(FFColor.surface, in: Circle())
                .overlay(Circle().strokeBorder(FFColor.border, lineWidth: 1))
                .foregroundStyle(disabled ? FFColor.textTertiary : FFColor.textPrimary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        let bounds: ClosedRange<Double> = 0...Double(max(0, visiblePlays.count - 1))
        return Slider(
            value: Binding(
                get: { Double(index) },
                set: { index = Int($0.rounded()) }
            ),
            in: bounds,
            step: 1
        )
        .tint(FFColor.accent)
        .padding(.horizontal, FFSpace.s)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "sportscourt")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No plays to chart")
                .font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
            Text("Play-by-play isn't available for this game yet. It usually lands shortly after kickoff — pull to refresh.")
                .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, FFSpace.xxxl)
    }

    // MARK: - Animation driver

    private func replay() {
        animationToken &+= 1   // forces the Canvas to re-create cleanly
        playProgress = 0
        let dur = speed.playDuration
        withAnimation(.easeOut(duration: dur)) {
            playProgress = 1.0
        }
    }

    // MARK: - Auto-advance

    private func startAutoAdvance() {
        autoTimerToken &+= 1
        let token = autoTimerToken
        let total = speed.playDuration + speed.holdDuration
        Task {
            while autoAdvance && token == autoTimerToken {
                try? await Task.sleep(nanoseconds: UInt64(total * 1_000_000_000))
                if !autoAdvance || token != autoTimerToken { return }
                await MainActor.run {
                    if index >= visiblePlays.count - 1 {
                        autoAdvance = false
                    } else {
                        index += 1
                    }
                }
            }
        }
    }

    private func stopAutoAdvance() {
        autoTimerToken &+= 1
    }

    // MARK: - Helpers

    private func formatClock(_ secsRemaining: Int?) -> String? {
        guard let s = secsRemaining, s >= 0 else { return nil }
        let q = s % 900   // 15-min quarters
        let m = q / 60
        let sec = q % 60
        return String(format: "%d:%02d", m, sec)
    }
}

// Tiny hex → Color helper kept local so this file is drop-in. Returns nil
// for malformed hex so the caller can fall back to the accent.
private extension Color {
    init?(uiColorHex hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self = Color(
            red:   Double((v >> 16) & 0xff) / 255,
            green: Double((v >>  8) & 0xff) / 255,
            blue:  Double( v        & 0xff) / 255
        )
    }
}
