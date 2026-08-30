import SwiftUI

// Per-game NFL preseason lines for the selected season, pushed from the
// player profile hub. Display only — preseason never feeds league scoring —
// so points use the preset for the selected league's scoring format.
struct PlayerPreseasonPage: View {
    @Environment(AppState.self) private var app
    let player: Player
    let model: PlayerDetailModel

    @State private var selectedGameID: String? = nil

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                section
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Preseason")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .sheet(item: $selectedGameID.asIdentifiable) { id in
            PreseasonGameLoaderView(gameID: id.id)
        }
    }

    private var section: some View {
        let lines = model.preseasonLines
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("PRESEASON \(String(app.selectedSeason))").ffEyebrow().padding(.leading, FFSpace.s)
            if lines.isEmpty {
                Text("No preseason stats.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            } else {
                VStack(spacing: 0) {
                    ForEach(lines) { line in
                        row(line)
                    }
                }
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.m)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
            }
        }
    }

    private func row(_ l: PreseasonPlayerLine) -> some View {
        let pts = l.points(scoring: model.scoring)
        return HStack(alignment: .top, spacing: FFSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PreseasonGame.shortWeekLabel(l.preWeek))
                    .font(.ffBody.weight(.semibold))
                    .foregroundStyle(FFColor.textPrimary)
                Text("vs \(l.opponent)")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                if !l.isFinal {
                    Text("LIVE")
                        .font(.ffMicro.bold()).tracking(0.8)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(FFColor.live, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if l.hasReceiving {
                    Text("\(l.receptions.statString) rec · \(l.receivingYards.statString) yd · \(l.receivingTDs.statString) TD")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if l.hasRushing {
                    Text("\(l.carries.statString) car · \(l.rushingYards.statString) yd · \(l.rushingTDs.statString) TD")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if l.hasPassing {
                    Text("\(Int(l.completions))/\(Int(l.attempts)) · \(l.passingYards.statString) yd · \(l.passingTDs.statString) TD · \(l.passingInterceptions.statString) INT")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if l.hasDefense {
                    Text("\(l.defTacklesTotal.statString) tkl · \(l.defSacks.statString) sck · \(l.defInterceptions.statString) int")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if l.hasReturns {
                    Text("\((l.kickReturns + l.puntReturns).statString) ret · \((l.kickReturnYards + l.puntReturnYards).statString) yd")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if l.hasKicking {
                    Text("FG \(l.fgMade.statString)/\(l.fgAtt.statString) · XP \(l.patMade.statString)/\(l.patAtt.statString)")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if l.targets > 0 {
                    Text("\(Int(l.targets)) tgt")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            Button {
                selectedGameID = l.gameID
            } label: {
                HStack(spacing: 3) {
                    Text(pts.fpString)
                        .font(.ffStatMedium)
                        .foregroundStyle(FFColor.textPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
                .frame(minWidth: 56, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }
}
