import SwiftUI

// Career-wide injury history: season-range filter, summary, body heat map,
// and the per-season log. Loaded lazily the first time the page opens.
// Pushed from the player profile hub.
struct PlayerInjuriesPage: View {
    @Environment(AppState.self) private var app
    let player: Player
    let model: PlayerDetailModel

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                injurySection()
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Injuries")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .task(id: player.id) {
            await model.loadInjuriesIfNeeded(app: app, player: player)
        }
    }

    @ViewBuilder
    private func injurySection() -> some View {
        if model.injuryLoading && model.injuryEvents.isEmpty {
            injuryMessageCard {
                HStack(spacing: FFSpace.s) {
                    ProgressView().tint(FFColor.accent)
                    Text("Loading injury history…")
                        .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                }
            }
        } else if model.injuryEvents.isEmpty {
            injuryMessageCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No injury history on record.")
                        .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    Text("We track reported injuries from recent seasons — a clean record here means none were reported.")
                        .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                }
            }
        } else {
            injuryContent()
        }
    }

    private func injuryContent() -> some View {
        let allSeasons = model.injuryEvents.map(\.season)
        let minS = allSeasons.min() ?? 0
        let maxS = allSeasons.max() ?? 0
        let start = model.injuryStartSeason ?? minS
        let end = model.injuryEndSeason ?? maxS
        let filtered = model.injuryEvents.filter { $0.season >= start && $0.season <= end }
        let stats = Fantasy.injuryRegionStats(from: filtered)
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            if minS != maxS {
                injurySeasonFilter(minSeason: minS, maxSeason: maxS, start: start, end: end)
            }
            injurySummaryCard(events: filtered, start: start, end: end)
            injuryHeatCard(stats: stats)
            injuryListSection(events: filtered)
        }
    }

    private func injurySeasonFilter(minSeason: Int, maxSeason: Int, start: Int, end: Int) -> some View {
        let years = Array(minSeason...maxSeason)
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("SEASON RANGE").ffEyebrow().padding(.leading, FFSpace.s)
            HStack(spacing: FFSpace.s) {
                Menu {
                    ForEach(years.filter { $0 <= end }, id: \.self) { yr in
                        Button(String(yr)) { model.injuryStartSeason = yr }
                    }
                } label: {
                    injuryFilterChip(label: "From", value: String(start))
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FFColor.textTertiary)
                Menu {
                    ForEach(years.filter { $0 >= start }, id: \.self) { yr in
                        Button(String(yr)) { model.injuryEndSeason = yr }
                    }
                } label: {
                    injuryFilterChip(label: "To", value: String(end))
                }
                Spacer()
                if model.injuryStartSeason != nil || model.injuryEndSeason != nil {
                    Button {
                        model.injuryStartSeason = nil
                        model.injuryEndSeason = nil
                    } label: {
                        Text("All time")
                            .font(.ffCaption.bold())
                            .foregroundStyle(FFColor.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(FFSpace.m)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func injuryFilterChip(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label.uppercased())
                .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            Text(value)
                .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(FFColor.textTertiary)
        }
        .padding(.horizontal, FFSpace.m).padding(.vertical, 8)
        .background(FFColor.surfaceElevated, in: Capsule())
        .overlay(Capsule().strokeBorder(FFColor.border, lineWidth: 1))
    }

    private func injurySummaryCard(events: [InjuryEvent], start: Int, end: Int) -> some View {
        let total = events.count
        let byGroup = Dictionary(grouping: events.compactMap { $0.group }, by: { $0 })
        let topGroup = byGroup.max { $0.value.count < $1.value.count }
        let rangeLabel = start == end ? String(start) : "\(start)–\(end)"
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("INJURIES").ffEyebrow(color: FFColor.accent)
                    Text("\(total)")
                        .font(.ffStatLarge)
                        .foregroundStyle(FFColor.textPrimary)
                    Text("\(total == 1 ? "reported injury" : "reported injuries") · \(rangeLabel)")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                if let topGroup {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("MOST AFFECTED").ffEyebrow(color: FFColor.textTertiary)
                        Text(topGroup.key.displayName)
                            .font(.ffStatMedium)
                            .foregroundStyle(FFColor.negative)
                        Text("\(topGroup.value.count)×")
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
        }
        .ffCard(padding: FFSpace.l)
    }

    private func injuryHeatCard(stats: [BodyRegion: Fantasy.RegionStat]) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("INJURY MAP").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: FFSpace.l) {
                if stats.isEmpty {
                    Text("No localized injuries in this range.")
                        .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, FFSpace.l)
                } else {
                    BodyHeatMap(stats: stats)
                    BodyHeatLegend()
                    Text("Color shows worst severity; the number counts injuries at that area. Sides aren't recorded, so paired areas show on both.")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(FFSpace.l)
            .frame(maxWidth: .infinity)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func injuryListSection(events: [InjuryEvent]) -> some View {
        // events are already newest-first; pull distinct seasons in that order.
        var seen = Set<Int>()
        let seasons = events.map(\.season).filter { seen.insert($0).inserted }
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            Text("INJURY LOG").ffEyebrow().padding(.leading, FFSpace.s)
            ForEach(seasons, id: \.self) { season in
                let rows = events.filter { $0.season == season }
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text(String(season))
                        .font(.ffStatMedium)
                        .foregroundStyle(FFColor.textPrimary)
                        .padding(.leading, FFSpace.s)
                    VStack(spacing: 0) {
                        ForEach(rows) { injuryRow($0) }
                    }
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                    .overlay(
                        RoundedRectangle(cornerRadius: FFRadius.m)
                            .strokeBorder(FFColor.border, lineWidth: 1)
                    )
                }
            }
        }
    }

    private func injuryRow(_ e: InjuryEvent) -> some View {
        HStack(alignment: .top, spacing: FFSpace.m) {
            Circle()
                .fill(injuryStatusColor(e.worstStatus))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.rawDetail)
                    .font(.ffBody.weight(.semibold))
                    .foregroundStyle(FFColor.textPrimary)
                    .lineLimit(1)
                Text(injuryWeekLabel(e))
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
            Spacer(minLength: FFSpace.s)
            injuryStatusBadge(e.worstStatus)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    private func injuryWeekLabel(_ e: InjuryEvent) -> String {
        if e.startWeek == 0 && e.endWeek == 0 { return "Preseason report" }
        if e.startWeek == e.endWeek { return "Week \(e.startWeek)" }
        return "Weeks \(e.startWeek)–\(e.endWeek) · \(e.weeksOut) wks"
    }

    private func injuryStatusColor(_ status: String) -> Color {
        switch status.uppercased() {
        case "OUT", "IR", "INJURED RESERVE", "PUP", "SUSPENDED", "SUS", "NFI":
            return FFColor.negative
        case "DOUBTFUL", "QUESTIONABLE":
            return FFColor.warning
        default:
            return FFColor.textSecondary
        }
    }

    private func injuryStatusBadge(_ status: String) -> some View {
        let color = injuryStatusColor(status)
        let label = status.isEmpty ? "—" : status.uppercased()
        return Text(label)
            .font(.ffMicro.bold())
            .tracking(0.6)
            .lineLimit(1)
            .padding(.horizontal, FFSpace.s).padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private func injuryMessageCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(FFSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
    }
}
