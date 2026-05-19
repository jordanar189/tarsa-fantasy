import Foundation

// Invite deep links. The shareable artifact is now a tappable link rather
// than a bare code; the existing 6-char join code remains the payload (and
// the DB lookup key), so manual entry still works as a fallback.
// Format: tarsafantasy://join/ABC123
enum JoinLink {
    static let scheme = "tarsafantasy"
    static let host = "join"

    /// Builds the shareable invite link for a join code, or nil if the code
    /// is empty.
    static func url(forCode code: String) -> URL? {
        guard let normalized = normalize(code) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(normalized)"
        return components.url
    }

    /// Extracts a join code from an incoming invite link, or nil if the URL
    /// isn't one of ours. Accepts both `join/CODE` and `join?code=CODE`.
    static func code(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let code = normalize(path) { return code }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code" }?.value
        return query.flatMap(normalize)
    }

    private static func normalize(_ raw: String) -> String? {
        let cleaned = String(raw.uppercased().filter { $0.isLetter || $0.isNumber })
        return cleaned.isEmpty ? nil : cleaned
    }
}
