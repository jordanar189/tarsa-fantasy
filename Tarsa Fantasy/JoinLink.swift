import Foundation

// Invite deep links. The shareable artifact is a tappable link rather than a
// bare code; the existing 6-char join code remains the payload (and the DB
// lookup key), so manual entry still works as a fallback.
//
// Primary (shared) link is a universal link served from tarsa.net:
//   https://tarsa.net/join/ABC123
// The custom scheme is still registered and parsed as a secondary fallback:
//   tarsafantasy://join/ABC123
enum JoinLink {
    static let webHost = "tarsa.net"
    static let pathPrefix = "join"
    static let scheme = "tarsafantasy"

    /// Builds the shareable universal invite link for a join code, or nil if
    /// the code is empty.
    static func url(forCode code: String) -> URL? {
        guard let normalized = normalize(code) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = webHost
        components.path = "/\(pathPrefix)/\(normalized)"
        return components.url
    }

    /// Extracts a join code from an incoming link, or nil if the URL isn't
    /// one of ours. Accepts the universal link (https://tarsa.net/join/CODE)
    /// and the custom scheme (tarsafantasy://join/CODE or ?code=CODE).
    static func code(from url: URL) -> String? {
        switch url.scheme?.lowercased() {
        case "https", "http":
            guard let host = url.host?.lowercased(),
                  host == webHost || host == "www.\(webHost)" else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[0].lowercased() == pathPrefix else { return nil }
            return normalize(parts[1])
        case scheme:
            guard url.host?.lowercased() == pathPrefix else { return nil }
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let code = normalize(path) { return code }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "code" }?.value
            return query.flatMap(normalize)
        default:
            return nil
        }
    }

    private static func normalize(_ raw: String) -> String? {
        let cleaned = String(raw.uppercased().filter { $0.isLetter || $0.isNumber })
        return cleaned.isEmpty ? nil : cleaned
    }
}
