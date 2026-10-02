import Foundation

/// What an emulator keeps in a folder.
enum SaveKind: String, Codable, CaseIterable, Sendable {
    /// The game's own save file: a battery save, a memory stick, a save folder.
    case saves
    /// Save states -- a snapshot of the machine, rewritten constantly.
    case states
    /// Memory cards, as a console had them.
    case memoryCards
    /// The console's own memory: a NAND, an EEPROM, the system's save area.
    case systemMemory
    /// A virtual SD card.
    case sdCard

    var label: String {
        switch self {
        case .saves:        return "Sauvegardes"
        case .states:       return "Sauvegardes d'état"
        case .memoryCards:  return "Cartes mémoire"
        case .systemMemory: return "Mémoire système"
        case .sdCard:       return "Carte SD"
        }
    }

    /// What this kind actually holds.
    ///
    /// The choice of what to copy is only an informed one if it says which of
    /// these is a save and which is a copy of a game.
    var explanation: String {
        switch self {
        case .saves:
            return "Le fichier de sauvegarde du jeu : votre partie."
        case .states:
            return "Un instantané de la machine, repris à l'image près. Volumineux et réécrit sans cesse, mais c'est la partie en cours."
        case .memoryCards:
            return "Les cartes mémoire GameCube, PlayStation et PS2 : toutes vos parties de ces consoles y sont."
        case .systemMemory:
            return "La mémoire propre de la console — NAND, EEPROM, NVRAM. Les sauvegardes Wii et 3DS y vivent, ainsi que les scores des bornes d'arcade."
        case .sdCard:
            return "La carte SD virtuelle d'un émulateur Switch ou 3DS : c'est là que vont les jeux, mods et DLC installés. Des copies de jeux plutôt que des sauvegardes — décoché par défaut."
        }
    }

    var symbol: String {
        switch self {
        case .saves:        return "externaldrive.fill.badge.checkmark"
        case .states:       return "camera.viewfinder"
        case .memoryCards:  return "memorychip"
        case .systemMemory: return "cpu"
        case .sdCard:       return "sdcard"
        }
    }
}

/// A setting inside an emulator's own configuration that names a folder.
struct FolderSetting: Sendable {
    enum Format: Sendable { case ini, bml }

    /// The configuration file, relative to the home folder.
    let file: String
    let format: Format
    let section: String
    let key: String
    /// A relative value in that file hangs off this folder, itself relative to
    /// the home folder -- usually the emulator's own data directory.
    let relativeTo: String
}

/// One place an emulator might keep saves.
///
/// Every path here is a *candidate*: it is shown only once found on disk, so a
/// path that is wrong for a given build costs nothing and never invents a
/// folder. What the emulator writes down about the folder wins over all of them.
struct SaveFolderSpec: Sendable {
    let kind: SaveKind
    /// Paths relative to the home folder, most likely first.
    ///
    /// Two segments stand for "any one folder": `*` matches and gives the
    /// folder its name in the backup -- the bottle a Windows game lives in --
    /// while `?` matches without naming, for the segment that is merely in the
    /// way, such as the user a bottle happens to have been made under.
    let candidates: [String]
    /// Tells two folders of the same kind apart in the backup. Defaults to the
    /// kind's own name.
    var slug: String?
    /// What to call this folder on screen, when its kind alone would be
    /// wrong or ambiguous: an emulator with two folders of the same kind needs
    /// each one named, or the tab lists the same word twice.
    var label: String?
    /// What this folder holds that is not a save and must not be copied: xemu
    /// keeps an eight-gigabyte disc image beside a 512-byte EEPROM.
    var excluding: [String]
    /// The only extensions worth copying, when the folder holds other things
    /// entirely -- a ROM folder, where the saves sit among the games.
    var onlyExtensions: Set<String>
    /// Where the emulator itself says this folder is.
    var setting: FolderSetting?
    /// Folder names a wildcard must never match: Windows keeps "Public" and
    /// "Default" beside the real users, and they hold nobody's saves.
    var ignoring: Set<String>

    init(_ kind: SaveKind, _ candidates: [String], slug: String? = nil,
         label: String? = nil, excluding: [String] = [], onlyExtensions: Set<String> = [],
         ignoring: Set<String> = [], setting: FolderSetting? = nil) {
        self.kind = kind
        self.candidates = candidates
        self.slug = slug
        self.label = label
        self.excluding = excluding
        self.onlyExtensions = onlyExtensions
        self.ignoring = ignoring
        self.setting = setting
    }
}

/// A save folder that exists on this Mac, right now.
struct SaveFolder: Identifiable, Hashable, Sendable {
    let emulatorID: String
    let kind: SaveKind
    /// Stable name of this folder inside the backup.
    let slug: String
    /// What to call it on screen, when the kind alone will not do.
    let label: String?
    let url: URL
    /// What tells this folder apart from its siblings of the same kind -- the
    /// name of the Windows bottle it belongs to. Empty when there is only one.
    let variant: String
    /// What of this folder is a save, and what must be left where it is.
    let filter: BackupEngine.Filter

    var id: String { "\(emulatorID)/\(slug)/\(variant)" }

    /// Where this folder lives under the backup root. Built from the emulator
    /// and the kind rather than from the path, so a backup keeps working when
    /// the emulator moves its folder -- or when the Mac changes.
    var backupSubpath: String {
        variant.isEmpty ? "\(emulatorID)/\(slug)" : "\(emulatorID)/\(slug)/\(variant)"
    }

    var title: String {
        let name = label ?? kind.label
        return variant.isEmpty ? name : "\(name) — \(variant)"
    }
}

/// Where each emulator keeps what the player would hate to lose.
///
/// An emulator absent from this catalogue is one whose saves live inside the
/// game's own folder (DOSBox, Boxer) or that has nothing worth copying yet:
/// naming a folder that is not the right one would back up the wrong thing,
/// which is worse than backing up nothing.
enum SaveCatalog {

    static let specs: [String: [SaveFolderSpec]] = [

        "dolphin": [
            SaveFolderSpec(.memoryCards, ["Library/Application Support/Dolphin/GC"]),
            SaveFolderSpec(.systemMemory, ["Library/Application Support/Dolphin/Wii"]),
            SaveFolderSpec(.states, ["Library/Application Support/Dolphin/StateSaves"]),
            SaveFolderSpec(.saves, ["Library/Application Support/Dolphin/GBA"], slug: "gba",
                           label: "Sauvegardes Game Boy Advance")
        ],

        "cemu": [
            SaveFolderSpec(.saves, ["Library/Application Support/Cemu/mlc01/usr/save"])
        ],

        "ryujinx": [
            SaveFolderSpec(.saves, ["Library/Application Support/Ryujinx/bis/user/save"]),
            // The save folders are named by index; this is what says which game
            // each one belongs to. Useless on its own, and useless without it
            // -- which makes it part of the saves, not of the console's memory.
            SaveFolderSpec(.saves, ["Library/Application Support/Ryujinx/bis/user/saveMeta"],
                           slug: "saveMeta", label: "Index des sauvegardes"),
            SaveFolderSpec(.sdCard, ["Library/Application Support/Ryujinx/sdcard"])
        ],

        "astris": [
            SaveFolderSpec(.saves, ["Library/Application Support/Astris/nand/user/save",
                                    "Library/Containers/V380-Ori.Astris/Data/Library/Application Support/Astris/nand/user/save"])
        ],

        "sudachi": [
            SaveFolderSpec(.saves, ["Library/Application Support/sudachi/nand/user/save"]),
            SaveFolderSpec(.sdCard, ["Library/Application Support/sudachi/sdmc"])
        ],

        "citron": [
            SaveFolderSpec(.saves, ["Library/Application Support/citron/nand/user/save"]),
            SaveFolderSpec(.sdCard, ["Library/Application Support/citron/sdmc"])
        ],

        "yuzu": [
            SaveFolderSpec(.saves, ["Library/Application Support/yuzu/nand/user/save"]),
            SaveFolderSpec(.sdCard, ["Library/Application Support/yuzu/sdmc"])
        ],

        "duckstation": [
            SaveFolderSpec(.memoryCards, ["Library/Application Support/DuckStation/memcards"],
                           setting: FolderSetting(file: "Library/Application Support/DuckStation/settings.ini",
                                                  format: .ini, section: "Folders", key: "MemoryCards",
                                                  relativeTo: "Library/Application Support/DuckStation")),
            SaveFolderSpec(.states, ["Library/Application Support/DuckStation/savestates"],
                           setting: FolderSetting(file: "Library/Application Support/DuckStation/settings.ini",
                                                  format: .ini, section: "Folders", key: "SaveStates",
                                                  relativeTo: "Library/Application Support/DuckStation"))
        ],

        "pcsx2": [
            SaveFolderSpec(.memoryCards, ["Library/Application Support/PCSX2/memcards"],
                           setting: FolderSetting(file: "Library/Application Support/PCSX2/inis/PCSX2.ini",
                                                  format: .ini, section: "Folders", key: "MemoryCards",
                                                  relativeTo: "Library/Application Support/PCSX2")),
            SaveFolderSpec(.states, ["Library/Application Support/PCSX2/sstates"],
                           setting: FolderSetting(file: "Library/Application Support/PCSX2/inis/PCSX2.ini",
                                                  format: .ini, section: "Folders", key: "Savestates",
                                                  relativeTo: "Library/Application Support/PCSX2"))
        ],

        "rpcs3": [
            SaveFolderSpec(.saves, ["Library/Application Support/rpcs3/dev_hdd0/home",
                                    ".config/rpcs3/dev_hdd0/home"])
        ],

        "ppsspp": [
            SaveFolderSpec(.saves, [".config/ppsspp/PSP/SAVEDATA",
                                    "Library/Application Support/PPSSPP/PSP/SAVEDATA"]),
            SaveFolderSpec(.states, [".config/ppsspp/PSP/PPSSPP_STATE",
                                     "Library/Application Support/PPSSPP/PSP/PPSSPP_STATE"])
        ],

        "vita3k": [
            SaveFolderSpec(.saves, ["Library/Application Support/Vita3K/Vita3K/ux0/user",
                                    ".Vita3K/ux0/user"])
        ],

        "melonds": [
            SaveFolderSpec(.saves, ["Library/Application Support/melonDS/savefiles"]),
            SaveFolderSpec(.states, ["Library/Application Support/melonDS/savestates"])
        ],

        "azahar": [
            SaveFolderSpec(.sdCard, ["Library/Application Support/Azahar/sdmc"], slug: "sdmc",
                           label: "Carte SD virtuelle"),
            SaveFolderSpec(.systemMemory, ["Library/Application Support/Azahar/nand"]),
            SaveFolderSpec(.states, ["Library/Application Support/Azahar/states"])
        ],

        "lime3ds": [
            SaveFolderSpec(.sdCard, ["Library/Application Support/Lime3DS/sdmc"], slug: "sdmc",
                           label: "Carte SD virtuelle"),
            SaveFolderSpec(.systemMemory, ["Library/Application Support/Lime3DS/nand"]),
            SaveFolderSpec(.states, ["Library/Application Support/Lime3DS/states"])
        ],

        "citra": [
            SaveFolderSpec(.sdCard, ["Library/Application Support/Citra/sdmc"], slug: "sdmc",
                           label: "Carte SD virtuelle"),
            SaveFolderSpec(.systemMemory, ["Library/Application Support/Citra/nand"]),
            SaveFolderSpec(.states, ["Library/Application Support/Citra/states"])
        ],

        "snes9x": [
            SaveFolderSpec(.saves, ["Library/Application Support/Snes9x/SRAMs"]),
            SaveFolderSpec(.states, ["Library/Application Support/Snes9x/Freezes"])
        ],

        // VBA-M writes beside the ROM unless its ini names a folder, which is
        // the only way to know: an empty key there means "next to the game".
        "vbam": [
            SaveFolderSpec(.saves, ["Library/Application Support/visualboyadvance-m/saves"],
                           setting: FolderSetting(file: "Library/Application Support/visualboyadvance-m/vbam.ini",
                                                  format: .ini, section: "General", key: "BatteryDir",
                                                  relativeTo: "Library/Application Support/visualboyadvance-m")),
            SaveFolderSpec(.states, ["Library/Application Support/visualboyadvance-m/savestates"],
                           setting: FolderSetting(file: "Library/Application Support/visualboyadvance-m/vbam.ini",
                                                  format: .ini, section: "General", key: "StateDir",
                                                  relativeTo: "Library/Application Support/visualboyadvance-m"))
        ],

        "mgba": [
            SaveFolderSpec(.saves, ["Library/Application Support/mGBA/saves"]),
            SaveFolderSpec(.states, ["Library/Application Support/mGBA/states"])
        ],

        "mesen": [
            SaveFolderSpec(.saves, ["Library/Application Support/Mesen2/Saves",
                                    "Library/Application Support/Mesen/Saves"]),
            SaveFolderSpec(.states, ["Library/Application Support/Mesen2/SaveStates",
                                     "Library/Application Support/Mesen/SaveStates"])
        ],

        // ares writes its saves beside the ROM unless told otherwise, and says
        // so in its settings; with nothing set there is no folder to back up.
        "ares": [
            SaveFolderSpec(.saves, ["Library/Application Support/ares/Saves"],
                           setting: FolderSetting(file: "Library/Application Support/ares/settings.bml",
                                                  format: .bml, section: "Paths", key: "Saves",
                                                  relativeTo: "Library/Application Support/ares"))
        ],

        "simple64": [
            SaveFolderSpec(.saves, ["Library/Application Support/simple64/saves",
                                    ".local/share/mupen64plus/save"])
        ],

        "flycast": [
            SaveFolderSpec(.saves, ["Library/Application Support/Flycast/data",
                                    ".flycast/data"])
        ],

        "redream": [
            SaveFolderSpec(.saves, ["Library/Application Support/redream/saves",
                                    ".redream/saves"])
        ],

        // The EEPROM and the hard disc live in the same folder, and the disc is
        // an eight-gigabyte image: it is the console's drive, not a save.
        "xemu": [
            SaveFolderSpec(.systemMemory, ["Library/Application Support/xemu/xemu"],
                           label: "Mémoire système (EEPROM)",
                           excluding: ["xbox_hdd.qcow2", "xbox_hdd.img"])
        ],

        "xenia": [
            SaveFolderSpec(.saves, ["Library/Application Support/xenia/content",
                                    ".xenia/content"])
        ],

        "mame": [
            SaveFolderSpec(.systemMemory, ["Library/Application Support/mame/nvram"], slug: "nvram",
                           label: "Mémoire des bornes (NVRAM)"),
            SaveFolderSpec(.states, ["Library/Application Support/mame/sta"])
        ],

        "openemu": [
            SaveFolderSpec(.saves, ["Library/Application Support/OpenEmu/Battery Saves"]),
            SaveFolderSpec(.states, ["Library/Application Support/OpenEmu/Save States"])
        ],

        "retroarch": [
            SaveFolderSpec(.saves, ["Documents/RetroArch/saves",
                                    "Library/Application Support/RetroArch/saves"]),
            SaveFolderSpec(.states, ["Documents/RetroArch/states",
                                     "Library/Application Support/RetroArch/states"])
        ],

        "uzdoom": [
            SaveFolderSpec(.saves, ["Documents/UZDoom/Savegames",
                                    "Library/Application Support/uzdoom/savegames"])
        ],

        "gzdoom": [
            SaveFolderSpec(.saves, ["Documents/GZDoom/Savegames",
                                    "Library/Application Support/gzdoom/savegames"])
        ],

        // A Windows game saves where Windows games save: in the bottle's own
        // user folder. One entry per bottle, named after it.
        //
        // "My Documents" is deliberately absent, and must stay absent: a
        // bottle links it straight to the Mac's own Documents folder, so a
        // game that saves there has already saved outside the bottle -- and
        // backing it up would copy the user's whole Documents folder, ROM
        // library included.
        "crossover": [
            SaveFolderSpec(.saves, ["Library/Application Support/CrossOver/Bottles/*/drive_c/users/?/Saved Games"],
                           slug: "saved-games", label: "Jeux sauvegardés (Saved Games)",
                           ignoring: windowsPseudoUsers),
            SaveFolderSpec(.saves, ["Library/Application Support/CrossOver/Bottles/*/drive_c/users/?/AppData/Roaming"],
                           slug: "appdata", label: "Données d'application (AppData)",
                           ignoring: windowsPseudoUsers)
        ],

        "whisky": [
            SaveFolderSpec(.saves, ["Library/Containers/com.isaacmarovitz.Whisky/Bottles/*/drive_c/users/?/Saved Games"],
                           slug: "saved-games", label: "Jeux sauvegardés (Saved Games)",
                           ignoring: windowsPseudoUsers),
            SaveFolderSpec(.saves, ["Library/Containers/com.isaacmarovitz.Whisky/Bottles/*/drive_c/users/?/AppData/Roaming"],
                           slug: "appdata", label: "Données d'application (AppData)",
                           ignoring: windowsPseudoUsers)
        ]
    ]

    // MARK: - Saves written beside the game

    /// The identifier the ROM folders are grouped under. Not an emulator, but
    /// it behaves like one everywhere else: it can be left out of the backup,
    /// backed up on its own, and restored.
    static let romsID = "roms"

    /// Extensions an emulator uses for a save file it writes next to the game.
    ///
    /// ares, melonDS, mGBA and VBA-M all do this by default, and none of them
    /// has a folder of its own to look in: the save for a game sits in the same
    /// folder as the game. Which makes these files the easiest of all to lose
    /// -- and impossible to back up by copying the folder, since the folder is
    /// the ROM library.
    static let adjacentSaves: Set<String> = [
        "srm",          // Snes9x, mGBA, VBA-M, ares, RetroArch : SRAM
        "sav",          // mGBA, melonDS, VBA-M, ares : battery save
        "dsv",          // melonDS, DeSmuME : DS save
        "rtc",          // mGBA, VBA-M : the cartridge's clock
        "eep", "fla",   // Nintendo 64 : EEPROM, flash
        "mpk", "sra",   // Nintendo 64 : controller pak, SRAM
        "gme", "mcr", "mcd"  // PlayStation memory cards
    ]

    /// The same, for the snapshots -- told apart so that "include save states"
    /// means the same thing here as it does for an emulator's own folder.
    static let adjacentStates: Set<String> = {
        var all: Set<String> = ["mln", "sgm", "state"]  // melonDS, VBA-M, RetroArch
        for slot in 0...9 {
            all.insert("ss\(slot)")     // mGBA
            all.insert("st\(slot)")     // melonDS, VBA-M
        }
        for slot in 1...9 { all.insert("state\(slot)") }
        return all
    }()

    /// The saves sitting in the user's own ROM folders.
    ///
    /// Two entries per folder rather than one: the battery saves and the
    /// snapshots are copied and counted separately, so leaving the states out
    /// leaves them out here too.
    static func folders(besideRomsIn roots: [String]) -> [SaveFolder] {
        let names = slugs(for: roots)
        var found: [SaveFolder] = []
        for root in roots {
            let url = URL(fileURLWithPath: root).standardizedFileURL
            guard isDirectory(url), let name = names[root] else { continue }
            found.append(SaveFolder(emulatorID: romsID, kind: .saves,
                                    slug: "\(name)/saves",
                                    label: "Sauvegardes — \(url.lastPathComponent)",
                                    url: url, variant: "",
                                    filter: BackupEngine.Filter(onlyExtensions: adjacentSaves)))
            found.append(SaveFolder(emulatorID: romsID, kind: .states,
                                    slug: "\(name)/states",
                                    label: "Sauvegardes d'état — \(url.lastPathComponent)",
                                    url: url, variant: "",
                                    filter: BackupEngine.Filter(onlyExtensions: adjacentStates)))
        }
        return found
    }

    /// A name for each ROM folder inside the backup.
    ///
    /// The folder's own name, which is what anybody would look for -- unless
    /// two of them share it, in which case both get a few characters of their
    /// full path so neither can land on top of the other.
    private static func slugs(for roots: [String]) -> [String: String] {
        let names = roots.map { (URL(fileURLWithPath: $0).lastPathComponent, $0) }
        var counts: [String: Int] = [:]
        for (name, _) in names { counts[name, default: 0] += 1 }
        var result: [String: String] = [:]
        for (name, root) in names {
            let safe = name.isEmpty ? "dossier" : name.replacingOccurrences(of: "/", with: "-")
            result[root] = counts[name] == 1 ? safe : "\(safe)-\(fingerprint(root))"
        }
        return result
    }

    /// Four hex characters of a path, stable from one launch to the next.
    private static func fingerprint(_ path: String) -> String {
        var hash = 5381
        for byte in path.utf8 { hash = (hash &* 33 &+ Int(byte)) & 0xFFFFFFF }
        return String(format: "%04x", hash & 0xFFFF)
    }

    /// The users Windows invents. A bottle's saves are never in these.
    private static let windowsPseudoUsers: Set<String> = ["Public", "Default", "Default User", "All Users"]

    /// Every emulator this catalogue knows a save folder for.
    static var knownEmulatorIDs: [String] { Array(specs.keys) }

    // MARK: - Resolution

    /// The save folders this emulator actually has on this Mac.
    static func folders(forEmulator id: String) -> [SaveFolder] {
        guard let specs = specs[id] else { return [] }
        var found: [SaveFolder] = []
        for spec in specs {
            found.append(contentsOf: folders(for: spec, emulatorID: id))
        }
        return found
    }

    private static func folders(for spec: SaveFolderSpec, emulatorID: String) -> [SaveFolder] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let slug = spec.slug ?? spec.kind.rawValue

        func folder(_ url: URL, variant: String = "") -> SaveFolder {
            SaveFolder(emulatorID: emulatorID, kind: spec.kind, slug: slug,
                       label: spec.label, url: url.standardizedFileURL, variant: variant,
                       filter: BackupEngine.Filter(excluding: Set(spec.excluding),
                                                   onlyExtensions: spec.onlyExtensions))
        }

        // What the emulator says about the folder settles it, and it is the one
        // answer that follows a folder moved onto another drive.
        if let setting = spec.setting,
           let value = read(setting, home: home) {
            let url = value.hasPrefix("/")
                ? URL(fileURLWithPath: value)
                : home.appendingPathComponent(setting.relativeTo).appendingPathComponent(value)
            if isDirectory(url) { return [folder(url)] }
        }

        for candidate in spec.candidates {
            let matches = expand(candidate, under: home, ignoring: spec.ignoring)
            guard !matches.isEmpty else { continue }
            // A path with no `*` can only ever match once, and needs no name.
            if !candidate.contains("*") {
                return matches.map { folder($0.url) }
            }
            return matches.map { folder($0.url, variant: $0.variant) }
        }
        return []
    }

    private static func read(_ setting: FolderSetting, home: URL) -> String? {
        let file = home.appendingPathComponent(setting.file)
        switch setting.format {
        case .ini: return ConfigFile.iniValue(setting.key, section: setting.section, in: file)
        case .bml: return ConfigFile.bmlValue(setting.key, section: setting.section, in: file)
        }
    }

    /// Walks a candidate path, expanding its wildcards into the folders that
    /// match, and keeps only what exists as a directory.
    private static func expand(_ candidate: String, under home: URL,
                               ignoring: Set<String>) -> [(url: URL, variant: String)] {
        var results: [(url: URL, variant: String)] = [(home, "")]
        for segment in candidate.split(separator: "/", omittingEmptySubsequences: true) {
            let names = segment == "*"
            guard names || segment == "?" else {
                results = results.map { ($0.url.appendingPathComponent(String(segment)), $0.variant) }
                continue
            }
            results = results.flatMap { parent -> [(url: URL, variant: String)] in
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: parent.url, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])) ?? []
                return children
                    .filter { isDirectory($0) && !ignoring.contains($0.lastPathComponent) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .map { child in
                        guard names else { return (child, parent.variant) }
                        // Several naming wildcards in one path stack into one
                        // readable name, which is what the backup folder ends
                        // up being called.
                        let name = child.lastPathComponent
                        return (child, parent.variant.isEmpty ? name : parent.variant + " " + name)
                    }
            }
        }
        return results.filter { isDirectory($0.url) }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
