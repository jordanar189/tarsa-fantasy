import SwiftUI

// Commissioner-only sheet for scheduling/configuring the draft. Editable
// while the draft is in `scheduled` status; once it goes live, all settings
// lock and the sheet becomes read-only with just a "view in room" link.
struct DraftSetupView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let league: League
    let existing: Draft?           // nil when creating fresh
    let onSave: (Draft) -> Void

    @State private var startsAt: Date
    @State private var pickSeconds: Int
    @State private var format: DraftFormat
    @State private var pickOrder: [String]
    @State private var auctionBudget: Int
    @State private var saving: Bool = false
    @State private var error: String? = nil

    init(league: League, existing: Draft?, onSave: @escaping (Draft) -> Void) {
        self.league   = league
        self.existing = existing
        self.onSave   = onSave
        _startsAt    = State(initialValue: existing?.startsAt ?? Self.defaultStart())
        _pickSeconds = State(initialValue: existing?.pickSeconds ?? 60)
        _format      = State(initialValue: existing?.format ?? .snake)
        _auctionBudget = State(initialValue: existing?.auctionBudget ?? 200)
        // Initial order: existing draft order, else waiver priority, else team order.
        let initial: [String] = existing?.pickOrder
            ?? (league.waiverPriority.isEmpty ? league.teams.map(\.id) : league.waiverPriority)
        let known = Set(initial)
        let missing = league.teams.map(\.id).filter { !known.contains($0) }
        _pickOrder = State(initialValue: initial + missing)
    }

    private static func defaultStart() -> Date {
        // Default to "tomorrow at 8pm local".
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.day = (c.day ?? 1) + 1
        c.hour = 20; c.minute = 0
        return Calendar.current.date(from: c) ?? Date().addingTimeInterval(86_400)
    }

    private var locked: Bool { (existing?.status ?? .scheduled) != .scheduled }

    // Keeper-lite leagues draft fewer rounds — keepers already occupy roster
    // slots, so the draft fills only what's left. Round-cost leagues run the
    // full length; keepers pre-fill their cost rounds at draft start instead.
    // Auctions always run full-size: keepers pre-fill as $1 sold lots and the
    // server normalizes total_picks from roster_config regardless.
    private var rosterSize: Int {
        format == .auction || league.keeperRoundCost
            ? max(1, league.rosterConfig.totalSize)
            : max(1, league.rosterConfig.totalSize - league.keeperCount)
    }
    private var totalPicks: Int { rosterSize * pickOrder.count }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                Form {
                    if locked {
                        Section {
                            Text("This draft is \(existing?.status.rawValue ?? "live") — settings can't be changed.")
                                .font(.ffCaption)
                                .foregroundStyle(FFColor.textTertiary)
                        }
                        .listRowBackground(FFColor.surface)
                    }
                    scheduleSection
                    formatSection
                    orderSection
                    summarySection
                    if let error {
                        Section {
                            Text(error).font(.ffCaption).foregroundStyle(FFColor.negative)
                        }
                        .listRowBackground(FFColor.surface)
                    }
                }
                .environment(\.editMode, .constant(.active))
                .scrollContentBackground(.hidden)
                .background(FFColor.bg)
            }
            .navigationTitle("Draft setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(FFColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .foregroundStyle(locked ? FFColor.textTertiary : FFColor.accent)
                        .disabled(saving || locked)
                }
            }
        }
    }

    private var scheduleSection: some View {
        Section {
            DatePicker("Start", selection: $startsAt, in: Date()...)
                .tint(FFColor.accent)
                .disabled(locked)
            Stepper(value: $pickSeconds, in: 15...300, step: 15) {
                HStack {
                    Text(format == .auction ? "Nomination clock" : "Pick clock")
                        .font(.ffBody).foregroundStyle(FFColor.textPrimary)
                    Spacer()
                    Text("\(pickSeconds)s")
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.accent)
                }
            }
            .disabled(locked)
        } header: {
            Text("Schedule").ffEyebrow()
        } footer: {
            Text(format == .auction
                 ? "Owners can enter the room any time after the draft is scheduled. The nomination clock starts once the draft goes live — when it hits zero, the best-available player is nominated automatically at $1."
                 : "Owners can enter the room any time after the draft is scheduled. The pick clock starts once the draft goes live — when it hits zero, the best-available player is auto-picked.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private var formatSection: some View {
        Section {
            Picker("Format", selection: $format) {
                ForEach(DraftFormat.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .disabled(locked)
            if format == .auction {
                Stepper(value: $auctionBudget, in: 100...500, step: 10) {
                    HStack {
                        Text("Budget per team").font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text("$\(auctionBudget)").font(.ffStatSmall).foregroundStyle(FFColor.accent)
                    }
                }
                .disabled(locked)
            }
        } header: {
            Text("Format").ffEyebrow()
        } footer: {
            Text(formatFooter)
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private var formatFooter: String {
        switch format {
        case .snake:
            return "Snake: round 1 picks 1→N, round 2 reverses, etc."
        case .linear:
            return "Linear: every round uses the same order. Rare in fantasy football."
        case .auction:
            return "Auction (beta): teams take turns nominating; everyone bids from a $\(auctionBudget) budget. The order below sets nomination turns."
        }
    }

    private var orderSection: some View {
        Section {
            ForEach(Array(pickOrder.enumerated()), id: \.element) { idx, teamID in
                HStack {
                    Text("#\(idx + 1)")
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.accent)
                        .frame(width: 32, alignment: .leading)
                    Text(teamName(teamID))
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                    if let team = league.teams.first(where: { $0.id == teamID }),
                       team.ownerID == nil {
                        Text("OPEN").ffEyebrow(color: FFColor.warning)
                    }
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            .onMove { from, to in pickOrder.move(fromOffsets: from, toOffset: to) }
        } header: {
            Text("Pick order").ffEyebrow()
        } footer: {
            Text("Drag to reorder. #1 picks first in round 1. Open teams will auto-pick the best available player on each of their turns.")
                .foregroundStyle(FFColor.textTertiary)
        }
        .listRowBackground(FFColor.surface)
    }

    private var summarySection: some View {
        Section {
            row("Teams", "\(pickOrder.count)")
            row("Rounds", "\(rosterSize)")
            row("Total picks", "\(totalPicks)")
            let est = totalPicks * pickSeconds
            row("Max length", est >= 3600
                ? String(format: "%dh %02dm", est/3600, (est%3600)/60)
                : "\(est/60)m")
        } header: {
            Text("Summary").ffEyebrow()
        }
        .listRowBackground(FFColor.surface)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.ffBody).foregroundStyle(FFColor.textSecondary)
            Spacer()
            Text(value).font(.ffStatSmall).foregroundStyle(FFColor.accent)
        }
    }

    private func teamName(_ id: String) -> String {
        league.teams.first(where: { $0.id == id })?.name ?? "Unknown"
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            guard let updated = try await app.upsertDraft(
                leagueID: league.id, format: format,
                pickSeconds: pickSeconds, startsAt: startsAt,
                pickOrder: pickOrder, rosterSize: rosterSize,
                auctionBudget: auctionBudget
            ) else { return }
            onSave(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
