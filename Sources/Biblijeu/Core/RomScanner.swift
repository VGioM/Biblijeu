import Foundation

/// Walks the ROM folders and turns files into `GameItem`s.
///
/// Two things make this less trivial than "list every file": disc images come
/// with track files that must not show up as separate games, and an extension
/// like `.iso` belongs to six consoles at once -- which one is decided by the
/// folder the file sits in.
enum RomScanner {

    /// Folders that never contain playable games.
    private static let skippedFolders: Set<String> = [
        "firmware", "keys", "prod.keys", "bios", "system", "systems",
        "saves", "savestates", "states", "cheats", "screenshots", "manuals",
        "covers", "artwork", "media", "themes", "cores", "logs", "playlists",
        "updates", "update", "dlc", "patches", "mods", "config", "cache",
        "__macosx", "assets", "shaders", "overlays", "thumbnails", "temp",
        // Resource trees of level editors and game engines, full of .wad parts.
        "fabs", "prefabs", "addons", "modules", "presets", "engines", "tools",
        "language", "ports", "docs", "licenses", "theme", "scripts",
        // Atelier NX / nxnative next to the Switch games: save copies and build logs.
        "save", "log"
    ]

    /// Folders skipped by suffix: macOS's "do not index" convention (Atelier NX keeps its nxnative
    /// builds in `nxnative-build.noindex`) and nxnative's per-game `<title ID>_build` work folders, whose
    /// tens of thousands of files include links to the game files and RomFS images that look like discs.
    private static func isWorkFolder(_ name: String) -> Bool {
        name.hasSuffix(".noindex") || name.hasSuffix("_build")
    }

    /// `.exe` files that are never the game itself.
    private static let executableNoise = [
        "unins", "setup", "install", "vcredist", "dxsetup", "dxwebsetup",
        "directx", "crashreport", "crashhandler", "updater", "update",
        "redist", "config", "settings", "readme", "uninstall", "activation"
    ]

    /// Track/companion files that a cue sheet or playlist already covers.
    private static let trackExtensions: Set<String> = ["bin", "img", "raw", "wav", "mp3", "ape", "flac", "sub", "ccd", "mds", "ecm"]
    private static let sheetExtensions: Set<String> = ["cue", "gdi", "m3u", "toc"]

    static func scan(roots: [URL], progress: @escaping (String) -> Void) -> [GameItem] {
        var items: [GameItem] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            progress("Analyse de \(root.lastPathComponent)…")
            items.append(contentsOf: scanRoot(root, progress: progress))
        }
        return groupMultiDisc(items)
    }

    // MARK: - Walking

    private static func scanRoot(_ root: URL, progress: @escaping (String) -> Void) -> [GameItem] {
        var items: [GameItem] = []
        var directories: [URL] = [root]
        let fm = FileManager.default

        while let dir = directories.popLast() {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }

            var files: [URL] = []
            var subdirectories: [URL] = []
            for url in contents {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    let name = url.lastPathComponent.lowercased()
                    if url.pathExtension.lowercased() == "app" {
                        // A game shipped as an app bundle inside a ROM folder.
                        if let item = ApplicationScanner.item(for: url, forcedKind: .game) {
                            items.append(item)
                        }
                        continue
                    }
                    if skippedFolders.contains(name) || isWorkFolder(name) { continue }
                    if skippedFolders.contains(where: { name.hasPrefix($0 + " ") || name.hasSuffix(" " + $0) }) { continue }
                    subdirectories.append(url)
                } else {
                    files.append(url)
                }
            }

            progress("Analyse de \(dir.lastPathComponent)…")

            // An installed Windows game is a whole tree of data files around one
            // launcher. Index the launcher and stop -- descending would pull in
            // every asset the engine happens to store in a ROM-like format.
            if dir != root, let launcher = windowsLauncher(in: dir, files: files) {
                // The game is the whole tree, not the two-hundred-kilobyte
                // launcher that starts it.
                items.append(makeItem(url: launcher, system: SystemCatalog.system("windows")!,
                                      root: root, size: treeSize(of: dir)))
                continue
            }

            directories.append(contentsOf: subdirectories)
            items.append(contentsOf: games(in: dir, files: files, root: root))
        }
        return items
    }

    /// Decides which files in one directory are actual games.
    private static func games(in directory: URL, files: [URL], root: URL) -> [GameItem] {
        let extensions = Set(files.map { $0.pathExtension.lowercased() })
        // A playlist supersedes its cue sheets, and a cue sheet supersedes its tracks.
        let hasPlaylist = extensions.contains("m3u")
        let hasSheet = !extensions.isDisjoint(with: sheetExtensions)

        var items: [GameItem] = []
        for url in files {
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty else { continue }
            guard SystemCatalog.allExtensions.contains(ext) else { continue }
            if hasPlaylist, ext != "m3u", sheetExtensions.contains(ext) || trackExtensions.contains(ext) { continue }
            if hasSheet, trackExtensions.contains(ext) { continue }
            if ext == "exe" || ext == "msi" || ext == "bat" || ext == "lnk" {
                guard isPlausibleWindowsGame(url, in: directory) else { continue }
            }
            // A .zip is a MAME set only where the folder says so; everywhere
            // else it is a download nobody asked to see in their library.
            if ext == "zip" || ext == "7z" {
                guard folderHint(for: url, root: root)?.id == "arcade" else { continue }
            }
            if url.lastPathComponent.hasPrefix("._") { continue }

            guard let system = resolveSystem(for: url, extension: ext, root: root) else { continue }
            if system.id == "switch", !SwitchTitle.isBaseGame(url) { continue }
            items.append(makeItem(url: url, system: system, root: root))
        }
        return items
    }

    /// Extension narrows it down; the enclosing folder decides between the
    /// consoles that share it.
    private static func resolveSystem(for url: URL, extension ext: String, root: URL) -> GameSystem? {
        let candidates = SystemCatalog.systems(forExtension: ext)
        let hinted = folderHint(for: url, root: root)

        if let hinted {
            if candidates.contains(where: { $0.id == hinted.id }) { return hinted }
            // The folder says "PS2" but the extension is .cue -- trust the folder
            // only when the extension is a generic container.
            if candidates.isEmpty { return hinted }
            if hinted.fileExtensions.contains(ext) { return hinted }
        }
        return candidates.first
    }

    /// The nearest ancestor folder (up to the scan root) that names a console.
    private static func folderHint(for url: URL, root: URL) -> GameSystem? {
        var dir = url.deletingLastPathComponent()
        let rootPath = root.standardizedFileURL.path
        while dir.standardizedFileURL.path.hasPrefix(rootPath) {
            if let system = SystemCatalog.system(forFolderName: dir.lastPathComponent) { return system }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        // The scan root itself may be named after a console.
        return SystemCatalog.system(forFolderName: root.lastPathComponent)
    }

    /// The one executable that launches the game living in `directory`, if this
    /// directory is an installed Windows game rather than a folder of ROMs.
    private static func windowsLauncher(in directory: URL, files: [URL]) -> URL? {
        let executables = files.filter { $0.pathExtension.lowercased() == "exe" }
        guard !executables.isEmpty else { return nil }
        let candidates = executables.filter { isPlausibleWindowsGame($0, in: directory) }
        guard !candidates.isEmpty else { return executables.count > 2 ? executables[0] : nil }

        let folder = NameParser.normalize(directory.lastPathComponent)
        // "Launcher.exe" and an exe named after its folder are the usual shapes.
        let ranked = candidates.sorted { lhs, rhs in
            score(lhs, folder: folder) > score(rhs, folder: folder)
        }
        return ranked.first
    }

    private static func score(_ url: URL, folder: String) -> Int {
        let name = NameParser.normalize(url.deletingPathExtension().lastPathComponent)
        if name == folder { return 100 }
        if ["launcher", "start", "play", "game"].contains(name) { return 90 }
        if folder.contains(name) || name.contains(folder) { return 80 }
        return 10
    }

    private static func isPlausibleWindowsGame(_ url: URL, in directory: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if executableNoise.contains(where: { name.hasPrefix($0) || name.contains($0) }) { return false }
        // A game folder usually holds one obvious launcher, not a bin/ full of tools.
        let parent = directory.lastPathComponent.lowercased()
        return name == "launcher" || name == "start" || name == "play"
            || name.contains("game") || parent.contains(name) || name.contains(parent)
            || name.count > 3
    }

    // MARK: - Sizes

    /// What the game actually weighs on disk.
    ///
    /// A cue sheet is a hundred bytes of text pointing at the tracks that hold
    /// the game, and an `.m3u` points at cue sheets in turn -- reporting the
    /// size of the file that was indexed would say "0 Mo" for a 700 Mo disc.
    private static func gameSize(of url: URL, declared: Int64) -> Int64 {
        let ext = url.pathExtension.lowercased()
        guard sheetExtensions.contains(ext) else { return declared }
        var total = declared
        for referenced in referencedFiles(of: url) {
            let values = try? referenced.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize {
                total += Int64(size)
            } else {
                // An .m3u lists cue sheets, which list tracks in their turn.
                total += gameSize(of: referenced, declared: 0)
            }
        }
        return total
    }

    /// The files a cue sheet, gdi or playlist points at, resolved next to it.
    private static func referencedFiles(of sheet: URL) -> [URL] {
        let loaded = (try? String(contentsOf: sheet, encoding: .utf8))
            ?? (try? String(contentsOf: sheet, encoding: .isoLatin1))
        guard let text = loaded else { return [] }
        let directory = sheet.deletingLastPathComponent()
        var names: [String] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.uppercased().hasPrefix("FILE ") {
                // FILE "Tekken 3 (Track 1).bin" BINARY
                if let quoted = line.range(of: "\"([^\"]+)\"", options: .regularExpression) {
                    names.append(String(line[quoted]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                } else {
                    // Unquoted: everything between "FILE " and the trailing type.
                    let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    let parts = body.split(separator: " ")
                    if parts.count > 1 { names.append(parts.dropLast().joined(separator: " ")) }
                }
            } else if sheet.pathExtension.lowercased() == "m3u" {
                names.append(line)
            } else if sheet.pathExtension.lowercased() == "gdi",
                      let quoted = line.range(of: "\"([^\"]+)\"", options: .regularExpression) {
                names.append(String(line[quoted]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }

        var seen = Set<String>()
        return names.compactMap { name in
            let file = directory.appendingPathComponent(name)
            guard seen.insert(file.path).inserted,
                  FileManager.default.fileExists(atPath: file.path) else { return nil }
            return file
        }
    }

    /// Recursive size of a directory, for games that are a whole folder.
    private static func treeSize(of directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    private static func makeItem(url: URL, system: GameSystem, root: URL,
                                 size: Int64? = nil) -> GameItem {
        let parsed = NameParser.parse(url)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])

        // Windows launchers are called "Launcher.exe" or "obsidian.exe"; the
        // folder they sit in is what the game is actually called.
        var title = parsed.title
        if system.id == "windows" {
            let folder = url.deletingLastPathComponent().lastPathComponent
            let folderTitle = NameParser.parse(name: folder).title
            let generic = ["launcher", "start", "play", "game"].contains(title.lowercased())
            let abbreviates = NameParser.normalize(folderTitle)
                .contains(NameParser.normalize(title))
            if generic || abbreviates { title = folderTitle }
        }

        return GameItem(
            id: GameItem.identifier(for: url),
            // A shell script or an app in a ROM folder is launched directly.
            kind: system.id == "mac" ? .game : .rom,
            title: title,
            sortTitle: NameParser.normalize(title),
            systemID: system.id,
            url: url,
            discs: [],
            region: parsed.region,
            languages: parsed.languages,
            revision: parsed.revision,
            tags: parsed.tags,
            fileSize: size ?? gameSize(of: url, declared: Int64(values?.fileSize ?? 0)),
            dateAdded: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
            sourceRoot: root,
            rawName: parsed.raw)
    }

    // MARK: - Multi-disc

    /// "Final Fantasy VII (France) (Disc 1..3)" is one game with three discs.
    private static func groupMultiDisc(_ items: [GameItem]) -> [GameItem] {
        var groups: [String: [GameItem]] = [:]
        var order: [String] = []
        var singles: [GameItem] = []

        for item in items {
            let parsed = NameParser.parse(item.url)
            guard item.kind == .rom, parsed.disc != nil else {
                singles.append(item)
                continue
            }
            let key = [item.url.deletingLastPathComponent().path,
                       item.systemID,
                       NameParser.normalizedCore(item.title)].joined(separator: "|")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }

        var grouped: [GameItem] = []
        for key in order {
            guard var members = groups[key], !members.isEmpty else { continue }
            members.sort { (NameParser.parse($0.url).disc ?? 0) < (NameParser.parse($1.url).disc ?? 0) }
            guard members.count > 1 else {
                grouped.append(members[0])
                continue
            }
            var first = members[0]
            first.discs = members.map(\.url)
            first.fileSize = members.reduce(0) { $0 + $1.fileSize }
            grouped.append(first)
        }
        return singles + grouped
    }
}
