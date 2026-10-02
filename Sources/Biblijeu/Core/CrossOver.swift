import Foundation

/// One CrossOver bottle: a Windows installation with its own drives, registry
/// and start menu.
struct CrossOverBottle: Hashable, Identifiable {
    let name: String
    let url: URL
    /// Bottles under `/Library` are shared between accounts; CrossOver calls
    /// them managed, and wants to be told so on the command line.
    let isManaged: Bool

    var id: String { (isManaged ? "managed:" : "private:") + name }
}

/// One entry of a bottle's Windows start menu -- a program CrossOver already
/// knows how to start, with the icon and the name it gave it.
struct CrossOverShortcut: Hashable, Identifiable {
    let bottle: CrossOverBottle
    /// "ReTHAWedLaunch": the name CrossOver shows in its own window.
    let name: String
    /// The stub CrossOver keeps for this entry: a shell script that runs wine.
    let stub: URL
    /// The launcher CrossOver put in ~/Applications/CrossOver, when it made one.
    let application: URL?
    /// The Windows program behind the entry, resolved to a file on this Mac.
    let target: URL?
    /// The icon CrossOver extracted from that program.
    let icon: URL?

    var id: String { bottle.id + "/" + name }

    /// What Biblijeu opens for this entry: the launcher app when CrossOver
    /// made one, because macOS then gives the game its own process and Dock
    /// icon; the stub otherwise.
    var launchURL: URL { application ?? stub }
}

/// Reads what CrossOver knows -- its bottles and their start menus -- and
/// starts Windows games in them.
///
/// Handing an `.exe` to CrossOver.app as a document makes it ask which bottle
/// to install into, which is not what someone who already has the game
/// installed wants. Naming the bottle on the command line is.
enum CrossOver {

    enum Failure: LocalizedError {
        case notInstalled
        case ambiguousBottle(String, [String])
        case failed(String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "CrossOver est introuvable."
            case .ambiguousBottle(let title, _):
                return "Biblijeu ne sait pas dans quelle bouteille lancer \(title)."
            case .failed(let name, let underlying):
                return "\(name) n'a pas pu démarrer.\n\(underlying)"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .notInstalled:
                return "Installez CrossOver, ou choisissez un autre émulateur pour les jeux Windows."
            case .ambiguousBottle(_, let bottles):
                return "Choisissez-la dans le panneau d'informations : \(bottles.joined(separator: ", "))."
            case .failed:
                return nil
            }
        }
    }

    // MARK: - Where CrossOver lives

    /// CrossOver itself. Looked up by path first: the scan runs off the main
    /// thread, and this is the answer in almost every install.
    static var applicationURL: URL? {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/CrossOver.app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CrossOver.app")
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    static var isInstalled: Bool { applicationURL != nil }

    /// One of CrossOver's own command line tools.
    private static func tool(_ name: String) -> URL? {
        guard let app = applicationURL else { return nil }
        let url = app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/\(name)")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: - Bottles

    /// Every bottle on this Mac, private ones first.
    static func bottles() -> [CrossOverBottle] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [(URL, Bool)] = [
            (home.appendingPathComponent("Library/Application Support/CrossOver/Bottles"), false),
            (URL(fileURLWithPath: "/Library/Application Support/CrossOver/Bottles"), true)
        ]

        var result: [CrossOverBottle] = []
        for (root, managed) in roots {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            // A bottle is a directory with a bottle configuration in it.
            for url in contents where FileManager.default.fileExists(
                atPath: url.appendingPathComponent("cxbottle.conf").path) {
                result.append(CrossOverBottle(name: url.lastPathComponent, url: url, isManaged: managed))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The directories worth watching for a game being installed into a bottle
    /// or removed from one: each bottle's menu data, and the folders where
    /// CrossOver puts the launchers it makes.
    ///
    /// Not the bottles themselves: FSEvents is recursive, and a running game
    /// writes to its registry and its save files constantly -- every write
    /// would ask for a rescan in the middle of play.
    static func watchPaths(for bottles: [CrossOverBottle]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = bottles.map { $0.url.appendingPathComponent("desktopdata") }
            + [home.appendingPathComponent("Applications/CrossOver"),
               URL(fileURLWithPath: "/Applications/CrossOver")]
        return candidates.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Start menus

    /// Every start-menu entry of every bottle.
    static func shortcuts(in bottles: [CrossOverBottle]) -> [CrossOverShortcut] {
        guard !bottles.isEmpty else { return [] }
        let applications = helperApplications()
        return bottles.flatMap { shortcuts(in: $0, applications: applications) }
    }

    private static func shortcuts(in bottle: CrossOverBottle,
                                  applications: [String: URL]) -> [CrossOverShortcut] {
        var entries = menuEntries(in: bottle)
        // A bottle whose menu plist is missing or stale still has the stubs.
        if entries.isEmpty {
            entries = stubs(in: bottle).map { (name: $0.deletingPathExtension().lastPathComponent,
                                               stub: $0, icon: nil) }
        }

        var seen = Set<String>()
        return entries.compactMap { entry in
            guard seen.insert(entry.name).inserted,
                  FileManager.default.isExecutableFile(atPath: entry.stub.path) else { return nil }
            return CrossOverShortcut(
                bottle: bottle,
                name: entry.name,
                stub: entry.stub,
                application: applications[helperKey(bottle: bottle.name, entry: entry.name)],
                target: target(of: entry.stub, in: bottle),
                icon: entry.icon)
        }
    }

    /// The start menu as CrossOver wrote it down for macOS: display names, the
    /// command behind each one, and the icon it pulled out of the program.
    private static func menuEntries(in bottle: CrossOverBottle)
        -> [(name: String, stub: URL, icon: URL?)] {
        let plist = bottle.url.appendingPathComponent("desktopdata/cxmenu/cxmenu_macosx.plist")
        guard let root = NSDictionary(contentsOf: plist) as? [String: Any] else { return [] }

        var found: [(name: String, stub: URL, icon: URL?)] = []
        func walk(_ node: [String: Any], name: String) {
            if !name.isEmpty, let command = node["Command"] as? String,
               let path = tokens(of: command).first {
                let icon = (node["Icon"] as? String).map { URL(fileURLWithPath: $0) }
                found.append((name, URL(fileURLWithPath: path),
                              icon.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }))
            }
            guard let children = node["Children"] as? [String: Any] else { return }
            for (key, value) in children {
                guard let child = value as? [String: Any] else { continue }
                // Folders are keyed with a trailing slash, entries are not.
                walk(child, name: key.hasSuffix("/") ? "" : key)
            }
        }
        for value in root.values {
            guard let node = value as? [String: Any] else { continue }
            walk(node, name: "")
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The `.lnk` stubs under a bottle's menu directory, found by hand.
    private static func stubs(in bottle: CrossOverBottle) -> [URL] {
        let menu = bottle.url.appendingPathComponent("desktopdata/cxmenu")
        guard let walker = FileManager.default.enumerator(
            at: menu, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "lnk" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    /// The launchers CrossOver keeps in an Applications folder, by bottle and
    /// entry name.
    private static func helperApplications() -> [String: URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [
            home.appendingPathComponent("Applications/CrossOver"),
            URL(fileURLWithPath: "/Applications/CrossOver")
        ]

        var result: [String: URL] = [:]
        for folder in folders {
            // CrossOver mirrors the Windows menu tree, so a game filed under a
            // publisher's folder sits one level down.
            for url in appBundles(in: folder, depth: 2) {
                let info = ApplicationScanner.bundleInfo(at: url)
                guard let bottle = info["CXHelperAppBottleName"] as? String,
                      let entry = info["CXOriginalMenuName"] as? String else { continue }
                result[helperKey(bottle: bottle, entry: entry)] = url
            }
        }
        return result
    }

    private static func appBundles(in folder: URL, depth: Int) -> [URL] {
        guard depth > 0, let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for url in contents {
            if url.pathExtension.lowercased() == "app" {
                result.append(url)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                result.append(contentsOf: appBundles(in: url, depth: depth - 1))
            }
        }
        return result
    }

    private static func helperKey(bottle: String, entry: String) -> String {
        bottle + "\u{0}" + entry
    }

    // MARK: - Resolving what a shortcut points at

    /// The Windows program a start-menu entry runs, as a file on this Mac.
    ///
    /// The stub names the `.lnk` inside the bottle; the `.lnk` names the
    /// program. Both paths are Windows paths, which the bottle's drive links
    /// turn back into real ones.
    private static func target(of stub: URL, in bottle: CrossOverBottle) -> URL? {
        guard let script = try? String(contentsOf: stub, encoding: .utf8) else { return nil }
        guard let windowsPath = argument(after: "--start", in: script),
              let link = nativeURL(forWindowsPath: windowsPath, in: bottle) else { return nil }
        guard link.pathExtension.lowercased() == "lnk" else { return link }
        guard let resolved = shellLinkTarget(at: link) else { return nil }
        return nativeURL(forWindowsPath: resolved, in: bottle)
    }

    /// Turns `Y:\Documents\game.exe` into the file it stands for, following the
    /// bottle's drive links. Falls back to a case-insensitive walk, because
    /// Windows paths do not agree with a case-sensitive disk about spelling.
    static func nativeURL(forWindowsPath path: String, in bottle: CrossOverBottle) -> URL? {
        let text = path.replacingOccurrences(of: "\\", with: "/")
        let letter = text.prefix(1).lowercased()
        guard text.dropFirst().hasPrefix(":"), letter.first?.isLetter == true else { return nil }

        let devices = bottle.url.appendingPathComponent("dosdevices")
        let link = devices.appendingPathComponent("\(letter):")
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        else { return nil }
        let base = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : devices.appendingPathComponent(destination).standardizedFileURL

        return resolve(text.dropFirst(2).split(separator: "/").map(String.init), under: base)
    }

    private static func resolve(_ components: [String], under base: URL) -> URL? {
        let fm = FileManager.default
        var url = base
        for component in components where !component.isEmpty {
            let candidate = url.appendingPathComponent(component)
            if fm.fileExists(atPath: candidate.path) {
                url = candidate
                continue
            }
            guard let siblings = try? fm.contentsOfDirectory(atPath: url.path),
                  let match = siblings.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
            else { return nil }
            url = url.appendingPathComponent(match)
        }
        return url
    }

    /// The program a Windows `.lnk` points at.
    ///
    /// A shell link is a binary structure that stores its target as plain bytes
    /// and again as UTF-16. Reading the drive-letter paths out of both and
    /// keeping the longest is enough to find the executable, and much shorter
    /// than a parser for a format nothing else here needs.
    static func shellLinkTarget(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count > 76 else { return nil }
        let candidates = windowsPaths(in: text(of: data, wide: false))
            + windowsPaths(in: text(of: data, wide: true))
        return candidates.max { $0.count < $1.count }
    }

    /// The bytes of a link, read as characters: either one byte per character,
    /// or the low byte of every UTF-16 unit. Anything unprintable becomes a
    /// separator, so a run of text cannot run into the next field.
    private static func text(of data: Data, wide: Bool) -> String {
        var characters = [Character]()
        characters.reserveCapacity(data.count)
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let low = bytes[index]
            let printable = wide
                ? (index + 1 < bytes.count && bytes[index + 1] == 0 && low >= 0x20 && low < 0x7f)
                : (low >= 0x20 && low < 0x7f)
            characters.append(printable ? Character(UnicodeScalar(low)) : "\n")
            index += wide ? 2 : 1
        }
        return String(characters)
    }

    private static let executableExtensions = ["exe", "bat", "cmd", "com", "msi"]

    /// The `X:\…\program.exe` paths in a piece of text.
    private static func windowsPaths(in text: String) -> [String] {
        let pattern = "[A-Za-z]:\\\\[^\\n\"<>|*?]{1,300}?\\.(?:"
            + executableExtensions.joined(separator: "|") + ")"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    // MARK: - Reading a stub

    /// The value that follows `flag` on the command line inside a stub script.
    private static func argument(after flag: String, in script: String) -> String? {
        for line in script.split(whereSeparator: \.isNewline) {
            let words = tokens(of: String(line))
            guard let index = words.firstIndex(of: flag), index + 1 < words.count else { continue }
            return words[index + 1]
        }
        return nil
    }

    /// The words of a simple command line, quotes removed.
    private static func tokens(of line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if quote == nil && character == "\\" {
                // Only outside quotes: a Windows path inside them is full of
                // backslashes that escape nothing.
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " || character == "\t" {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // MARK: - Launching

    /// Starts a start-menu entry the way CrossOver itself would.
    static func launch(_ shortcut: CrossOverShortcut, completion: @escaping (Error?) -> Void) {
        if let application = shortcut.application {
            Launcher.open(app: application, arguments: [], name: shortcut.name, completion: completion)
        } else {
            spawn(shortcut.stub, arguments: [], name: shortcut.name, completion: completion)
        }
    }

    /// Runs a start-menu stub found on its own, without the bottle it came
    /// from -- what an item that was scanned rather than resolved carries.
    static func launch(stub: URL, name: String, completion: @escaping (Error?) -> Void) {
        spawn(stub, arguments: [], name: name, completion: completion)
    }

    /// Runs a Windows program in a named bottle.
    static func run(_ executable: URL, in bottle: CrossOverBottle, name: String,
                    completion: @escaping (Error?) -> Void) {
        guard let cxstart = tool("cxstart") else {
            completion(Failure.notInstalled); return
        }
        spawn(cxstart, arguments: arguments(for: executable, in: bottle), name: name,
              completion: completion)
    }

    private static func arguments(for executable: URL, in bottle: CrossOverBottle) -> [String] {
        var arguments = ["--bottle", bottle.name]
        if bottle.isManaged { arguments += ["--scope", "managed"] }
        // A Windows game reads its data files from the folder it sits in, and
        // "--" keeps a path that starts with a dash out of the options.
        arguments += ["--workdir", executable.deletingLastPathComponent().path,
                      "--no-wait", "--", executable.path]
        return arguments
    }

    /// The command line Biblijeu would run, for the info panel.
    static func commandPreview(for executable: URL, in bottle: CrossOverBottle) -> String? {
        guard let cxstart = tool("cxstart") else { return nil }
        return ([cxstart.path] + arguments(for: executable, in: bottle)).map(quoted).joined(separator: " ")
    }

    static func commandPreview(for shortcut: CrossOverShortcut) -> String {
        shortcut.application.map { "open -a \(quoted($0.path))" } ?? quoted(shortcut.stub.path)
    }

    private static func quoted(_ text: String) -> String {
        text.contains(" ") ? "\"\(text)\"" : text
    }

    /// True for the stub of a start-menu entry, which is a program to run
    /// rather than a document to open.
    static func isShortcutStub(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "lnk"
            && url.path.contains("/desktopdata/cxmenu/")
    }

    private static func spawn(_ executable: URL, arguments: [String], name: String,
                              completion: @escaping (Error?) -> Void) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // cxstart talks to its own log; nothing here reads its output, and an
        // unread pipe would eventually block the game.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async {
                    completion(Failure.failed(name, underlying: error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Folding bottles into the library

    /// Words that mark a start-menu entry as something other than the game:
    /// matched whole, so a game with "Support" in a longer title is safe.
    private static let noiseWords: Set<String> = [
        "uninstall", "uninstaller", "desinstaller", "desinstallation",
        "readme", "lisezmoi", "manual", "manuel", "documentation", "help",
        "aide", "support", "eula", "license", "licence", "updater", "update",
        "winecfg", "regedit", "control", "notepad", "explorer"
    ]

    private static func looksLikeNoise(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("uninstall") || lower.contains("désinstall") { return true }
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains { noiseWords.contains(String($0)) }
    }

    /// Merges what CrossOver knows into what the folder scan found.
    ///
    /// A Windows game the scan already picked up keeps its place in the
    /// library -- with its history, its favourite mark and its cover -- and
    /// simply gains the icon CrossOver extracted for it; only the entries no
    /// scanned game accounts for become items of their own, which is how a
    /// game installed inside a bottle shows up at all.
    static func merge(_ shortcuts: [CrossOverShortcut], into scanned: [GameItem]) -> [GameItem] {
        guard !shortcuts.isEmpty else { return scanned }
        var items = scanned
        var claimed = Set<CrossOverShortcut>()

        for index in items.indices where items[index].systemID == "windows" {
            let folder = items[index].url.deletingLastPathComponent().standardizedFileURL
            let matches = shortcuts.filter { shortcut in
                guard let target = shortcut.target?.standardizedFileURL else { return false }
                return target.path.hasPrefix(folder.path + "/")
            }
            guard !matches.isEmpty else { continue }
            claimed.formUnion(matches)
            // The entry that starts the game, not the one that updates it.
            let best = matches.first { !looksLikeNoise($0.name) } ?? matches[0]
            if items[index].localArtwork == nil { items[index].localArtwork = best.icon }
        }

        for shortcut in shortcuts where !claimed.contains(shortcut) && !looksLikeNoise(shortcut.name) {
            items.append(item(for: shortcut))
        }
        return items
    }

    /// A library tile for a game that lives inside a bottle.
    private static func item(for shortcut: CrossOverShortcut) -> GameItem {
        let url = shortcut.launchURL
        let parsed = NameParser.parse(name: shortcut.name)
        let values = try? (shortcut.target ?? url).resourceValues(
            forKeys: [.creationDateKey, .fileSizeKey])

        return GameItem(
            id: GameItem.identifier(for: url),
            kind: .game,
            title: parsed.title,
            sortTitle: NameParser.normalize(parsed.title),
            systemID: "windows",
            url: url,
            region: nil,
            fileSize: Int64(values?.fileSize ?? 0),
            dateAdded: values?.creationDate ?? .distantPast,
            bundleID: nil,
            appVersion: nil,
            sourceRoot: shortcut.bottle.url,
            rawName: shortcut.name,
            localArtwork: shortcut.icon)
    }
}
