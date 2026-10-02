import Foundation

enum HTTP {
    /// One session for the whole app: thumbnail indexes are large, cover images
    /// are many, and both benefit from connection reuse.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadRevalidatingCacheData
        config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 64 << 20)
        return URLSession(configuration: config)
    }()

    /// The server answered, but not with a success. The code is carried so a
    /// caller can tell "this release does not exist" (404) from "you have asked
    /// too often" (403) and stop rather than retry.
    struct Failure: Error {
        let status: Int
    }

    static func data(from url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw Failure(status: http.statusCode)
        }
        return data
    }
}
