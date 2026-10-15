import AppKit
import Foundation

/// One game the macOS Steam client has installed, read from its manifest.
struct SteamGame: Hashable {
    let appID: Int
    let name: String
    /// `…/steamapps/common/<installdir>`: where the game's files are.
    let folder: URL

    /// What Steam opens to start the game, with whatever compatibility tool
    /// the user picked for it -- NotProton hands a Windows game to CrossOver.
    var launchURL: URL { URL(string: "steam://rungameid/\(appID)")! }
}

/// A program the user added to Steam with « Ajouter un jeu non-Steam ».
struct SteamShortcut: Hashable {
    /// What Steam opens it with: the shortcut's own id in the high half,
    /// the "this is a shortcut" mark in the low one.
    let gameID: UInt64
    let name: String
    let executable: URL
    /// The Steam account whose list it is on, which keeps its custom art.
    let userFolder: URL
}

/// Reads the macOS Steam client's libraries.
///
/// A Windows game installed by Steam through a compatibility tool such as
/// NotProton has no bottle of its own and no start-menu entry: only Steam
/// knows how to start it. Biblijeu therefore asks Steam to, instead of
/// running the `.exe` in whichever bottle it could find.
enum Steam {

    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam")
    }

    /// Steam's own pieces, which it installs like games but which are not.
    private static let toolNames = ["redistributable", "steamworks", "steam linux runtime",
                                    "proton", "steamvr"]

    // MARK: - Libraries

    /// Every `steamapps` folder Steam keeps games in, the default one first.
    static func libraries() -> [URL] {
        let main = root.appendingPathComponent("steamapps")
        var result = [main]
        let list = main.appendingPathComponent("libraryfolders.vdf")
        if let text = try? String(contentsOf: list, encoding: .utf8) {
            for path in values(of: "path", in: text) {
                let url = URL(fileURLWithPath: path).appendingPathComponent("steamapps")
                if !result.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                    result.append(url)
                }
            }
        }
        return result.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The fully installed games of every library -- not one still
    /// downloading, and not the runtimes Steam installs alongside them.
    static func installedGames() -> [SteamGame] {
        var games: [SteamGame] = []
        for library in libraries() {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: library, includingPropertiesForKeys: nil) else { continue }
            for manifest in contents where manifest.lastPathComponent.hasPrefix("appmanifest_")
                && manifest.pathExtension == "acf" {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let appID = values(of: "appid", in: text).first.flatMap({ Int($0) }),
                      let name = values(of: "name", in: text).first,
                      let installdir = values(of: "installdir", in: text).first,
                      let flags = values(of: "StateFlags", in: text).first.flatMap({ Int($0) }),
                      flags & 4 != 0 else { continue }
                let lower = name.lowercased()
                if toolNames.contains(where: { lower.contains($0) }) { continue }
                let folder = library.appendingPathComponent("common").appendingPathComponent(installdir)
                guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                games.append(SteamGame(appID: appID, name: name, folder: folder))
            }
        }
        return games
    }

    /// The folders worth watching for a game being installed or removed, or
    /// added to Steam by hand.
    static func watchPaths() -> [String] {
        (libraries() + userFolders().map { $0.appendingPathComponent("config") })
            .map(\.path)
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Every game Steam can start, as the ids it starts them by: what tells a
    /// game appearing or going away from Steam merely writing to its files.
    static func knownGameIDs() -> Set<UInt64> {
        Set(installedGames().map { UInt64($0.appID) } + shortcuts().map(\.gameID))
    }

    // MARK: - Games added by hand

    /// `userdata/<account>`: one per Steam account that signed in on this Mac.
    private static func userFolders() -> [URL] {
        let folder = root.appendingPathComponent("userdata")
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.filter { Int($0.lastPathComponent) != nil }
    }

    /// The programs added to Steam by hand, on every account, hidden ones left
    /// out.
    static func shortcuts() -> [SteamShortcut] {
        var result: [SteamShortcut] = []
        var seen = Set<UInt64>()
        for user in userFolders() {
            let file = user.appendingPathComponent("config/shortcuts.vdf")
            guard let data = try? Data(contentsOf: file),
                  let root = BinaryVDF.parse(data)["shortcuts"] as? [String: Any] else { continue }
            for case let entry as [String: Any] in root.values {
                let field = { (name: String) in
                    entry.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
                }
                guard let id = field("appid") as? UInt32,
                      let name = field("AppName") as? String, !name.isEmpty,
                      let exe = field("Exe") as? String, !exe.isEmpty,
                      (field("IsHidden") as? UInt32 ?? 0) == 0 else { continue }
                // Steam writes the path in quotes, the way a command line would.
                let path = exe.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                let gameID = UInt64(id) << 32 | 0x0200_0000
                guard seen.insert(gameID).inserted else { continue }
                result.append(SteamShortcut(gameID: gameID, name: name,
                                            executable: URL(fileURLWithPath: path),
                                            userFolder: user))
            }
        }
        return result
    }

    /// The cover the user gave a shortcut in Steam, if any.
    private static func cover(for shortcut: SteamShortcut) -> URL? {
        let id = shortcut.gameID >> 32
        let grid = shortcut.userFolder.appendingPathComponent("config/grid")
        return ["png", "jpg"].lazy
            .map { grid.appendingPathComponent("\(id)p.\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The cover Steam already downloaded for its own library view.
    static func cover(for appID: Int) -> URL? {
        let folder = root.appendingPathComponent("appcache/librarycache/\(appID)")
        let direct = folder.appendingPathComponent("library_600x900.jpg")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        // Newer clients file it one level down, under a content hash, and
        // call it a capsule.
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in walker
            where ["library_600x900.jpg", "library_capsule.jpg"].contains(url.lastPathComponent) {
            return url
        }
        return nil
    }

    // MARK: - Launching

    static func launch(gameID: UInt64, name: String, completion: @escaping (Error?) -> Void) {
        let url = URL(string: "steam://rungameid/\(gameID)")!
        let opened = NSWorkspace.shared.open(url)
        completion(opened ? nil : Launcher.LaunchError.failed(
            name, underlying: "Steam est introuvable."))
    }

    static func commandPreview(gameID: UInt64) -> String {
        "open steam://rungameid/\(gameID)"
    }

    // MARK: - Folding Steam into the library

    /// Merges what Steam knows into what the folder scan found.
    ///
    /// A game that ships as a macOS app keeps that app, which already starts
    /// on its own. Everything else becomes one tile started through Steam --
    /// the `.exe` the scan found in its folder keeps its place, and with it
    /// its history and its cover. Either way, the other files the scan picked
    /// up in that folder go away.
    static func merge(_ games: [SteamGame], into scanned: [GameItem]) -> [GameItem] {
        guard !games.isEmpty else { return scanned }
        var items = scanned

        for game in games {
            let prefix = game.folder.standardizedFileURL.path + "/"
            let inside = items.indices.filter {
                items[$0].url.standardizedFileURL.path.hasPrefix(prefix)
            }
            // A game folder is one game: the mod loaders, bonus scripts and
            // tools lying next to it are not tiles of their own.
            let apps = inside.filter { items[$0].url.pathExtension.lowercased() == "app" }
            if !apps.isEmpty {
                let drop = Set(inside).subtracting(apps)
                items = items.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
                continue
            }

            // The game's own .exe, not a .bat from its bonus content.
            let ranked = inside.sorted { lhs, rhs in
                let l = items[lhs].url, r = items[rhs].url
                let lExe = l.pathExtension.lowercased() == "exe"
                let rExe = r.pathExtension.lowercased() == "exe"
                if lExe != rExe { return lExe }
                return l.pathComponents.count < r.pathComponents.count
            }
            if let keep = ranked.first {
                items[keep].kind = .game
                items[keep].title = game.name
                items[keep].sortTitle = NameParser.normalize(game.name)
                items[keep].steamGameID = UInt64(game.appID)
                if items[keep].localArtwork == nil { items[keep].localArtwork = cover(for: game.appID) }
                let drop = Set(inside.filter { $0 != keep })
                items = items.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            } else {
                items.append(item(for: game))
            }
        }
        return items
    }

    /// Merges the programs added to Steam by hand: the tile the scan already
    /// had for that program, if any, is now started through Steam; otherwise
    /// the program gets a tile of its own.
    static func merge(_ shortcuts: [SteamShortcut], into scanned: [GameItem]) -> [GameItem] {
        var items = scanned
        for shortcut in shortcuts {
            let path = shortcut.executable.standardizedFileURL.path
            if let index = items.firstIndex(where: { $0.url.standardizedFileURL.path == path }) {
                items[index].kind = .game
                items[index].title = shortcut.name
                items[index].sortTitle = NameParser.normalize(shortcut.name)
                items[index].steamGameID = shortcut.gameID
                if items[index].localArtwork == nil { items[index].localArtwork = cover(for: shortcut) }
            } else if FileManager.default.fileExists(atPath: path) {
                items.append(item(for: shortcut))
            }
        }
        return items
    }

    private static func item(for shortcut: SteamShortcut) -> GameItem {
        let url = shortcut.executable
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        let windows = ["exe", "bat", "msi", "lnk"].contains(url.pathExtension.lowercased())
        return GameItem(
            id: GameItem.identifier(for: url),
            kind: .game,
            title: shortcut.name,
            sortTitle: NameParser.normalize(shortcut.name),
            systemID: windows ? "windows" : "mac",
            url: url,
            fileSize: Int64(values?.fileSize ?? 0),
            dateAdded: values?.creationDate ?? .distantPast,
            sourceRoot: url.deletingLastPathComponent(),
            rawName: shortcut.name,
            localArtwork: cover(for: shortcut),
            steamGameID: shortcut.gameID)
    }

    /// A library tile for a game nothing in the ROM folders points at.
    private static func item(for game: SteamGame) -> GameItem {
        let values = try? game.folder.resourceValues(forKeys: [.creationDateKey])
        return GameItem(
            id: GameItem.identifier(for: game.folder),
            kind: .game,
            title: game.name,
            sortTitle: NameParser.normalize(game.name),
            systemID: containsWindowsProgram(game.folder) ? "windows" : "mac",
            url: game.folder,
            dateAdded: values?.creationDate ?? .distantPast,
            sourceRoot: game.folder.deletingLastPathComponent(),
            rawName: game.name,
            localArtwork: cover(for: game.appID),
            steamGameID: UInt64(game.appID))
    }

    /// True when the game's folder holds a Windows executable near the top --
    /// deep enough for `bin/win64/game.exe`, not so deep as to walk the assets.
    private static func containsWindowsProgram(_ folder: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for case let url as URL in walker {
            if walker.level > 4 { walker.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "exe" { return true }
        }
        return false
    }

    // MARK: - Reading Valve's key-value files

    /// Every value written as `"key"  "value"` in a VDF or ACF file.
    private static func values(of key: String, in text: String) -> [String] {
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: key) + "\"\\s+\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map {
                String(text[$0]).replacingOccurrences(of: "\\\\", with: "\\")
            }
        }
    }
}

/// Valve's binary key-values, the format of `shortcuts.vdf`: a type byte, a
/// zero-terminated key, then the value -- a nested table closed by 0x08, a
/// zero-terminated string, or a little-endian 32-bit integer.
enum BinaryVDF {

    static func parse(_ data: Data) -> [String: Any] {
        var reader = Reader(bytes: [UInt8](data))
        return reader.table() ?? [:]
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        mutating func table() -> [String: Any]? {
            var result: [String: Any] = [:]
            while index < bytes.count {
                let type = bytes[index]
                index += 1
                if type == 0x08 { return result }
                guard let key = string() else { return nil }
                switch type {
                case 0x00:
                    guard let nested = table() else { return nil }
                    result[key] = nested
                case 0x01:
                    guard let value = string() else { return nil }
                    result[key] = value
                case 0x02:
                    guard index + 4 <= bytes.count else { return nil }
                    result[key] = bytes[index..<index + 4].reversed()
                        .reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                    index += 4
                default:
                    // A type this reader does not know: its length is unknown,
                    // so nothing after it can be trusted.
                    return nil
                }
            }
            return result
        }

        mutating func string() -> String? {
            guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
            let text = String(decoding: bytes[index..<end], as: UTF8.self)
            index = end + 1
            return text
        }
    }
}
