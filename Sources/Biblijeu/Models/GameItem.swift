import Foundation

enum GameKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case rom        // a file played through an emulator
    case game       // a native macOS game or game launcher
    case emulator   // an emulator app
    case other      // kept in the library, but not a game: a script, a tool

    var id: String { rawValue }

    /// ROMs and native games both sit under their system in the sidebar --
    /// a macOS game belongs in "Jeu macOS" just as an SNES ROM belongs in
    /// "Super Nintendo". Emulators and loose files have no system of their own.
    var belongsToSystem: Bool { self == .rom || self == .game }

    var label: String {
        switch self {
        case .rom: return "ROM"
        case .game: return "Jeu"
        case .emulator: return "Émulateur"
        case .other: return "Autre"
        }
    }
}

/// One tile in the library: a ROM (possibly several discs), a native game, or
/// an emulator found in /Applications.
struct GameItem: Identifiable, Hashable {
    let id: String
    var kind: GameKind
    var title: String
    var sortTitle: String
    var systemID: String
    var url: URL
    /// Extra discs of a multi-disc game, in order. Empty for everything else.
    var discs: [URL] = []
    var region: String?
    var languages: [String] = []
    var revision: String?
    var tags: [String] = []
    var fileSize: Int64 = 0
    var dateAdded: Date = .distantPast
    var bundleID: String?
    var appVersion: String?
    var sourceRoot: URL?
    /// Filename as found on disk, minus extension -- what the artwork lookup matches on.
    var rawName: String = ""
    /// A picture the scan already found for this game, before any lookup:
    /// CrossOver keeps one for every start-menu entry it makes.
    var localArtwork: URL?

    var system: GameSystem? { SystemCatalog.system(systemID) }

    var isMultiDisc: Bool { discs.count > 1 }

    var symbol: String {
        switch kind {
        case .emulator: return "cpu"
        case .game: return "app.badge"
        case .other: return "doc.text"
        case .rom: return system?.symbol ?? "gamecontroller"
        }
    }

    /// "SNES · France · 1,0 Mo"
    var subtitle: String {
        var parts: [String] = []
        if kind == .other { parts.append("Autre") }
        else if let system { parts.append(system.shortName) }
        if let region { parts.append(region) }
        if isMultiDisc { parts.append("\(discs.count) disques") }
        if fileSize > 0 { parts.append(GameItem.sizeFormatter.string(fromByteCount: fileSize)) }
        if kind != .rom, let appVersion { parts.append("v\(appVersion)") }
        return parts.joined(separator: " · ")
    }

    /// Text the search field matches against.
    var searchHaystack: String {
        [title, rawName, region ?? "", system?.name ?? "", system?.shortName ?? "",
         tags.joined(separator: " ")].joined(separator: " ").lowercased()
    }

    static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f
    }()

    /// Stable id that survives relaunch: the path, hashed.
    /// What identifies a game between two runs of Biblijeu.
    ///
    /// The file name and its size, never the folder around it: a library moved
    /// onto an external drive is the same library, and hashing the full path
    /// would orphan every favourite, jaquette, historique and sauvegarde
    /// repérée the moment the drive letter changed. Two files sharing a name
    /// *and* a byte count are the same dump for our purposes.
    static func identifier(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return hash("\(url.lastPathComponent.lowercased()):\(size)")
    }

    /// How games were identified before: the full path. Kept so the state
    /// recorded under the old identity can be carried over once.
    static func legacyIdentifier(for url: URL) -> String {
        hash(url.standardizedFileURL.path)
    }

    private static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}

/// How the grid is ordered.
enum GameSortOrder: String, CaseIterable, Identifiable {
    case title = "Titre"
    case recentlyPlayed = "Joué récemment"
    case recentlyAdded = "Ajouté récemment"
    case system = "Console"
    case size = "Taille"

    var id: String { rawValue }
}
