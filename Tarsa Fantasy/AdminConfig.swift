import Foundation

// Hard-coded admin allowlist. A signed-in user whose username (case-insensitive)
// is in this set sees the Admin menu in the Leagues toolbar.
//
// To grant admin to another account: add the lowercase username here and
// rebuild. (If you want this to live in the database later, replace with a
// boolean column on `profiles` and a fetch in RemoteService.)
enum AdminConfig {
    static let adminUsernames: Set<String> = [
        "jordanar189",
    ]
}
