import SwiftUI

// 32-team browser grouped by AFC / NFC then by division. Tap any team to
// open its profile.
struct TeamsView: View {
    @Environment(AppState.self) private var app
    @Binding var selectedPlayerID: String?

    @State private var teams: [NFLTeamMeta] = []
    @State private var selectedTeam: NFLTeamMeta? = nil

    private var byConference: [(conference: String, divisions: [(name: String, teams: [NFLTeamMeta])])] {
        let confs = Dictionary(grouping: teams, by: { $0.conference })
        return confs.keys.sorted().map { conf in
            let inConf = confs[conf] ?? []
            let divs = Dictionary(grouping: inConf, by: { $0.division })
            let divisions = divs.keys.sorted().map { divName in
                (name: divName, teams: (divs[divName] ?? []).sorted { $0.abbr < $1.abbr })
            }
            return (conference: conf, divisions: divisions)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FFSpace.l) {
                ForEach(byConference, id: \.conference) { conf in
                    VStack(alignment: .leading, spacing: FFSpace.s) {
                        Text(conf.conference).ffEyebrow().padding(.leading, FFSpace.s)
                        ForEach(conf.divisions, id: \.name) { div in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(conf.conference) \(div.name)".uppercased())
                                    .font(.ffMicro).tracking(0.8)
                                    .foregroundStyle(FFColor.textTertiary)
                                    .padding(.leading, FFSpace.s)
                                LazyVGrid(columns: [
                                    GridItem(.flexible()), GridItem(.flexible())
                                ], spacing: FFSpace.s) {
                                    ForEach(div.teams) { team in
                                        Button { selectedTeam = team } label: {
                                            teamTile(team)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.top, FFSpace.s)
            .padding(.bottom, 40)
        }
        .task { teams = await app.nflTeams() }
        .sheet(item: $selectedTeam) { team in
            TeamProfileView(team: team, selectedPlayerID: $selectedPlayerID)
        }
    }

    private func teamTile(_ team: NFLTeamMeta) -> some View {
        HStack(spacing: FFSpace.m) {
            teamLogo(team, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(team.abbr)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
                Text(team.fullName.replacingOccurrences(of: " \(team.abbr)", with: ""))
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(FFSpace.m)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }
}

// Reusable team-logo loader. AsyncImage with the same Nuke pipeline isn't
// quite ergonomic here because NukeUI's LazyImage doesn't load eagerly
// enough for tiles, so fall back to AsyncImage with a Circle placeholder.
struct TeamLogoCircle: View {
    let url: String?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
    }

    private var placeholder: some View {
        Circle().fill(FFColor.surfaceElevated)
    }
}

// Convenience wrapper used by tiles.
private func teamLogo(_ team: NFLTeamMeta, size: CGFloat) -> some View {
    TeamLogoCircle(url: team.logoURL, size: size)
}
