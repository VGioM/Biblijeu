import Foundation

/// One console/platform Biblijeu knows about.
///
/// `libretroFolder` is the name used by thumbnails.libretro.com, which is where
/// the box art comes from for everything retro -- no API key needed.
struct GameSystem: Identifiable, Hashable {
    let id: String
    let name: String
    let shortName: String
    let manufacturer: String
    let symbol: String
    let year: Int
    let libretroFolder: String?
    /// Lowercase, no leading dot. Order matters only for display.
    let fileExtensions: Set<String>
    /// Lowercase folder names that pin a file to this system when the
    /// extension alone is ambiguous (`.iso` is six consoles at once).
    let folderAliases: [String]
    /// Emulator ids in preference order; the first one installed wins.
    let emulators: [String]

    var sortKey: String { "\(year)-\(name)" }
}

enum SystemCatalog {
    /// Every system, newest hardware last -- the sidebar groups by manufacturer
    /// and sorts by year, so the order here is only a tie-breaker.
    static let all: [GameSystem] = [
        GameSystem(id: "nes", name: "Nintendo Entertainment System", shortName: "NES",
                   manufacturer: "Nintendo", symbol: "gamecontroller", year: 1983,
                   libretroFolder: "Nintendo - Nintendo Entertainment System",
                   fileExtensions: ["nes", "fds", "unf", "unif"],
                   folderAliases: ["nes", "famicom", "nintendo entertainment system"],
                   emulators: ["ares", "mesen", "openemu", "retroarch"]),

        GameSystem(id: "snes", name: "Super Nintendo", shortName: "SNES",
                   manufacturer: "Nintendo", symbol: "gamecontroller", year: 1990,
                   libretroFolder: "Nintendo - Super Nintendo Entertainment System",
                   fileExtensions: ["sfc", "smc", "swc", "fig", "bs"],
                   folderAliases: ["snes", "super nintendo", "super famicom", "sfc"],
                   emulators: ["snes9x", "ares", "openemu", "retroarch"]),

        GameSystem(id: "n64", name: "Nintendo 64", shortName: "N64",
                   manufacturer: "Nintendo", symbol: "gamecontroller", year: 1996,
                   libretroFolder: "Nintendo - Nintendo 64",
                   fileExtensions: ["n64", "z64", "v64", "ndd"],
                   folderAliases: ["n64", "nintendo 64"],
                   emulators: ["ares", "simple64", "openemu", "retroarch"]),

        GameSystem(id: "gb", name: "Game Boy", shortName: "GB",
                   manufacturer: "Nintendo", symbol: "l.joystick.tilt.left", year: 1989,
                   libretroFolder: "Nintendo - Game Boy",
                   fileExtensions: ["gb"],
                   folderAliases: ["gb", "game boy", "gameboy"],
                   emulators: ["vbam", "ares", "mgba", "openemu", "retroarch"]),

        GameSystem(id: "gbc", name: "Game Boy Color", shortName: "GBC",
                   manufacturer: "Nintendo", symbol: "l.joystick.tilt.left", year: 1998,
                   libretroFolder: "Nintendo - Game Boy Color",
                   fileExtensions: ["gbc"],
                   folderAliases: ["gbc", "game boy color", "gameboy color"],
                   emulators: ["vbam", "ares", "mgba", "openemu", "retroarch"]),

        GameSystem(id: "gba", name: "Game Boy Advance", shortName: "GBA",
                   manufacturer: "Nintendo", symbol: "l.joystick.tilt.left", year: 2001,
                   libretroFolder: "Nintendo - Game Boy Advance",
                   fileExtensions: ["gba", "agb"],
                   folderAliases: ["gba", "game boy advance", "gameboy advance"],
                   emulators: ["vbam", "mgba", "ares", "openemu", "retroarch"]),

        GameSystem(id: "nds", name: "Nintendo DS", shortName: "DS",
                   manufacturer: "Nintendo", symbol: "rectangle.split.1x2", year: 2004,
                   libretroFolder: "Nintendo - Nintendo DS",
                   fileExtensions: ["nds", "dsi", "ids", "srl"],
                   folderAliases: ["nds", "ds", "nintendo ds"],
                   emulators: ["melonds", "openemu", "retroarch"]),

        GameSystem(id: "n3ds", name: "Nintendo 3DS", shortName: "3DS",
                   manufacturer: "Nintendo", symbol: "rectangle.split.1x2", year: 2011,
                   libretroFolder: "Nintendo - Nintendo 3DS",
                   fileExtensions: ["3ds", "cci", "cxi", "cia", "3dsx"],
                   folderAliases: ["3ds", "n3ds", "nintendo 3ds"],
                   emulators: ["azahar", "lime3ds", "citra"]),

        GameSystem(id: "gc", name: "GameCube", shortName: "GameCube",
                   manufacturer: "Nintendo", symbol: "cube", year: 2001,
                   libretroFolder: "Nintendo - GameCube",
                   fileExtensions: ["gcm", "gcz", "rvz", "ciso", "iso", "wia"],
                   folderAliases: ["gamecube", "game cube", "gc", "ngc"],
                   emulators: ["dolphin"]),

        GameSystem(id: "wii", name: "Wii", shortName: "Wii",
                   manufacturer: "Nintendo", symbol: "wave.3.right", year: 2006,
                   libretroFolder: "Nintendo - Wii",
                   // No ".wad": a Wii channel dump is rare, a Doom wad is not.
                   fileExtensions: ["wbfs", "rvz", "wia", "iso"],
                   folderAliases: ["wii"],
                   emulators: ["dolphin"]),

        GameSystem(id: "wiiu", name: "Wii U", shortName: "Wii U",
                   manufacturer: "Nintendo", symbol: "wave.3.right", year: 2012,
                   libretroFolder: "Nintendo - Wii U",
                   fileExtensions: ["wud", "wux", "wua", "rpx"],
                   folderAliases: ["wii u", "wiiu", "wii : wii u", "wii-wii u"],
                   emulators: ["cemu"]),

        GameSystem(id: "switch", name: "Nintendo Switch", shortName: "Switch",
                   manufacturer: "Nintendo", symbol: "switch.2", year: 2017,
                   libretroFolder: nil,
                   fileExtensions: ["xci", "nsp", "nsz", "xcz"],
                   folderAliases: ["switch", "nintendo switch", "nsw"],
                   emulators: ["ryujinx", "astris", "sudachi", "citron", "yuzu"]),

        GameSystem(id: "vb", name: "Virtual Boy", shortName: "Virtual Boy",
                   manufacturer: "Nintendo", symbol: "eye", year: 1995,
                   libretroFolder: "Nintendo - Virtual Boy",
                   fileExtensions: ["vb", "vboy"],
                   folderAliases: ["virtual boy", "vb"],
                   emulators: ["ares", "retroarch"]),

        GameSystem(id: "ps1", name: "PlayStation", shortName: "PS1",
                   manufacturer: "Sony", symbol: "playstation.logo", year: 1994,
                   libretroFolder: "Sony - PlayStation",
                   fileExtensions: ["cue", "chd", "pbp", "m3u", "ccd", "toc", "img", "ecm"],
                   folderAliases: ["ps1", "psx", "playstation", "playstation 1", "psone"],
                   emulators: ["duckstation", "openemu", "ares", "retroarch"]),

        GameSystem(id: "ps2", name: "PlayStation 2", shortName: "PS2",
                   manufacturer: "Sony", symbol: "playstation.logo", year: 2000,
                   libretroFolder: "Sony - PlayStation 2",
                   fileExtensions: ["iso", "chd", "cso", "gz", "bin", "mdf", "nrg"],
                   folderAliases: ["ps2", "playstation 2"],
                   emulators: ["pcsx2"]),

        GameSystem(id: "ps3", name: "PlayStation 3", shortName: "PS3",
                   manufacturer: "Sony", symbol: "playstation.logo", year: 2006,
                   libretroFolder: "Sony - PlayStation 3",
                   fileExtensions: ["pkg", "self", "elf"],
                   folderAliases: ["ps3", "playstation 3"],
                   emulators: ["rpcs3"]),

        GameSystem(id: "ps5", name: "PlayStation 5", shortName: "PS5",
                   manufacturer: "Sony", symbol: "playstation.logo", year: 2020,
                   libretroFolder: nil,
                   fileExtensions: ["pkg", "self", "elf"],
                   folderAliases: ["ps5", "playstation 5"],
                   emulators: ["kytyps5"]),

        GameSystem(id: "psp", name: "PlayStation Portable", shortName: "PSP",
                   manufacturer: "Sony", symbol: "rectangle.on.rectangle", year: 2004,
                   libretroFolder: "Sony - PlayStation Portable",
                   fileExtensions: ["cso", "pbp", "iso", "chd", "prx"],
                   folderAliases: ["psp", "playstation portable"],
                   emulators: ["ppsspp", "retroarch"]),

        GameSystem(id: "vita", name: "PlayStation Vita", shortName: "Vita",
                   manufacturer: "Sony", symbol: "rectangle.on.rectangle", year: 2011,
                   libretroFolder: "Sony - PlayStation Vita",
                   fileExtensions: ["vpk"],
                   folderAliases: ["vita", "ps vita", "psvita"],
                   emulators: ["vita3k"]),

        GameSystem(id: "genesis", name: "Mega Drive", shortName: "Mega Drive",
                   manufacturer: "Sega", symbol: "gamecontroller", year: 1988,
                   libretroFolder: "Sega - Mega Drive - Genesis",
                   fileExtensions: ["md", "gen", "smd", "bin"],
                   folderAliases: ["megadrive", "mega drive", "genesis", "md"],
                   emulators: ["ares", "openemu", "retroarch"]),

        GameSystem(id: "mastersystem", name: "Master System", shortName: "Master System",
                   manufacturer: "Sega", symbol: "gamecontroller", year: 1985,
                   libretroFolder: "Sega - Master System - Mark III",
                   fileExtensions: ["sms"],
                   folderAliases: ["master system", "sms", "mark iii"],
                   emulators: ["ares", "openemu", "retroarch"]),

        GameSystem(id: "gamegear", name: "Game Gear", shortName: "Game Gear",
                   manufacturer: "Sega", symbol: "l.joystick.tilt.left", year: 1990,
                   libretroFolder: "Sega - Game Gear",
                   fileExtensions: ["gg"],
                   folderAliases: ["game gear", "gamegear", "gg"],
                   emulators: ["ares", "openemu", "retroarch"]),

        GameSystem(id: "sega32x", name: "Sega 32X", shortName: "32X",
                   manufacturer: "Sega", symbol: "gamecontroller", year: 1994,
                   libretroFolder: "Sega - 32X",
                   fileExtensions: ["32x"],
                   folderAliases: ["32x", "sega 32x"],
                   emulators: ["ares", "openemu", "retroarch"]),

        GameSystem(id: "saturn", name: "Saturn", shortName: "Saturn",
                   manufacturer: "Sega", symbol: "gamecontroller", year: 1994,
                   libretroFolder: "Sega - Saturn",
                   fileExtensions: ["cue", "chd", "ccd", "mds"],
                   folderAliases: ["saturn", "sega saturn"],
                   emulators: ["ares", "retroarch", "openemu"]),

        GameSystem(id: "dreamcast", name: "Dreamcast", shortName: "Dreamcast",
                   manufacturer: "Sega", symbol: "gamecontroller", year: 1998,
                   libretroFolder: "Sega - Dreamcast",
                   fileExtensions: ["gdi", "cdi", "chd"],
                   folderAliases: ["dreamcast", "dc"],
                   emulators: ["flycast", "redream", "openemu", "retroarch"]),

        GameSystem(id: "pcengine", name: "PC Engine", shortName: "PC Engine",
                   manufacturer: "NEC", symbol: "gamecontroller", year: 1987,
                   libretroFolder: "NEC - PC Engine - TurboGrafx 16",
                   fileExtensions: ["pce", "sgx"],
                   folderAliases: ["pc engine", "pcengine", "turbografx"],
                   emulators: ["ares", "openemu", "retroarch"]),

        GameSystem(id: "neogeo", name: "Neo Geo", shortName: "Neo Geo",
                   manufacturer: "SNK", symbol: "gamecontroller", year: 1990,
                   libretroFolder: "SNK - Neo Geo",
                   fileExtensions: ["neo"],
                   folderAliases: ["neogeo", "neo geo"],
                   emulators: ["mame", "openemu", "retroarch"]),

        GameSystem(id: "ngp", name: "Neo Geo Pocket", shortName: "NGP",
                   manufacturer: "SNK", symbol: "l.joystick.tilt.left", year: 1998,
                   libretroFolder: "SNK - Neo Geo Pocket Color",
                   fileExtensions: ["ngp", "ngpc"],
                   folderAliases: ["neo geo pocket", "ngp"],
                   emulators: ["ares", "openemu", "retroarch"]),

        GameSystem(id: "wonderswan", name: "WonderSwan", shortName: "WonderSwan",
                   manufacturer: "Bandai", symbol: "l.joystick.tilt.left", year: 1999,
                   libretroFolder: "Bandai - WonderSwan Color",
                   fileExtensions: ["ws", "wsc"],
                   folderAliases: ["wonderswan"],
                   emulators: ["ares", "retroarch"]),

        GameSystem(id: "lynx", name: "Atari Lynx", shortName: "Lynx",
                   manufacturer: "Atari", symbol: "l.joystick.tilt.left", year: 1989,
                   libretroFolder: "Atari - Lynx",
                   fileExtensions: ["lnx"],
                   folderAliases: ["lynx"],
                   emulators: ["ares", "openemu", "retroarch"]),

        GameSystem(id: "atari2600", name: "Atari 2600", shortName: "2600",
                   manufacturer: "Atari", symbol: "gamecontroller", year: 1977,
                   libretroFolder: "Atari - 2600",
                   fileExtensions: ["a26"],
                   folderAliases: ["atari 2600", "2600", "vcs"],
                   emulators: ["ares", "openemu", "retroarch"]),

        GameSystem(id: "xbox", name: "Xbox", shortName: "Xbox",
                   manufacturer: "Microsoft", symbol: "gamecontroller", year: 2001,
                   libretroFolder: "Microsoft - Xbox",
                   fileExtensions: ["xiso"],
                   folderAliases: ["xbox"],
                   emulators: ["xemu"]),

        GameSystem(id: "xbox360", name: "Xbox 360", shortName: "X360",
                   manufacturer: "Microsoft", symbol: "gamecontroller", year: 2005,
                   libretroFolder: nil,
                   fileExtensions: ["xex", "iso"],
                   folderAliases: ["xbox 360", "xbox360", "x360"],
                   emulators: ["xenia"]),

        GameSystem(id: "3do", name: "3DO", shortName: "3DO",
                   manufacturer: "Panasonic", symbol: "gamecontroller", year: 1993,
                   libretroFolder: "The 3DO Company - 3DO",
                   fileExtensions: ["iso", "cue", "chd"],
                   folderAliases: ["3do"],
                   emulators: ["retroarch", "openemu"]),

        GameSystem(id: "arcade", name: "Arcade", shortName: "Arcade",
                   manufacturer: "Arcade", symbol: "theatermasks", year: 1980,
                   libretroFolder: "MAME",
                   fileExtensions: ["zip", "7z"],
                   folderAliases: ["arcade", "mame", "fbneo", "fba"],
                   emulators: ["mame", "openemu", "retroarch"]),

        GameSystem(id: "amiga", name: "Amiga", shortName: "Amiga",
                   manufacturer: "Commodore", symbol: "desktopcomputer", year: 1985,
                   libretroFolder: "Commodore - Amiga",
                   fileExtensions: ["adf", "adz", "ipf", "lha", "hdf"],
                   folderAliases: ["amiga"],
                   emulators: ["retroarch", "openemu"]),

        GameSystem(id: "c64", name: "Commodore 64", shortName: "C64",
                   manufacturer: "Commodore", symbol: "desktopcomputer", year: 1982,
                   libretroFolder: "Commodore - 64",
                   fileExtensions: ["d64", "t64", "tap", "prg", "crt"],
                   folderAliases: ["c64", "commodore 64"],
                   emulators: ["retroarch", "openemu"]),

        GameSystem(id: "doom", name: "Doom", shortName: "Doom",
                   manufacturer: "PC", symbol: "flame", year: 1993,
                   libretroFolder: "DOOM",
                   fileExtensions: ["wad", "iwad", "pk3", "ipk3", "pk7"],
                   folderAliases: ["doom", "wads"],
                   emulators: ["uzdoom", "gzdoom", "retroarch"]),

        GameSystem(id: "dos", name: "MS-DOS", shortName: "DOS",
                   manufacturer: "PC", symbol: "desktopcomputer", year: 1981,
                   libretroFolder: "DOS",
                   fileExtensions: ["dosz", "conf"],
                   folderAliases: ["dos", "msdos", "ms-dos"],
                   emulators: ["dosbox", "retroarch", "boxer"]),

        GameSystem(id: "windows", name: "Jeu Windows", shortName: "Windows",
                   manufacturer: "PC", symbol: "pc", year: 1995,
                   libretroFolder: nil,
                   fileExtensions: ["exe", "msi", "bat", "lnk"],
                   folderAliases: ["pc", "windows", "win"],
                   emulators: ["crossover", "whisky", "porting-toolkit"]),

        GameSystem(id: "mac", name: "Jeu macOS", shortName: "macOS",
                   manufacturer: "Apple", symbol: "applelogo", year: 2000,
                   libretroFolder: nil,
                   fileExtensions: ["app", "command", "sh"],
                   folderAliases: ["mac", "macos", "osx"],
                   emulators: [])
    ]

    static let byID: [String: GameSystem] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func system(_ id: String) -> GameSystem? { byID[id] }

    /// Every system that claims this extension, most specific first.
    /// Ambiguous containers (`.iso`, `.bin`, `.cue`) come back as several.
    static func systems(forExtension ext: String) -> [GameSystem] {
        let e = ext.lowercased()
        // A system that uses few extensions is a far better guess than one that
        // accepts every disc-image format under the sun.
        return all.filter { $0.fileExtensions.contains(e) }
                  .sorted {
                      $0.fileExtensions.count != $1.fileExtensions.count
                          ? $0.fileExtensions.count < $1.fileExtensions.count
                          : $0.year < $1.year
                  }
    }

    /// Which system a folder name points at, if any ("PS2", "Wii : Wii U"…).
    static func system(forFolderName raw: String) -> GameSystem? {
        let name = raw.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        // Longest alias first so "wii u" beats "wii".
        let candidates = all.flatMap { sys in sys.folderAliases.map { ($0, sys) } }
            .sorted { $0.0.count > $1.0.count }
        for (alias, sys) in candidates where name == alias { return sys }
        for (alias, sys) in candidates where name.contains(alias) {
            // Guard against "Switch Firmware" style folders matching too eagerly:
            // require the alias to sit on a word boundary.
            let pattern = "(^|[^a-z0-9])\(NSRegularExpression.escapedPattern(for: alias))([^a-z0-9]|$)"
            if name.range(of: pattern, options: .regularExpression) != nil { return sys }
        }
        return nil
    }

    /// Extensions worth even opening a directory for.
    static let allExtensions: Set<String> = Set(all.flatMap { $0.fileExtensions })
}
