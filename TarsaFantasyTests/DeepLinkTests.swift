// Unit tests for DeepLinkRouter — the pure push-URL → (league, tab) mapping
// behind AppState.handlePushDeepLink — and the AppTab legacy-name alias.

import Foundation
import Testing
@testable import Tarsa_Fantasy

struct DeepLinkTests {

    private func dest(_ s: String) -> DeepLinkRouter.Destination? {
        guard let url = URL(string: s) else { return nil }
        return DeepLinkRouter.destination(for: url)
    }

    @Test func bareLeagueURLLandsOnTeamTab() {
        #expect(dest("tarsafantasy://league/abc12345")
                == DeepLinkRouter.Destination(leagueID: "abc12345", tab: .team))
    }

    @Test func tradesSubPathLandsOnMovesTab() {
        #expect(dest("tarsafantasy://league/abc12345/trades")
                == DeepLinkRouter.Destination(leagueID: "abc12345", tab: .moves))
    }

    @Test func waiversSubPathLandsOnMovesTab() {
        #expect(dest("tarsafantasy://league/abc12345/waivers")
                == DeepLinkRouter.Destination(leagueID: "abc12345", tab: .moves))
    }

    @Test func matchupSubPathLandsOnMatchupTab() {
        #expect(dest("tarsafantasy://league/abc12345/matchup")
                == DeepLinkRouter.Destination(leagueID: "abc12345", tab: .matchup))
    }

    @Test func unknownSubPathFallsBackToTeamTab() {
        #expect(dest("tarsafantasy://league/abc12345/draft")
                == DeepLinkRouter.Destination(leagueID: "abc12345", tab: .team))
    }

    @Test func legacyLineupHostLandsOnTeamTab() {
        let d = dest("tarsafantasy://lineup")
        #expect(d?.leagueID == nil)
        #expect(d?.tab == .team)
    }

    @Test func malformedURLResolvesToNil() {
        // League host with no league id.
        #expect(dest("tarsafantasy://league") == nil)
        #expect(dest("tarsafantasy://league/") == nil)
        // Unknown host.
        #expect(dest("tarsafantasy://unknown/whatever") == nil)
        #expect(dest("https://example.com/league/abc12345") == nil)
    }

    // The pre-5-tab raw name must keep resolving so old stored values and
    // links map onto the renamed Team tab.
    @Test func legacyLineupRawValueMapsToTeam() {
        #expect(AppTab(rawValue: "lineup") == .team)
        #expect(AppTab(rawValue: "team") == .team)
        #expect(AppTab(rawValue: "moves") == .moves)
        #expect(AppTab(rawValue: "bogus") == nil)
    }
}
