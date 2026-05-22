import Foundation

// GIF search via GIPHY. A sent GIF is just a normal chat message whose
// image_url points at GIPHY's hosted .gif — no schema change, it flows
// through the existing image bubble (rendered animated by AnimatedImageView).
//
// Migrated off Tenor, which Google is shutting down (new sign-ups ended
// Jan 2026, full shutdown June 30 2026).
//
// Requires a GIPHY API key. Get one (free) at https://developers.giphy.com —
// create an app and use its API key below. The default beta key is heavily
// rate-limited; request a production key before shipping. When the key is
// empty the picker shows a friendly "unavailable" state and search returns no
// results, so the rest of the app is unaffected.
enum GiphyConfig {
    static let apiKey = ""
    static var isConfigured: Bool { !apiKey.isEmpty }
}

// One GIF result. `previewURL` is the small version for the picker grid;
// `fullURL` is the size-capped gif embedded in the message.
struct GIFResult: Identifiable, Hashable, Sendable {
    let id: String
    let previewURL: String
    let fullURL: String
}

actor GIFService {
    static let shared = GIFService()

    private let host = "https://api.giphy.com/v1/gifs"

    // Trending GIFs for the picker's empty/landing state.
    func featured(limit: Int = 24) async -> [GIFResult] {
        await fetch(path: "trending", queryItems: baseItems(limit: limit))
    }

    func search(query: String, limit: Int = 24) async -> [GIFResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return await featured(limit: limit) }
        var items = baseItems(limit: limit)
        items.append(URLQueryItem(name: "q", value: trimmed))
        items.append(URLQueryItem(name: "lang", value: "en"))
        return await fetch(path: "search", queryItems: items)
    }

    // MARK: - Internals

    private func baseItems(limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "api_key", value: GiphyConfig.apiKey),
            URLQueryItem(name: "limit", value: String(limit)),
            // Filter out explicit content; pg-13 is the common default for a
            // chat GIF picker (g is too sparse for reaction GIFs).
            URLQueryItem(name: "rating", value: "pg-13"),
        ]
    }

    private func fetch(path: String, queryItems: [URLQueryItem]) async -> [GIFResult] {
        guard GiphyConfig.isConfigured else { return [] }
        guard var components = URLComponents(string: "\(host)/\(path)") else { return [] }
        components.queryItems = queryItems
        guard let url = components.url else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { return [] }
            guard (200..<300).contains(http.statusCode) else {
                // A bad key (401/403) or rate limit (429) returns [] just like
                // an empty result; log it in debug so misconfiguration is
                // obvious while wiring up the key.
                #if DEBUG
                print("GIFService: GIPHY \(path) returned HTTP \(http.statusCode)")
                #endif
                return []
            }
            let decoded = try JSONDecoder().decode(GiphyResponse.self, from: data)
            return decoded.data.compactMap(\.gifResult)
        } catch {
            #if DEBUG
            print("GIFService: GIPHY \(path) request failed — \(error)")
            #endif
            return []
        }
    }

    private struct GiphyResponse: Decodable {
        let data: [GiphyGif]
    }

    private struct GiphyGif: Decodable {
        let id: String
        let images: [String: GiphyImage]

        var gifResult: GIFResult? {
            let full = images["downsized"]?.url ?? images["original"]?.url
            let preview = images["fixed_width"]?.url
                ?? images["fixed_width_downsampled"]?.url
                ?? full
            guard let full, let preview else { return nil }
            return GIFResult(id: id, previewURL: preview, fullURL: full)
        }
    }

    // GIPHY's rendition dictionary mixes still/animated entries; only some
    // carry a "url", so it's optional.
    private struct GiphyImage: Decodable {
        let url: String?
    }
}
