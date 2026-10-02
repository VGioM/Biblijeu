import Foundation

/// Covers for anything libretro's archive doesn't carry -- Switch titles,
/// Windows games, native macOS games. Needs a free key from steamgriddb.com.
actor SteamGridDBProvider {
    static let shared = SteamGridDBProvider()

    private struct SearchResponse: Decodable {
        struct Game: Decodable { let id: Int; let name: String }
        let success: Bool
        let data: [Game]
    }

    private struct GridResponse: Decodable {
        struct Grid: Decodable { let url: String; let thumb: String? }
        let success: Bool
        let data: [Grid]
    }

    private var searchCache: [String: Int?] = [:]

    /// A 600x900 cover for `title`, or nil.
    func cover(for title: String, apiKey: String) async -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        guard let gameID = await gameID(for: title, apiKey: key) else { return nil }

        var components = URLComponents(string: "https://www.steamgriddb.com/api/v2/grids/game/\(gameID)")!
        components.queryItems = [
            URLQueryItem(name: "dimensions", value: "600x900,342x482"),
            URLQueryItem(name: "types", value: "static"),
            URLQueryItem(name: "nsfw", value: "false"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components.url,
              let data = try? await HTTP.data(from: url, headers: ["Authorization": "Bearer \(key)"]),
              let response = try? JSONDecoder().decode(GridResponse.self, from: data),
              response.success else { return nil }
        return response.data.first?.url
    }

    /// Several covers, from several candidate games, for the correction sheet.
    /// The autocomplete is fuzzy, so the right title is often the third one.
    func candidates(for title: String, apiKey: String, limit: Int = 12) async -> [(name: String, url: String)] {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }
        let games = await search(title, apiKey: key).prefix(5)
        guard !games.isEmpty else { return [] }

        // Most covers for the best match, a couple for each alternative.
        var result: [(name: String, url: String)] = []
        for (index, game) in games.enumerated() {
            let wanted = index == 0 ? 6 : 2
            for url in await grids(for: game.id, apiKey: key, limit: wanted) {
                result.append((game.name, url))
                if result.count >= limit { return result }
            }
        }
        return result
    }

    private func grids(for gameID: Int, apiKey: String, limit: Int) async -> [String] {
        var components = URLComponents(string: "https://www.steamgriddb.com/api/v2/grids/game/\(gameID)")!
        components.queryItems = [
            URLQueryItem(name: "dimensions", value: "600x900,342x482"),
            URLQueryItem(name: "types", value: "static"),
            URLQueryItem(name: "nsfw", value: "false"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url,
              let data = try? await HTTP.data(from: url, headers: ["Authorization": "Bearer \(apiKey)"]),
              let response = try? JSONDecoder().decode(GridResponse.self, from: data),
              response.success else { return [] }
        return response.data.map(\.url)
    }

    private func search(_ title: String, apiKey: String) async -> [SearchResponse.Game] {
        let normalized = NameParser.normalize(title)
        guard let escaped = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://www.steamgriddb.com/api/v2/search/autocomplete/\(escaped)"),
              let data = try? await HTTP.data(from: url, headers: ["Authorization": "Bearer \(apiKey)"]),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data),
              response.success else { return [] }
        return response.data
    }

    private func gameID(for title: String, apiKey: String) async -> Int? {
        let normalized = NameParser.normalize(title)
        if let cached = searchCache[normalized] { return cached }

        guard let escaped = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://www.steamgriddb.com/api/v2/search/autocomplete/\(escaped)"),
              let data = try? await HTTP.data(from: url, headers: ["Authorization": "Bearer \(apiKey)"]),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data),
              response.success else {
            return nil
        }

        // Prefer an exact title match; the autocomplete is fuzzy enough to
        // return sequels and spin-offs first.
        let exact = response.data.first { NameParser.normalize($0.name) == normalized }
        let id = (exact ?? response.data.first)?.id
        searchCache[normalized] = id
        return id
    }

    /// Confirms a key works, for the button in Settings.
    func validate(key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let url = URL(string: "https://www.steamgriddb.com/api/v2/search/autocomplete/zelda") else { return false }
        guard let data = try? await HTTP.data(from: url, headers: ["Authorization": "Bearer \(trimmed)"]),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return false }
        return response.success
    }
}
