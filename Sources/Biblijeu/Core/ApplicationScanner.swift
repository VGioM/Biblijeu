import AppKit
import Foundation

/// Finds the games and emulators already installed as .app bundles.
///
/// Three signals, in order of trust: the emulator catalogue (bundle id), the
/// `LSApplicationCategoryType` the app declares, and a short list of launchers
/// that ship without a category.
enum ApplicationScanner {

    /// Launchers and native games that declare no category of their own.
    private static let knownGameBundleIDs: Set<String> = [
        "com.valvesoftware.steam", "com.roblox.robloxplayer", "com.roblox.robloxstudio",
        "net.blizzard.worldofwarcraft", "net.battle.app", "com.blizzard.battle.net",
        "com.epicgames.launcher", "com.gog.galaxy", "com.hytale.launcher",
        "com.mojang.minecraftlauncher", "net.minecraft.launcher",
        "com.riotgames.leagueoflegends", "com.riotgames.legendsofruneterra",
        "com.itch.itch", "io.github.hyperplay", "com.heroicgameslauncher.hgl",
        "com.playstation.remoteplay", "com.nvidia.gfnpc",
        "com.paradoxinteractive.heartsofiron4"
    ]

    private static let gameNameHints = [
        "doom", "quake", "minecraft", "steam", "roblox", "launcher", "battle.net",
        "epic games", "gog galaxy", "heroic", "hytale"
    ]

    /// Words that mark an app as an emulator rather than a game, for the ones
    /// the catalogue does not know. Matched whole against the words of the name
    /// and the bundle id, so "ares" does not catch "Wares".
    private static let emulatorWords: Set<String> = [
        "emu", "emulator", "emulateur", "émulateur", "emulation", "qemu",
        "retroarch", "openemu", "provenance", "playcover", "utm", "dosbox",
        "boxer", "vice", "hatari", "fuse", "stella", "nestopia", "sameboy",
        "bsnes", "higan", "ares", "mame", "mess", "epsxe", "pcsx", "pcsx2",
        "duckstation", "rpcs3", "ppsspp", "vita3k", "dolphin", "cemu",
        "ryujinx", "yuzu", "sudachi", "citron", "citra", "azahar", "lime3ds",
        "melonds", "desmume", "mgba", "vbam", "snes9x", "zsnes", "mesen",
        "mupen64plus", "simple64", "flycast", "redream", "xemu", "xenia",
        "cxbx", "kega", "fusion", "gearboy", "punes", "gopher64", "rosalie"
    ]

    /// Apps that look game-ish by name but are not games.
    private static let denyBundleIDs: Set<String> = [
        "com.nchsoftware.switchfrpaid", "com.apple.gamecenter",
        "com.apple.dt.Xcode", "com.microsoft.VSCode",
        "org.python.PythonLauncher"
    ]

    static func scan(folders: [URL], progress: @escaping (String) -> Void) -> [GameItem] {
        var seen = Set<String>()
        var items: [GameItem] = []
        for folder in folders {
            progress("Analyse de \(folder.lastPathComponent)…")
            // One level of nesting covers /Applications/Utilities-style folders.
            for url in appBundles(in: [folder]) {
                if let item = item(for: url), seen.insert(item.id).inserted { items.append(item) }
            }
        }
        return items
    }

    /// Builds an item for one bundle, or nil if it is not a game or emulator.
    static func item(for url: URL, forcedKind: GameKind? = nil) -> GameItem? {
        let info = bundleInfo(at: url)
        let bundleID = info["CFBundleIdentifier"] as? String
        // CrossOver's own launchers are handled by `CrossOver`, which knows
        // which bottle and which start-menu entry each one stands for.
        if info["CXHelperAppBottleName"] != nil { return nil }
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        // The catalogue is the first word on what an app is: an emulator stays
        // an emulator even when it declares itself a game -- most of them do --
        // and even when it was found inside a ROM folder. Failing that, the
        // file types it opens speak for it. The name is the last resort, and
        // only arbitrates among apps that already claim to be games.
        let denied = bundleID.map { id in
            denyBundleIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
        } ?? false
        let declaresGame = !denied && isGame(name: name, bundleID: bundleID, info: info)
        let isEmulator = !denied && emulatorSpec(bundleID: bundleID, url: url) != nil
        let inferred = !denied && inferredEmulatorSpec(at: url, info: info) != nil
        let namedLikeOne = declaresGame && looksLikeEmulator(name: name, bundleID: bundleID)

        let kind: GameKind
        if isEmulator || inferred || namedLikeOne {
            kind = .emulator
        } else if let forcedKind {
            kind = forcedKind
        } else if denied {
            return nil
        } else if declaresGame {
            kind = .game
        } else {
            return nil
        }

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let cleanName = name.replacingOccurrences(of: "-v?[0-9]+(\\.[0-9]+)+$", with: "",
                                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        return GameItem(
            id: GameItem.identifier(for: url),
            kind: kind,
            title: cleanName.isEmpty ? name : cleanName,
            sortTitle: NameParser.normalize(cleanName.isEmpty ? name : cleanName),
            systemID: "mac",
            url: url,
            region: nil,
            fileSize: 0,
            dateAdded: values?.creationDate ?? .distantPast,
            bundleID: bundleID,
            appVersion: info["CFBundleShortVersionString"] as? String,
            sourceRoot: url.deletingLastPathComponent(),
            rawName: url.deletingPathExtension().lastPathComponent)
    }

    /// The emulator this bundle is, if Biblijeu knows it.
    static func emulatorSpec(bundleID: String?, url: URL) -> EmulatorSpec? {
        if let bundleID, let spec = EmulatorCatalog.spec(forBundleID: bundleID) { return spec }
        let executable = bundleInfo(at: url)["CFBundleExecutable"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return EmulatorCatalog.spec(forExecutable: executable)
    }

    /// Extensions that essentially only an emulator claims. The looser ones a
    /// console shares with the rest of the world are deliberately absent:
    /// `.iso` belongs to every disc tool, `.md` to every Markdown editor, and
    /// `.vb` to every code editor -- VS Code declares the last two and is not a
    /// Mega Drive emulator.
    private static let telltaleExtensions: Set<String> = [
        "nes", "fds", "unif", "sfc", "smc", "swc", "n64", "z64", "v64", "ndd",
        "gbc", "gba", "nds", "dsi", "3ds", "cia", "cci", "cxi",
        "xci", "nsp", "nsz", "xcz", "nca", "nro", "nso",
        "rvz", "gcm", "gcz", "wbfs", "wia", "wud", "wux", "rpx",
        "gdi", "cdi", "pbp", "cso", "chd", "vpk", "ngp", "ngc",
        "pce", "sgx", "a26", "a78", "lnx", "jag", "j64",
        "adf", "adz", "d64", "t64", "dosz", "pk3", "ipk3", "smd", "32x"
    ]

    /// An emulator the catalogue has never heard of, described by its own
    /// Info.plist: an app that declares it opens `.xci` and `.nsp` runs Switch
    /// games, whatever it is called. It gets a spec that opens the ROM as a
    /// document -- the one way of starting a game that needs no prior knowledge
    /// of the emulator's command line.
    static func inferredEmulatorSpec(at url: URL, info: [String: Any]) -> EmulatorSpec? {
        let extensions = declaredExtensions(in: info).intersection(telltaleExtensions)
        guard !extensions.isEmpty else { return nil }

        // "windows" and "mac" are shelves, not consoles: an app that opens .exe
        // is not thereby an emulator.
        let consoles = SystemCatalog.all
            .filter { !$0.fileExtensions.isDisjoint(with: extensions) }
            .map(\.id)
            .filter { $0 != "windows" && $0 != "mac" }
        guard !consoles.isEmpty else { return nil }

        let bundleID = info["CFBundleIdentifier"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return EmulatorSpec(id: "auto:" + bundleID, name: name,
                            bundleIDs: [bundleID], executableNames: [],
                            systems: consoles,
                            launch: .document, directLaunch: nil, homepage: nil)
    }

    /// The file extensions an app claims in `CFBundleDocumentTypes`.
    private static func declaredExtensions(in info: [String: Any]) -> Set<String> {
        guard let types = info["CFBundleDocumentTypes"] as? [[String: Any]] else { return [] }
        var result = Set<String>()
        for type in types {
            guard let extensions = type["CFBundleTypeExtensions"] as? [String] else { continue }
            for ext in extensions { result.insert(ext.lowercased()) }
        }
        return result
    }

    /// Every emulator Biblijeu can actually launch on this machine.
    ///
    /// Looks one level down as well as at the top: emulators kept on an
    /// external drive usually live in a folder of their own.
    static func installedEmulators(in folders: [URL]) -> [InstalledEmulator] {
        var found: [String: InstalledEmulator] = [:]
        for url in appBundles(in: folders) {
            guard let emulator = emulator(at: url) else { continue }
            // Several builds side by side: keep the first one found.
            if found[emulator.id] == nil { found[emulator.id] = emulator }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The emulator this bundle is -- from the catalogue, or from what the app
    /// says it can open.
    static func emulator(at url: URL) -> InstalledEmulator? {
        let info = bundleInfo(at: url)
        let spec = emulatorSpec(bundleID: info["CFBundleIdentifier"] as? String, url: url)
            ?? inferredEmulatorSpec(at: url, info: info)
        guard let spec else { return nil }
        return InstalledEmulator(spec: spec, url: url,
                                 version: info["CFBundleShortVersionString"] as? String)
    }

    /// Every `.app` in `folders`, plus those one folder deeper.
    private static func appBundles(in folders: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for folder in folders {
            guard let contents = try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for url in contents {
                if url.pathExtension.lowercased() == "app" {
                    result.append(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          let nested = try? fm.contentsOfDirectory(
                            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    result.append(contentsOf: nested.filter { $0.pathExtension.lowercased() == "app" })
                }
            }
        }
        return result
    }

    /// An emulator the catalogue has never heard of: recognised by its name, and
    /// only ever consulted for apps that would otherwise land among the games.
    private static func looksLikeEmulator(name: String, bundleID: String?) -> Bool {
        let text = name + " " + (bundleID ?? "")
        let lower = text.lowercased()
        if lower.contains("emulator") || lower.contains("emulateur") || lower.contains("émulateur") {
            return true
        }
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains { emulatorWords.contains(String($0)) }
    }

    private static func isGame(name: String, bundleID: String?, info: [String: Any]) -> Bool {
        if let bundleID, knownGameBundleIDs.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return true
        }
        if let category = info["LSApplicationCategoryType"] as? String,
           category.hasPrefix("public.app-category.") ,
           category.contains("games") {
            return true
        }
        let lower = name.lowercased()
        return gameNameHints.contains { lower.contains($0) }
    }

    // Scanning runs off the main thread, so the plist cache needs its own lock.
    private static var infoCache: [String: [String: Any]] = [:]
    private static let cacheLock = NSLock()

    static func bundleInfo(at url: URL) -> [String: Any] {
        cacheLock.lock()
        let cached = infoCache[url.path]
        cacheLock.unlock()
        if let cached { return cached }

        let plist = url.appendingPathComponent("Contents/Info.plist")
        let info = (NSDictionary(contentsOf: plist) as? [String: Any]) ?? [:]
        cacheLock.lock()
        infoCache[url.path] = info
        cacheLock.unlock()
        return info
    }

    static func clearCache() {
        cacheLock.lock()
        infoCache.removeAll()
        cacheLock.unlock()
    }
}
