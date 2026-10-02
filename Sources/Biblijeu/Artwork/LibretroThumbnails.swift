import Foundation

/// Box art from thumbnails.libretro.com.
///
/// The archive is keyed by No-Intro / Redump filenames, which is exactly how
/// most ROM dumps are named -- so an exact match is common, and when it isn't,
/// comparing the index against the ROM name gets there anyway. No API key.
actor LibretroThumbnails {
    static let shared = LibretroThumbnails()

    enum Variant: String {
        case boxart = "Named_Boxarts"
        case title = "Named_Titles"
        case snap = "Named_Snaps"
    }

    struct Match {
        let filename: String       // "Super Mario Sunshine (Europe) (En,Fr,De,Es,It).png"
        let libretroFolder: String

        func url(_ variant: Variant) -> String? {
            let base = "https://thumbnails.libretro.com"
            guard let folder = libretroFolder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed()),
                  let file = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed())
            else { return nil }
            return "\(base)/\(folder)/\(variant.rawValue)/\(file)"
        }
    }

    private struct Entry {
        let filename: String
        let fullNorm: String
        let coreNorm: String
        let tokens: Set<String>
        /// Tokens of the whole name, parentheses included -- this is what tells
        /// "Tekken 3 (Europe)" apart from "Tekken 3 (Europe) (Demo)".
        let fullTokens: Set<String>
        let region: String?
    }

    /// Words that mark a dump as something other than the plain retail release.
    private static let noiseTokens: Set<String> = [
        "demo", "beta", "proto", "prototype", "sample", "kiosk", "alt",
        "unl", "pirate", "hack", "trial", "preview", "debug", "test",
        "aftermarket", "promo", "bonus"
    ]

    private var indexes: [String: [Entry]] = [:]
    private var loading: [String: Task<[Entry], Never>] = [:]
    private let cacheDirectory: URL
    /// Indexes change rarely; a month between refreshes is plenty.
    private let maxAge: TimeInterval = 30 * 24 * 3600

    init() {
        cacheDirectory = AppSettings.supportDirectory
            .appendingPathComponent("ThumbnailIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Best cover for `rawName` on `system`, or nil when the archive has nothing.
    func match(rawName: String, system: GameSystem, preferredRegion: String) async -> Match? {
        await ranked(rawName: rawName, system: system, preferredRegion: preferredRegion,
                     threshold: 0.72, limit: 1).first
    }

    /// The plausible covers, best first, for the user to choose among when the
    /// automatic pick is wrong. Deliberately looser than `match`: a wrong first
    /// guess usually means the right one was just below the threshold.
    func candidates(rawName: String, system: GameSystem,
                    preferredRegion: String, limit: Int = 14) async -> [Match] {
        await ranked(rawName: rawName, system: system, preferredRegion: preferredRegion,
                     threshold: 0.24, limit: limit)
    }

    private func ranked(rawName: String, system: GameSystem, preferredRegion: String,
                        threshold: Double, limit: Int) async -> [Match] {
        guard let folder = system.libretroFolder else { return [] }
        let entries = await index(for: folder)
        guard !entries.isEmpty else { return [] }

        let fullNorm = NameParser.normalize(rawName)
        let coreNorm = NameParser.normalizedCore(rawName)
        let queryTokens = NameParser.tokens(coreNorm)
        let queryFullTokens = NameParser.tokens(fullNorm)
        guard !queryTokens.isEmpty else { return [] }
        let wanted = Self.regionKey(forLabel: preferredRegion)
        let queryRegion = Self.regionKey(inName: rawName)

        var scored: [(entry: Entry, score: Double)] = []
        for entry in entries {
            var score: Double

            if entry.fullNorm == fullNorm {
                score = 1000
            } else if entry.coreNorm == coreNorm {
                score = 500
            } else {
                let intersection = queryTokens.intersection(entry.tokens).count
                guard intersection > 0 else { continue }
                let union = queryTokens.union(entry.tokens).count
                let jaccard = Double(intersection) / Double(union)
                guard jaccard >= threshold else { continue }
                score = 300 * jaccard
            }

            if let region = entry.region {
                if let queryRegion, region == queryRegion { score += 40 }
                else if region == wanted { score += 25 }
                else if region == "world" { score += 12 }
            }
            // Among dumps of the same game, prefer the one whose extra
            // qualifiers the ROM name also carries.
            let union = queryFullTokens.union(entry.fullTokens).count
            if union > 0 {
                let shared = queryFullTokens.intersection(entry.fullTokens).count
                score += 30 * Double(shared) / Double(union)
            }
            // "(Demo)", "(Beta)", "(Alt)" -- only wanted if the ROM says so.
            let unwantedNoise = entry.fullTokens.intersection(Self.noiseTokens)
                .subtracting(queryFullTokens)
            score -= 18 * Double(unwantedNoise.count)
            score -= Double(max(0, entry.tokens.subtracting(queryTokens).count))

            scored.append((entry, score))
        }

        return scored.sorted { $0.score > $1.score }
            .prefix(limit)
            .map { Match(filename: $0.entry.filename, libretroFolder: folder) }
    }

    // MARK: - Index

    private func index(for folder: String) async -> [Entry] {
        if let cached = indexes[folder] { return cached }
        if let running = loading[folder] { return await running.value }

        let task = Task<[Entry], Never> { [cacheDirectory, maxAge] in
            let file = cacheDirectory.appendingPathComponent(Self.slug(folder) + ".txt")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modified = attributes[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) < maxAge,
               let text = try? String(contentsOf: file, encoding: .utf8) {
                return Self.entries(fromNames: text.split(separator: "\n").map(String.init))
            }
            guard let names = await Self.download(folder: folder) else {
                // Serve a stale index rather than nothing when the network is down.
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    return Self.entries(fromNames: text.split(separator: "\n").map(String.init))
                }
                return []
            }
            try? names.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            return Self.entries(fromNames: names)
        }
        loading[folder] = task
        let entries = await task.value
        loading[folder] = nil
        if !entries.isEmpty { indexes[folder] = entries }
        return entries
    }

    private static func download(folder: String) async -> [String]? {
        guard let encoded = folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed()),
              let url = URL(string: "https://thumbnails.libretro.com/\(encoded)/Named_Boxarts/"),
              let data = try? await HTTP.data(from: url),
              let html = String(data: data, encoding: .utf8) else { return nil }

        // The listing is a plain Apache-style index of <a href="…png">.
        let pattern = try! NSRegularExpression(pattern: "href=\"([^\"]+\\.png)\"")
        let ns = html as NSString
        var names: [String] = []
        names.reserveCapacity(4000)
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let encodedName = ns.substring(with: match.range(at: 1))
            guard let name = encodedName.removingPercentEncoding else { continue }
            names.append(name)
        }
        return names.isEmpty ? nil : names
    }

    private static func entries(fromNames names: [String]) -> [Entry] {
        names.compactMap { name in
            let base = (name as NSString).deletingPathExtension
            guard !base.isEmpty else { return nil }
            let core = NameParser.normalizedCore(base)
            let full = NameParser.normalize(base)
            return Entry(filename: name,
                         fullNorm: full,
                         coreNorm: core,
                         tokens: NameParser.tokens(core),
                         fullTokens: NameParser.tokens(full),
                         region: regionKey(inName: base))
        }
    }

    // MARK: - Regions

    private static let regionKeys = [
        "europe", "usa", "japan", "world", "france", "germany", "italy", "spain",
        "korea", "australia", "brazil", "china", "taiwan", "netherlands", "sweden"
    ]

    private static let labelToKey: [String: String] = [
        "europe": "europe", "france": "france", "états-unis": "usa", "etats-unis": "usa",
        "usa": "usa", "japon": "japan", "japan": "japan", "monde": "world", "world": "world"
    ]

    static func regionKey(forLabel label: String) -> String {
        labelToKey[label.lowercased()] ?? "europe"
    }

    static func regionKey(inName name: String) -> String? {
        let lower = name.lowercased()
        return regionKeys.first { lower.contains("(\($0)") }
    }

    private static func slug(_ folder: String) -> String {
        folder.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
    }

    /// Drops every cached index so the next lookup re-downloads.
    func clearIndexCache() {
        indexes.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}

private extension CharacterSet {
    /// Path-safe set that still escapes `#`, `?` and friends inside file names.
    static func urlPathAllowed() -> CharacterSet {
        var set = CharacterSet.alphanumerics
        // No space: it must become %20 or URL(string:) rejects the result.
        set.insert(charactersIn: "-._~()[]!$&'*+,;=:@")
        return set
    }
}
