import Foundation

// GIF search via Tenor (Google). A sent GIF is just a normal chat message
// whose image_url points at Tenor's hosted .gif — no schema change, it flows
// through the existing image bubble (rendered animated by AnimatedImageView).
//
// Requires a Tenor v2 API key. Get one (free) at
// https://developers.google.com/tenor/guides/quickstart and paste it below.
// When the key is empty the picker shows a friendly "unavailable" state and
// search returns no results, so the rest of the app is unaffected.
enum TenorConfig {
    static let apiKey = ""
    // Free-form client attribution; lets Tenor return more consistent
    // ranking across calls from this app.
    static let clientKey = "tarsa_fantasy"
    static var isConfigured: Bool { !apiKey.isEmpty }
}

// One GIF result. `previewURL` is the small (tinygif) version for the picker
// grid; `fullURL` is the standard gif embedded in the message.
struct GIFResult: Identifiable, Hashable, Sendable {
    let id: String
    let previewURL: String
    let fullURL: String
}

actor GIFService {
    static let shared = GIFService()

    private let host = "https://tenor.googleapis.com/v2"

    // Trending GIFs for the picker's empty/landing state.
    func featured(limit: Int = 24) async -> [GIFResult] {
        await fetch(path: "featured", queryItems: baseItems(limit: limit))
    }

    func search(query: String, limit: Int = 24) async -> [GIFResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return await featured(limit: limit) }
        var items = baseItems(limit: limit)
        items.append(URLQueryItem(name: "q", value: trimmed))
        return await fetch(path: "search", queryItems: items)
    }

    // MARK: - Internals

    private func baseItems(limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "key", value: TenorConfig.apiKey),
            URLQueryItem(name: "client_key", value: TenorConfig.clientKey),
            URLQueryItem(name: "limit", value: String(limit)),
            // Only fetch the two formats we render; keeps payloads small.
            URLQueryItem(name: "media_filter", value: "gif,tinygif"),
            // Keep results family-friendly.
            URLQueryItem(name: "contentfilter", value: "high"),
        ]
    }

    private func fetch(path: String, queryItems: [URLQueryItem]) async -> [GIFResult] {
        guard TenorConfig.isConfigured else { return [] }
        guard var components = URLComponents(string: "\(host)/\(path)") else { return [] }
        components.queryItems = queryItems
        guard let url = components.url else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            let decoded = try JSONDecoder().decode(TenorResponse.self, from: data)
            return decoded.results.compactMap(\.gifResult)
        } catch {
            return []
        }
    }

    private struct TenorResponse: Decodable {
        let results: [TenorResult]
    }

    private struct TenorResult: Decodable {
        let id: String
        let mediaFormats: [String: TenorMedia]

        enum CodingKeys: String, CodingKey {
            case id
            case mediaFormats = "media_formats"
        }

        var gifResult: GIFResult? {
            let full = mediaFormats["gif"]?.url ?? mediaFormats["tinygif"]?.url
            let preview = mediaFormats["tinygif"]?.url ?? full
            guard let full, let preview else { return nil }
            return GIFResult(id: id, previewURL: preview, fullURL: full)
        }
    }

    private struct TenorMedia: Decodable {
        let url: String
    }
}
