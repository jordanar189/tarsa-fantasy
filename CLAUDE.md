# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & run

iOS app, Xcode project (no Swift Package, no test target). The project root and scheme name both contain spaces — quote paths.

```bash
# Build for simulator
xcodebuild -project "Tarsa Fantasy.xcodeproj" \
  -scheme "Tarsa Fantasy" \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build

# Clean
xcodebuild -project "Tarsa Fantasy.xcodeproj" \
  -scheme "Tarsa Fantasy" clean
```

Day-to-day development is in Xcode (⌘R to run, ⌘B to build, SwiftUI previews via `#Preview`). Deployment target is iOS 26.4 — use `xcodebuild -showsdks` to confirm an SDK that supports it before scripted builds.

## Adding files

The Xcode target uses `PBXFileSystemSynchronizedRootGroup` — every file inside `Tarsa Fantasy/` is compiled automatically. **Do not edit `project.pbxproj` when adding Swift files**; just create them in the right directory and they'll be picked up.

## Architecture

Four layers, top to bottom:

1. **SwiftUI views** (`Views/`, `ContentView.swift`) — read state from `@Environment(AppState.self)`. Three tabs: Players, Rankings, Leagues.
2. **`AppState`** (`@Observable`, `@MainActor`) — single source of truth for UI. Owns season list, in-memory `[Int: [String: Player]]` cache, league summaries, current tab/season, and bootstrap/error state. All view → data calls go through here; views never touch the actors directly.
3. **Actor services** — `NFLDataService` (network + disk cache for nflverse data) and `LeagueStore` (JSON file persistence). Both are singletons (`.shared`) and `actor`-isolated; `AppState` awaits them on the MainActor.
4. **`Fantasy` enum** (`Fantasy.swift`) — pure, framework-free domain logic: `search`, `rank`, `generateSchedule` (round-robin with bye marker for odd team counts), `teamWeekScore`, `scoreboard`, `standings`. No I/O. This is the layer to unit-test if a test target is ever added.

The codebase opts into `SWIFT_APPROACHABLE_CONCURRENCY = YES`. Isolation is declared explicitly per type: `AppState` is `@MainActor`, SwiftUI views are implicitly MainActor via `View`, and the services are `actor`s. Data types in `Models.swift` and pure helpers in `Fantasy.swift` are non-isolated and Sendable. Do **not** add `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — it forces MainActor onto the data layer and breaks synchronous calls from the actor services.

## Data flow

- **NFL stats**: `NFLDataService` downloads `stats_player_week_{season}.csv` from `github.com/nflverse/nflverse-data` releases. CSVs are cached on disk in `Caches/nflverse/` for 6h (`ttl`), parsed once and memoized in-process. `availableSeasons()` probes years from the current year down to 2016 with HEAD requests (slow on first cold launch — cached after).
- **CSV parsing**: hand-rolled RFC 4180 parser in `NFLDataService.swift` (`CSVParser.parse`) — handles quoted fields, embedded commas/newlines, and `""` escaping. Filters to regular-season rows (`season_type == "REG"`). Half-PPR is computed locally as `standard + 0.5 * receptions` (nflverse only ships standard + PPR).
- **Leagues**: `LeagueStore` persists a single `leagues.json` envelope to `Documents/` using ISO-8601 dates and atomic writes via `replaceItemAt`. Schedule is generated at creation time by `Fantasy.generateSchedule` (circle/round-robin algorithm; teams count made even with a `__bye__` sentinel).
- **Scoring**: `Scoring` enum (`.standard | .ppr | .half`) flows through every points calculation — `Game.points(scoring:)` and `SeasonTotals.points(scoring:)` pick the right pre-computed field.

## Conventions

- Comments are sparse and explain *why*, not *what*. Most files open with a 1–2 line header describing intent (see `Fantasy.swift`, `NFLDataService.swift`, `LeagueStore.swift`); match that style.
- Models live in `Models.swift` as plain `Codable`/`Hashable` structs/enums. View-specific projections (`PlayerSummary`, `Rank`, `LeagueRosterEntry`, `StandingsRow`) are built by `Fantasy` methods, not stored.
- `Fantasy.round2` is used everywhere for display — round at the boundary, keep raw doubles internally.
- League/team IDs are 8-char hex from `SecRandomCopyBytes` (`LeagueStore.newID`).
