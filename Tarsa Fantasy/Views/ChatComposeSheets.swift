import SwiftUI

// Builder sheets for structured chat cards. Each gathers its inputs and hands
// a finished ChatPayload back to the chat view via `onCreate`, which posts it.

// MARK: - Poll

struct PollBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (ChatPayload) -> Void

    @State private var question = ""
    @State private var options: [OptionField] = [OptionField(), OptionField()]
    @State private var allowMultiple = false
    @State private var allowAddOptions = false
    @State private var hasDeadline = false
    @State private var closesAt = Date().addingTimeInterval(24 * 60 * 60)

    private var cleanedOptions: [String] {
        options
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canPost: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cleanedOptions.count >= 2
    }

    private func number(of option: OptionField) -> Int {
        (options.firstIndex(where: { $0.id == option.id }) ?? 0) + 1
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: FFSpace.l) {
                        VStack(alignment: .leading, spacing: FFSpace.s) {
                            Text("Question").ffEyebrow()
                            ComposeField(text: $question, prompt: "Ask your league…")
                        }
                        VStack(alignment: .leading, spacing: FFSpace.s) {
                            Text("Options").ffEyebrow()
                            ForEach($options) { $option in
                                HStack(spacing: FFSpace.s) {
                                    ComposeField(text: $option.text, prompt: "Option \(number(of: option))")
                                    if options.count > 2 {
                                        Button {
                                            options.removeAll { $0.id == option.id }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(FFColor.textTertiary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            if options.count < 6 {
                                Button {
                                    options.append(OptionField())
                                } label: {
                                    Label("Add option", systemImage: "plus.circle")
                                        .font(.ffCaption)
                                        .foregroundStyle(FFColor.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        VStack(alignment: .leading, spacing: FFSpace.s) {
                            Text("Settings").ffEyebrow()
                            ToggleRow(title: "Allow multiple answers",
                                      subtitle: "Voters can pick more than one option",
                                      isOn: $allowMultiple)
                            ToggleRow(title: "Let members add options",
                                      subtitle: "Anyone can append their own option",
                                      isOn: $allowAddOptions)
                            ToggleRow(title: "Set a deadline",
                                      subtitle: "Voting locks at the time you choose",
                                      isOn: $hasDeadline)
                            if hasDeadline {
                                DatePicker("Closes", selection: $closesAt, in: Date()...,
                                           displayedComponents: [.date, .hourAndMinute])
                                    .font(.ffBody)
                                    .tint(FFColor.accent)
                                    .padding(.horizontal, FFSpace.m)
                                    .padding(.vertical, FFSpace.s)
                                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: FFRadius.s)
                                            .strokeBorder(FFColor.border, lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .padding(FFSpace.l)
                }
            }
            .navigationTitle("New poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(FFColor.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Post") {
                        onCreate(ChatPayload(
                            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                            options: cleanedOptions,
                            allowMultiple: allowMultiple ? true : nil,
                            allowAddOptions: allowAddOptions ? true : nil,
                            closesAt: hasDeadline ? closesAt.timeIntervalSince1970 : nil
                        ))
                    }
                    .foregroundStyle(canPost ? FFColor.accent : FFColor.textTertiary)
                    .disabled(!canPost)
                }
            }
        }
    }
}

// MARK: - Pick'em

// Built from the real NFL schedule: the creator picks a week, then taps the
// games to include. Each selected game becomes a card row where members call
// the winner. Games lock at kickoff.
struct PickemBuilderSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let league: League
    let onCreate: (ChatPayload) -> Void

    @State private var title = ""
    @State private var week = 1
    @State private var schedule: [NFLGame] = []
    @State private var teamNames: [String: String] = [:]
    @State private var selected: Set<String> = []
    @State private var loading = true

    private var availableWeeks: [Int] {
        Array(Set(schedule.map(\.week))).sorted()
    }

    private var gamesThisWeek: [NFLGame] {
        schedule
            .filter { $0.week == week }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
    }

    private var canPost: Bool { !selected.isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("New pick 'em")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(FFColor.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Post") { post() }
                        .foregroundStyle(canPost ? FFColor.accent : FFColor.textTertiary)
                        .disabled(!canPost)
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().tint(FFColor.accent)
        } else if schedule.isEmpty {
            VStack(spacing: FFSpace.s) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(FFColor.textTertiary)
                Text("Schedule not available")
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Text("The \(league.season) NFL schedule hasn't loaded yet.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(FFSpace.xxl)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: FFSpace.l) {
                    VStack(alignment: .leading, spacing: FFSpace.s) {
                        Text("Title (optional)").ffEyebrow()
                        ComposeField(text: $title, prompt: "Week \(week) picks")
                    }
                    weekSelector
                    VStack(alignment: .leading, spacing: FFSpace.s) {
                        HStack {
                            Text("Games · tap to include").ffEyebrow()
                            Spacer()
                            Text("\(selected.intersection(Set(gamesThisWeek.map(\.gameID))).count) selected")
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                        }
                        if gamesThisWeek.isEmpty {
                            Text("No games scheduled for week \(week).")
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.textSecondary)
                        } else {
                            ForEach(gamesThisWeek) { game in
                                gameRow(game)
                            }
                        }
                    }
                }
                .padding(FFSpace.l)
            }
        }
    }

    private var weekSelector: some View {
        HStack {
            Button {
                if let prev = availableWeeks.last(where: { $0 < week }) { week = prev }
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(canGoBack ? FFColor.accent : FFColor.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            Spacer()
            Text("WEEK \(week)")
                .font(.ffHeadline)
                .tracking(1)
                .foregroundStyle(FFColor.textPrimary)
            Spacer()
            Button {
                if let next = availableWeeks.first(where: { $0 > week }) { week = next }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(canGoForward ? FFColor.accent : FFColor.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)
        }
        .padding(.horizontal, FFSpace.m)
        .padding(.vertical, FFSpace.s)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.s)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private var canGoBack: Bool { availableWeeks.contains { $0 < week } }
    private var canGoForward: Bool { availableWeeks.contains { $0 > week } }

    private func gameRow(_ game: NFLGame) -> some View {
        let isSelected = selected.contains(game.gameID)
        return Button {
            if isSelected { selected.remove(game.gameID) } else { selected.insert(game.gameID) }
        } label: {
            HStack(spacing: FFSpace.s) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? FFColor.accent : FFColor.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(game.away) @ \(game.home)")
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                    if let kickoff = game.kickoff {
                        Text(kickoff.formatted(.dateTime.weekday().month().day().hour().minute()))
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, FFSpace.m)
            .padding(.vertical, FFSpace.s)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.s)
                    .strokeBorder(isSelected ? FFColor.accent.opacity(0.6) : FFColor.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        let loadedSchedule = await app.schedules(season: league.season)
        let loadedMetas = await app.nflTeams()
        teamNames = Dictionary(uniqueKeysWithValues: loadedMetas.map { ($0.abbr, $0.fullName) })
        schedule = loadedSchedule
        let now = Date()
        let upcoming = loadedSchedule
            .filter { ($0.kickoff ?? .distantPast) > now }
            .map(\.week).min()
        week = upcoming ?? loadedSchedule.map(\.week).min() ?? 1
        loading = false
    }

    private func post() {
        let chosen = schedule
            .filter { selected.contains($0.gameID) }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
        let pickGames = chosen.map { g in
            PickGame(
                id: g.gameID, week: g.week, away: g.away, home: g.home,
                awayName: teamNames[g.away], homeName: teamNames[g.home],
                kickoff: g.kickoff?.timeIntervalSince1970
            )
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(ChatPayload(
            question: trimmedTitle.isEmpty ? nil : trimmedTitle,
            games: pickGames
        ))
    }
}

// MARK: - Trade block

struct TradeBlockBuilderSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let league: League
    let onCreate: (ChatPayload) -> Void

    @State private var selected: Set<String> = []
    @State private var note = ""
    @State private var roster: [RosterPick] = []
    @State private var seeking: [RosterPick] = []
    @State private var seekQuery = ""
    @State private var loading = true

    private struct RosterPick: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private var myTeam: FantasyTeam? {
        league.teams.first { $0.ownerID == app.session?.userID }
    }

    private var canPost: Bool {
        !selected.isEmpty || !seeking.isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Players matching the lookup query, excluding the user's own roster and
    // anything already on the seeking list.
    private var seekResults: [PlayerSummary] {
        let q = seekQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let mine = Set(roster.map(\.id))
        let already = Set(seeking.map(\.id))
        return Fantasy.search(
            players: app.players(season: league.season),
            query: q,
            scoring: app.activeScoring,
            limit: 20
        ).filter { !mine.contains($0.id) && !already.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("Trade block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(FFColor.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Post") { post() }
                        .foregroundStyle(canPost ? FFColor.accent : FFColor.textTertiary)
                        .disabled(!canPost)
                }
            }
            .task { await loadRoster() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().tint(FFColor.accent)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: FFSpace.l) {
                    VStack(alignment: .leading, spacing: FFSpace.s) {
                        Text("Players I'm offering").ffEyebrow()
                        if roster.isEmpty {
                            Text("No players on your roster yet.")
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.textSecondary)
                        } else {
                            ForEach(roster) { pick in
                                offerRow(pick)
                            }
                        }
                    }
                    seekingSection
                    VStack(alignment: .leading, spacing: FFSpace.s) {
                        Text("Note (optional)").ffEyebrow()
                        ComposeField(text: $note, prompt: "What are you looking for?")
                    }
                }
                .padding(FFSpace.l)
            }
        }
    }

    private var seekingSection: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("Players I'm after").ffEyebrow()
            if !seeking.isEmpty {
                VStack(spacing: FFSpace.s) {
                    ForEach(seeking) { pick in
                        seekingChip(pick)
                    }
                }
            }
            ComposeField(text: $seekQuery, prompt: "Search any player…")
            if !seekResults.isEmpty {
                VStack(spacing: 4) {
                    ForEach(seekResults) { result in
                        seekResultRow(result)
                    }
                }
            }
        }
    }

    private func offerRow(_ pick: RosterPick) -> some View {
        let isSelected = selected.contains(pick.id)
        return Button {
            if isSelected { selected.remove(pick.id) } else { selected.insert(pick.id) }
        } label: {
            HStack(spacing: FFSpace.s) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? FFColor.accent : FFColor.textTertiary)
                Text(pick.name)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                Spacer()
            }
            .padding(.horizontal, FFSpace.m)
            .padding(.vertical, FFSpace.s)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.s)
                    .strokeBorder(isSelected ? FFColor.accent.opacity(0.6) : FFColor.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func seekingChip(_ pick: RosterPick) -> some View {
        HStack(spacing: FFSpace.s) {
            Image(systemName: "target")
                .font(.system(size: 12))
                .foregroundStyle(FFColor.positive)
            Text(pick.name)
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
            Spacer()
            Button {
                seeking.removeAll { $0.id == pick.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(FFColor.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, FFSpace.m)
        .padding(.vertical, FFSpace.s)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.s)
                .strokeBorder(FFColor.positive.opacity(0.5), lineWidth: 1)
        )
    }

    private func seekResultRow(_ result: PlayerSummary) -> some View {
        Button {
            seeking.append(RosterPick(id: result.id, name: result.name))
            seekQuery = ""
        } label: {
            HStack(spacing: FFSpace.s) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(FFColor.accent)
                Text(result.name)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                Text("\(result.position) · \(result.team)")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
                Spacer()
            }
            .padding(.horizontal, FFSpace.m)
            .padding(.vertical, FFSpace.s)
            .background(FFColor.surfaceElevated, in: RoundedRectangle(cornerRadius: FFRadius.s))
        }
        .buttonStyle(.plain)
    }

    private func loadRoster() async {
        _ = await app.loadSeason(league.season)
        let cache = app.players(season: league.season)
        roster = (myTeam?.roster ?? [])
            .filter { !$0.isEmpty }
            .compactMap { id in
                cache[id].map { RosterPick(id: id, name: $0.name) }
            }
        loading = false
    }

    private func post() {
        let names = roster.filter { selected.contains($0.id) }.map(\.name)
        let seekNames = seeking.map(\.name)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(ChatPayload(
            players: names.isEmpty ? nil : names,
            seeking: seekNames.isEmpty ? nil : seekNames,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            teamName: myTeam?.name
        ))
    }
}

// MARK: - Shared field

// An editable option/answer row backed by a stable identity, so SwiftUI
// bindings survive deletions of non-terminal rows (index-based bindings can
// crash with "Index out of range" mid-diff when a row is removed).
private struct OptionField: Identifiable, Hashable {
    let id = UUID()
    var text: String = ""
}

// A styled single-line text field matching the chat composer's look.
private struct ComposeField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        TextField("", text: $text, prompt:
            Text(prompt).foregroundColor(FFColor.textTertiary)
        )
        .font(.ffBody)
        .foregroundStyle(FFColor.textPrimary)
        .padding(.horizontal, FFSpace.m)
        .padding(.vertical, FFSpace.s)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.s)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }
}

// A labeled toggle row used in builder settings sections.
private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
                Text(subtitle)
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .tint(FFColor.accent)
        .padding(.horizontal, FFSpace.m)
        .padding(.vertical, FFSpace.s)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.s)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }
}
