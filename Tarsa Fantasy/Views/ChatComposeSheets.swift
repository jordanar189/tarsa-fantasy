import SwiftUI

// Builder sheets for structured chat cards. Each gathers its inputs and hands
// a finished ChatPayload back to the chat view via `onCreate`, which posts it.

// MARK: - Poll / pick'em

// Pick'em is functionally a poll (tap an option, tallies shown live); the
// `kind` only changes copy and the card's styling.
struct PollBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: MessageKind
    let onCreate: (ChatPayload) -> Void

    @State private var question = ""
    @State private var options: [String] = ["", ""]

    private var cleanedOptions: [String] {
        options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canPost: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cleanedOptions.count >= 2
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: FFSpace.l) {
                        VStack(alignment: .leading, spacing: FFSpace.s) {
                            Text("Question").ffEyebrow()
                            ComposeField(
                                text: $question,
                                prompt: kind == .pickem ? "Who wins Monday night?" : "Ask your league…"
                            )
                        }
                        VStack(alignment: .leading, spacing: FFSpace.s) {
                            Text("Options").ffEyebrow()
                            ForEach(options.indices, id: \.self) { i in
                                HStack(spacing: FFSpace.s) {
                                    ComposeField(text: $options[i], prompt: "Option \(i + 1)")
                                    if options.count > 2 {
                                        Button {
                                            options.remove(at: i)
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
                                    options.append("")
                                } label: {
                                    Label("Add option", systemImage: "plus.circle")
                                        .font(.ffCaption)
                                        .foregroundStyle(FFColor.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(FFSpace.l)
                }
            }
            .navigationTitle(kind == .pickem ? "New pick 'em" : "New poll")
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
                            options: cleanedOptions
                        ))
                    }
                    .foregroundStyle(canPost ? FFColor.accent : FFColor.textTertiary)
                    .disabled(!canPost)
                }
            }
        }
    }
}

// MARK: - Trivia

struct TriviaBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (ChatPayload) -> Void

    @State private var question = ""
    @State private var options: [String] = ["", ""]
    @State private var correctIndex: Int? = nil

    // Trims options, drops empties, and remaps the correct answer to its
    // position in the cleaned list. Nil when the inputs aren't postable yet.
    private var result: (options: [String], correct: Int)? {
        let trimmed = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let cleaned = trimmed.enumerated().filter { !$0.element.isEmpty }
        guard cleaned.count >= 2,
              let ci = correctIndex,
              let pos = cleaned.firstIndex(where: { $0.offset == ci })
        else { return nil }
        return (cleaned.map { $0.element }, pos)
    }

    private var canPost: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: FFSpace.l) {
                        VStack(alignment: .leading, spacing: FFSpace.s) {
                            Text("Question").ffEyebrow()
                            ComposeField(text: $question, prompt: "Trivia question…")
                        }
                        VStack(alignment: .leading, spacing: FFSpace.s) {
                            Text("Answers · tap the circle to mark correct").ffEyebrow()
                            ForEach(options.indices, id: \.self) { i in
                                HStack(spacing: FFSpace.s) {
                                    Button {
                                        correctIndex = i
                                    } label: {
                                        Image(systemName: correctIndex == i ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(correctIndex == i ? FFColor.positive : FFColor.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    ComposeField(text: $options[i], prompt: "Answer \(i + 1)")
                                    if options.count > 2 {
                                        Button {
                                            if correctIndex == i { correctIndex = nil }
                                            options.remove(at: i)
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
                                    options.append("")
                                } label: {
                                    Label("Add answer", systemImage: "plus.circle")
                                        .font(.ffCaption)
                                        .foregroundStyle(FFColor.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(FFSpace.l)
                }
            }
            .navigationTitle("New trivia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(FFColor.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Post") {
                        guard let r = result else { return }
                        onCreate(ChatPayload(
                            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                            options: r.options,
                            correct: r.correct
                        ))
                    }
                    .foregroundStyle(canPost ? FFColor.accent : FFColor.textTertiary)
                    .disabled(!canPost)
                }
            }
        }
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
    @State private var loading = true

    private struct RosterPick: Identifiable, Hashable {
        let id: String
        let name: String
    }

    private var myTeam: FantasyTeam? {
        league.teams.first { $0.ownerID == app.session?.userID }
    }

    private var canPost: Bool {
        !selected.isEmpty || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    if roster.isEmpty {
                        Text("No players on your roster to list — add a note instead.")
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textSecondary)
                    } else {
                        VStack(alignment: .leading, spacing: FFSpace.s) {
                            Text("Players on the block").ffEyebrow()
                            ForEach(roster) { pick in
                                rosterRow(pick)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: FFSpace.s) {
                        Text("Note (optional)").ffEyebrow()
                        ComposeField(text: $note, prompt: "What are you looking for?")
                    }
                }
                .padding(FFSpace.l)
            }
        }
    }

    private func rosterRow(_ pick: RosterPick) -> some View {
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
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(ChatPayload(
            players: names.isEmpty ? nil : names,
            note: trimmedNote.isEmpty ? nil : trimmedNote,
            teamName: myTeam?.name
        ))
    }
}

// MARK: - Shared field

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
