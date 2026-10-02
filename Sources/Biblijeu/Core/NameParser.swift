import Foundation

/// Turns "Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De).z64" into
/// something you would want to read on a shelf, and keeps the bits it stripped
/// out (region, languages, disc number) because the artwork lookup needs them.
struct ParsedName {
    var title: String
    var region: String?
    var languages: [String] = []
    var revision: String?
    var disc: Int?
    var tags: [String] = []
    /// Filename minus extension, untouched -- the key libretro thumbnails use.
    var raw: String
}

enum NameParser {
    private static let regions: Set<String> = [
        "europe", "usa", "japan", "world", "france", "germany", "italy", "spain",
        "korea", "china", "taiwan", "brazil", "australia", "canada", "netherlands",
        "sweden", "norway", "denmark", "finland", "russia", "asia", "uk",
        "usa, europe", "japan, usa", "europe, australia", "japan, europe",
        "united kingdom", "hong kong", "greece", "portugal", "poland", "unknown"
    ]

    private static let regionLabels: [String: String] = [
        "europe": "Europe", "usa": "États-Unis", "japan": "Japon", "world": "Monde",
        "france": "France", "germany": "Allemagne", "italy": "Italie", "spain": "Espagne",
        "korea": "Corée", "china": "Chine", "taiwan": "Taïwan", "brazil": "Brésil",
        "australia": "Australie", "canada": "Canada", "netherlands": "Pays-Bas",
        "sweden": "Suède", "norway": "Norvège", "denmark": "Danemark",
        "finland": "Finlande", "russia": "Russie", "asia": "Asie",
        "uk": "Royaume-Uni", "united kingdom": "Royaume-Uni", "greece": "Grèce",
        "portugal": "Portugal", "poland": "Pologne", "hong kong": "Hong Kong",
        "unknown": "Région inconnue"
    ]

    private static let languageCodes: Set<String> = [
        "en", "fr", "de", "es", "it", "ja", "nl", "pt", "sv", "no", "da", "fi",
        "zh", "ko", "ru", "pl", "cs", "hu", "tr", "ar", "he", "el", "ca",
        "zh-hant", "zh-hans", "pt-br", "es-419"
    ]

    /// Tokens that mean "this is a dump attribute", never part of the title.
    private static let noiseTokens: Set<String> = [
        "beta", "proto", "prototype", "demo", "sample", "unl", "unlicensed",
        "alt", "pirate", "aftermarket", "kiosk", "virtual console", "gamecube",
        "wii virtual console", "switch online", "nintendo power", "decrypted",
        "encrypted", "trimmed", "nkit", "scrubbed", "redump", "no-intro"
    ]

    static func parse(_ url: URL) -> ParsedName {
        let raw = url.deletingPathExtension().lastPathComponent
        return parse(name: raw)
    }

    static func parse(name raw: String) -> ParsedName {
        var result = ParsedName(title: raw, raw: raw)
        var working = raw

        // 1. Pull out every (…) and […] group, classify it, and remove it.
        let groupPattern = try! NSRegularExpression(pattern: "[\\(\\[]([^\\)\\]]*)[\\)\\]]")
        let ns = working as NSString
        var groups: [String] = []
        for m in groupPattern.matches(in: working, range: NSRange(location: 0, length: ns.length)) {
            groups.append(ns.substring(with: m.range(at: 1)))
        }
        working = groupPattern.stringByReplacingMatches(
            in: working, range: NSRange(location: 0, length: ns.length), withTemplate: " ")

        for group in groups {
            classify(group, into: &result)
        }

        // 2. Tidy the leftover title.
        working = working
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—.·"))

        // 3. Some dumps use hyphens instead of parentheses:
        //    "Super-Mario-Sunshine-Europe-En-Fr-De-Es-It".
        if !working.contains(" "), working.contains("-") {
            working = unpackHyphenatedName(working, into: &result)
        }

        // 4. "Legend of Zelda, The" reads better as "The Legend of Zelda".
        result.title = moveTrailingArticle(working)
        if result.title.isEmpty { result.title = raw }
        return result
    }

    private static func classify(_ group: String, into result: inout ParsedName) {
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()

        if regions.contains(lower) {
            result.region = regionLabels[lower] ?? trimmed
            return
        }
        // "En,Fr,De" or "En,Ja,Fr,De,Es,It,Zh-Hant"
        let parts = lower.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty, parts.allSatisfy({ languageCodes.contains($0) }) {
            result.languages = parts.map { $0.uppercased() }
            return
        }
        if let match = lower.range(of: "^(disc|disk|disque|cd)\\s*([0-9]+)$", options: .regularExpression) {
            let digits = lower[match].filter(\.isNumber)
            result.disc = Int(digits)
            return
        }
        if lower.hasPrefix("rev ") || lower.hasPrefix("v") && lower.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) {
            result.revision = trimmed
            return
        }
        // Title ids like 01006BB00C6F0000 carry no meaning for a human.
        if trimmed.count >= 12, trimmed.allSatisfy({ $0.isHexDigit }) { return }
        if noiseTokens.contains(lower) {
            result.tags.append(trimmed)
            return
        }
        result.tags.append(trimmed)
    }

    /// Strips trailing region/language tokens off a hyphen-separated dump name.
    private static func unpackHyphenatedName(_ name: String, into result: inout ParsedName) -> String {
        var tokens = name.split(separator: "-").map(String.init)
        var languages: [String] = []
        var region: String?

        while let last = tokens.last {
            let lower = last.lowercased()
            if languageCodes.contains(lower) {
                languages.insert(last.uppercased(), at: 0)
                tokens.removeLast()
            } else if regions.contains(lower) {
                region = regionLabels[lower] ?? last
                tokens.removeLast()
            } else {
                break
            }
        }
        if result.region == nil { result.region = region }
        if result.languages.isEmpty { result.languages = languages }
        return tokens.joined(separator: " ")
    }

    private static func moveTrailingArticle(_ title: String) -> String {
        // "Legend of Zelda, The - Ocarina of Time" -> article sits before the dash.
        let articles = ["The", "A", "An", "Le", "La", "Les", "Les ", "L'", "Der", "Die", "Das", "El", "Los"]
        for article in articles {
            let needle = ", \(article)"
            if let range = title.range(of: needle) {
                let head = String(title[title.startIndex..<range.lowerBound])
                let tail = String(title[range.upperBound...])
                let joined = "\(article) \(head)\(tail)"
                return joined.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
                             .trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

    /// Lowercase, accent-free, punctuation-free -- used to compare a ROM name
    /// with the entries of a thumbnail index.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The title with every (…) group removed, normalised. Two dumps of the same
    /// game in different regions share this.
    static func normalizedCore(_ text: String) -> String {
        let withoutGroups = text.replacingOccurrences(
            of: "[\\(\\[][^\\)\\]]*[\\)\\]]", with: " ", options: .regularExpression)
        return normalize(withoutGroups)
    }

    /// Common words that say nothing about which game this is.
    static let stopWords: Set<String> = ["the", "a", "an", "of", "and", "le", "la", "les", "de", "du"]

    static func tokens(_ text: String) -> Set<String> {
        Set(normalize(text).split(separator: " ").map(String.init)).subtracting(stopWords)
    }
}
