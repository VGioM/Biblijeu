import Foundation

/// How an emulator wants to be handed a ROM.
enum LaunchStyle: Hashable {
    /// Pass the ROM on the command line. `{rom}` is substituted.
    case arguments([String])
    /// Hand the ROM to the app as a document, the way a double-click would.
    case document
}

/// How an emulator can be told to start from a save state.
///
/// Nothing here guesses where a state file lives: `auto` and `slot` let the
/// emulator find its own per-game state, and `file` is only used with a path
/// the user picked themselves.
struct ResumeSupport: Hashable {
    /// "Load this game's most recent state", no argument needed.
    var auto: [String]?
    /// Numbered slot; `{slot}` is substituted.
    var slot: [String]?
    /// An explicit state file; `{state}` is substituted.
    var file: [String]?
    /// The emulator's own data directory under ~/Library/Application Support,
    /// the state folder inside it, and where that folder is configured -- asked
    /// of the emulator rather than assumed, so moving it is followed.
    var dataFolder: String?
    var stateFolder: String = ""
    var settingsFile: String?
    var stateKey: String = "SaveStates"
    /// The extensions worth reading in that folder.
    var extensions: [String] = []
    /// A state written by this emulator holds, in clear text, the path of the
    /// disc it was taken on -- so a state can be matched to a game with
    /// certainty rather than by when it was written.
    var statesNameTheirDisc: Bool = false

    var isSupported: Bool { auto != nil || slot != nil || file != nil }
    static let none = ResumeSupport()
}

/// What the user asked for when starting a game.
enum ResumeRequest: Hashable {
    case fromStart
    case auto
    case slot(Int)
    case file(URL)
}

/// Where a project announces its builds.
///
/// Nothing here guesses a repository from a name: a wrong one would answer
/// with somebody else's version numbers, which is worse than saying nothing.
/// An emulator whose project could not be pinned down simply has no source.
enum UpdateSource: Hashable {
    /// A GitHub repository, "owner/name". The newest release that is not a
    /// pre-release is what counts; projects that publish nothing else fall
    /// back to their newest build of any kind.
    case github(String)
    /// Dolphin numbers its builds itself and publishes them on its own site.
    case dolphin

    /// True when the source names only the build of the day, so anything
    /// different from what is installed is newer by construction.
    var namesOnlyTheCurrentBuild: Bool {
        if case .dolphin = self { return true }
        return false
    }

    /// The page to send the user to when they want the new build.
    var page: String {
        switch self {
        case .github(let repo): return "https://github.com/\(repo)/releases/latest"
        case .dolphin:          return "https://dolphin-emu.org/download/"
        }
    }
}

/// A known emulator: how to recognise it on disk and how to boot a game with it.
struct EmulatorSpec: Identifiable, Hashable {
    let id: String
    let name: String
    /// Matched case-insensitively against CFBundleIdentifier.
    let bundleIDs: [String]
    /// Fallback for apps that ship without a bundle id (VBA-M, some nightlies).
    let executableNames: [String]
    let systems: [String]
    /// Normal launch: emulator opens with its own interface, game boots.
    let launch: LaunchStyle
    /// "Lancement direct": straight to fullscreen, no emulator UI.
    let directLaunch: LaunchStyle?
    let homepage: String?
    /// Declared last so the existing catalogue entries stay untouched.
    var resume: ResumeSupport = .none
    /// Where to ask whether a newer build exists. Nil when the project has no
    /// feed worth trusting -- a dead repository, or a paid app that updates
    /// itself.
    var updates: UpdateSource? = nil

    /// The arguments that make this emulator honour `request`, or nil when it
    /// cannot do what was asked.
    func resumeArguments(for request: ResumeRequest) -> [String]? {
        switch request {
        case .fromStart:
            return []
        case .auto:
            // A slot-only emulator can still honour "resume" via its first slot.
            if let auto = resume.auto { return auto }
            if let slot = resume.slot { return slot.map { $0.replacingOccurrences(of: "{slot}", with: "1") } }
            return nil
        case .slot(let index):
            guard let slot = resume.slot else { return nil }
            return slot.map { $0.replacingOccurrences(of: "{slot}", with: String(index)) }
        case .file(let url):
            guard let file = resume.file else { return nil }
            return file.map { $0.replacingOccurrences(of: "{state}", with: url.path) }
        }
    }

    func arguments(for rom: URL, direct: Bool, leading: [String] = []) -> [String]? {
        let style = (direct ? directLaunch : nil) ?? launch
        guard case .arguments(let template) = style else { return nil }
        // Extra flags go first: several emulators pair a flag with the ROM
        // path ("-e <file>"), so nothing may be slipped in between them.
        return leading + template.map { $0.replacingOccurrences(of: "{rom}", with: rom.path) }
    }

    /// The same emulator, told to handle a different set of consoles. Used when
    /// the user corrects what an app can run: its command line is worth keeping.
    func withSystems(_ systems: [String]) -> EmulatorSpec {
        EmulatorSpec(id: id, name: name, bundleIDs: bundleIDs,
                     executableNames: executableNames, systems: systems,
                     launch: launch, directLaunch: directLaunch,
                     homepage: homepage, resume: resume, updates: updates)
    }

    func usesDocumentOpen(direct: Bool) -> Bool {
        let style = (direct ? directLaunch : nil) ?? launch
        if case .document = style { return true }
        return false
    }
}

/// An `EmulatorSpec` that was actually found on this machine.
struct InstalledEmulator: Identifiable, Hashable {
    let spec: EmulatorSpec
    let url: URL
    let version: String?

    var id: String { spec.id }
    var name: String { spec.name }
}

enum EmulatorCatalog {
    static let all: [EmulatorSpec] = [
        EmulatorSpec(id: "dolphin", name: "Dolphin",
                     bundleIDs: ["org.dolphin-emu.dolphin"], executableNames: ["Dolphin"],
                     systems: ["gc", "wii"],
                     launch: .arguments(["-e", "{rom}"]),
                     directLaunch: .arguments(["-b", "-e", "{rom}"]),
                     homepage: "https://dolphin-emu.org",
                     resume: ResumeSupport(file: ["--save_state={state}"],
                                           dataFolder: "Dolphin",
                                           stateFolder: "StateSaves",
                                           extensions: ["sav"]),
                     updates: .dolphin),

        EmulatorSpec(id: "cemu", name: "Cemu",
                     bundleIDs: ["info.cemu.Cemu"], executableNames: ["Cemu"],
                     systems: ["wiiu"],
                     launch: .arguments(["-g", "{rom}"]),
                     directLaunch: .arguments(["-f", "-g", "{rom}"]),
                     homepage: "https://cemu.info",
                     updates: .github("cemu-project/Cemu")),

        EmulatorSpec(id: "ryujinx", name: "Ryujinx",
                     bundleIDs: ["org.ryujinx.Ryujinx", "io.github.ryubing.ryujinx"],
                     executableNames: ["Ryujinx"],
                     systems: ["switch"],
                     launch: .arguments(["{rom}"]),
                     directLaunch: .arguments(["--fullscreen", "{rom}"]),
                     homepage: "https://ryujinx.app"),

        // Ships as a document-based app: it opens .nsp/.xci the way a
        // double-click would, and takes no ROM on the command line.
        EmulatorSpec(id: "astris", name: "Astris",
                     bundleIDs: ["V380-Ori.Astris"], executableNames: ["Astris"],
                     systems: ["switch"],
                     launch: .document, directLaunch: nil, homepage: nil,
                     updates: .github("V380-Ori/Astris.Binaries")),

        EmulatorSpec(id: "sudachi", name: "Sudachi",
                     bundleIDs: ["org.sudachi.sudachi"], executableNames: ["sudachi"],
                     systems: ["switch"],
                     launch: .arguments(["{rom}"]),
                     directLaunch: .arguments(["-f", "{rom}"]), homepage: nil),

        EmulatorSpec(id: "citron", name: "Citron",
                     bundleIDs: ["org.citron.citron"], executableNames: ["citron"],
                     systems: ["switch"],
                     launch: .arguments(["{rom}"]), directLaunch: nil, homepage: nil),

        EmulatorSpec(id: "yuzu", name: "Yuzu",
                     bundleIDs: ["org.yuzu_emu.yuzu"], executableNames: ["yuzu"],
                     systems: ["switch"],
                     launch: .arguments(["{rom}"]), directLaunch: nil, homepage: nil),

        EmulatorSpec(id: "duckstation", name: "DuckStation",
                     bundleIDs: ["com.github.stenzek.duckstation"], executableNames: ["DuckStation"],
                     systems: ["ps1"],
                     launch: .arguments(["--", "{rom}"]),
                     directLaunch: .arguments(["-fullscreen", "-batch", "--", "{rom}"]),
                     homepage: "https://duckstation.org",
                     resume: ResumeSupport(auto: ["-resume"],
                                           slot: ["-state", "{slot}"],
                                           file: ["-statefile", "{state}"],
                                           dataFolder: "DuckStation",
                                           stateFolder: "savestates",
                                           settingsFile: "settings.ini",
                                           extensions: ["sav"],
                                           statesNameTheirDisc: true),
                     updates: .github("stenzek/duckstation")),

        EmulatorSpec(id: "pcsx2", name: "PCSX2",
                     bundleIDs: ["net.pcsx2.pcsx2"], executableNames: ["PCSX2", "pcsx2-qt"],
                     systems: ["ps2"],
                     launch: .arguments(["--", "{rom}"]),
                     directLaunch: .arguments(["-batch", "-fullscreen", "--", "{rom}"]),
                     homepage: "https://pcsx2.net",
                     // Slot -1 is how PCSX2 names the state it writes when the
                     // player quits ("<serial> (<crc>).resume.p2s"); it works
                     // the serial out of the ISO we hand it, so no guessing.
                     resume: ResumeSupport(auto: ["-state", "-1"],
                                           slot: ["-state", "{slot}"],
                                           file: ["-statefile", "{state}"],
                                           dataFolder: "PCSX2",
                                           stateFolder: "sstates",
                                           settingsFile: "inis/PCSX2.ini",
                                           stateKey: "Savestates",
                                           extensions: ["p2s"]),
                     updates: .github("PCSX2/pcsx2")),

        EmulatorSpec(id: "rpcs3", name: "RPCS3",
                     bundleIDs: ["net.rpcs3.rpcs3"], executableNames: ["rpcs3"],
                     systems: ["ps3"],
                     launch: .arguments(["{rom}"]),
                     directLaunch: .arguments(["--no-gui", "{rom}"]), homepage: nil,
                     updates: .github("RPCS3/rpcs3")),

        // PS5 emulation at version 0.3: the bundle declares no document types,
        // so it takes no game from outside -- it is opened, and the game is
        // picked inside. Almost nothing boots yet.
        EmulatorSpec(id: "kytyps5", name: "KytyPS5",
                     bundleIDs: ["org.kytyps5.kytyps5"],
                     executableNames: ["KytyPS5", "kyty_emulator"],
                     systems: ["ps5"],
                     launch: .document, directLaunch: nil,
                     homepage: "https://kytyps5.net",
                     updates: .github("KytyPS5/KytyPS5")),

        EmulatorSpec(id: "ppsspp", name: "PPSSPP",
                     bundleIDs: ["org.ppsspp.ppsspp"], executableNames: ["PPSSPPSDL", "PPSSPP"],
                     systems: ["psp"],
                     launch: .arguments(["{rom}"]),
                     directLaunch: .arguments(["--fullscreen", "{rom}"]),
                     homepage: "https://ppsspp.org",
                     resume: ResumeSupport(file: ["--state={state}"],
                                           dataFolder: "PPSSPP",
                                           stateFolder: "PSP/PPSSPP_STATE",
                                           extensions: ["ppst"]),
                     updates: .github("hrydgard/ppsspp")),

        EmulatorSpec(id: "vita3k", name: "Vita3K",
                     bundleIDs: ["org.vita3k.vita3k"], executableNames: ["Vita3K"],
                     systems: ["vita"],
                     launch: .arguments(["-r", "{rom}"]), directLaunch: nil, homepage: nil,
                     updates: .github("Vita3K/Vita3K")),

        EmulatorSpec(id: "melonds", name: "melonDS",
                     bundleIDs: ["net.kuribo64.melonDS"], executableNames: ["melonDS"],
                     systems: ["nds"],
                     launch: .arguments(["{rom}"]),
                     directLaunch: .arguments(["-f", "{rom}"]),
                     homepage: "https://melonds.kuribo64.net",
                     updates: .github("melonDS-emu/melonDS")),

        EmulatorSpec(id: "azahar", name: "Azahar",
                     bundleIDs: ["org.azahar-emu.azahar"], executableNames: ["azahar"],
                     systems: ["n3ds"],
                     launch: .arguments(["{rom}"]),
                     directLaunch: .arguments(["-f", "{rom}"]),
                     homepage: "https://azahar-emu.org",
                     updates: .github("azahar-emu/azahar")),

        EmulatorSpec(id: "lime3ds", name: "Lime3DS",
                     bundleIDs: ["io.github.lime3ds.lime3ds"], executableNames: ["lime3ds"],
                     systems: ["n3ds"],
                     launch: .arguments(["{rom}"]), directLaunch: nil, homepage: nil,
                     updates: .github("Lime3DS/Lime3DS")),

        EmulatorSpec(id: "citra", name: "Citra",
                     bundleIDs: ["org.citra-emu.citra"], executableNames: ["citra-qt"],
                     systems: ["n3ds"],
                     launch: .arguments(["{rom}"]), directLaunch: nil, homepage: nil),

        EmulatorSpec(id: "snes9x", name: "Snes9x",
                     bundleIDs: ["com.snes9x.macos.snes9x", "com.snes9x.snes9x"],
                     executableNames: ["Snes9x"],
                     systems: ["snes"],
                     launch: .document, directLaunch: nil,
                     homepage: "https://www.snes9x.com",
                     updates: .github("snes9xgit/snes9x")),

        EmulatorSpec(id: "vbam", name: "VisualBoyAdvance-M",
                     bundleIDs: ["com.vba-m.visualboyadvance-m"],
                     executableNames: ["visualboyadvance-m"],
                     systems: ["gba", "gb", "gbc"],
                     launch: .arguments(["{rom}"]),
                     directLaunch: .arguments(["-f", "{rom}"]),
                     homepage: "https://vba-m.com",
                     updates: .github("visualboyadvance-m/visualboyadvance-m")),

        EmulatorSpec(id: "mgba", name: "mGBA",
                     bundleIDs: ["com.endrift.mgba"], executableNames: ["mGBA"],
                     systems: ["gba", "gb", "gbc"],
                     launch: .arguments(["{rom}"]),
                     directLaunch: .arguments(["-f", "{rom}"]), homepage: nil,
                     updates: .github("mgba-emu/mgba")),

        EmulatorSpec(id: "mesen", name: "Mesen",
                     bundleIDs: ["ca.mesen.Mesen"], executableNames: ["Mesen"],
                     systems: ["nes", "snes", "gb", "gbc", "pcengine"],
                     launch: .arguments(["{rom}"]), directLaunch: nil, homepage: nil,
                     updates: .github("SourMesen/Mesen2")),

        EmulatorSpec(id: "ares", name: "ares",
                     bundleIDs: ["dev.ares.ares"], executableNames: ["ares"],
                     systems: ["nes", "snes", "n64", "gb", "gbc", "gba", "genesis",
                               "mastersystem", "gamegear", "sega32x", "saturn", "pcengine",
                               "ngp", "wonderswan", "lynx", "atari2600", "vb", "ps1"],
                     launch: .arguments(["{rom}"]),
                     directLaunch: .arguments(["--fullscreen", "{rom}"]),
                     homepage: "https://ares-emu.net",
                     updates: .github("ares-emulator/ares")),

        EmulatorSpec(id: "simple64", name: "simple64",
                     bundleIDs: ["io.github.simple64.simple64"], executableNames: ["simple64-gui"],
                     systems: ["n64"],
                     launch: .arguments(["{rom}"]), directLaunch: nil, homepage: nil,
                     updates: .github("simple64/simple64")),

        EmulatorSpec(id: "flycast", name: "Flycast",
                     bundleIDs: ["com.flycast.Flycast", "org.flycast.Flycast"],
                     executableNames: ["Flycast"],
                     systems: ["dreamcast"],
                     launch: .arguments(["{rom}"]), directLaunch: nil, homepage: nil,
                     updates: .github("flyinghead/flycast")),

        EmulatorSpec(id: "redream", name: "redream",
                     bundleIDs: ["io.redream.redream"], executableNames: ["redream"],
                     systems: ["dreamcast"],
                     launch: .arguments(["{rom}"]), directLaunch: nil, homepage: nil),

        EmulatorSpec(id: "xemu", name: "xemu",
                     bundleIDs: ["app.xemu.xemu"], executableNames: ["xemu"],
                     systems: ["xbox"],
                     launch: .arguments(["-dvd_path", "{rom}"]), directLaunch: nil, homepage: nil,
                     updates: .github("xemu-project/xemu")),

        // Xenia takes the game as a positional argument; its switches are cvars,
        // written `--name=value` rather than as bare flags.
        EmulatorSpec(id: "xenia", name: "Xenia Edge",
                     bundleIDs: ["com.xenia.edge"],
                     executableNames: ["Xenia-edge", "xenia"],
                     systems: ["xbox360"],
                     launch: .arguments(["{rom}"]),
                     directLaunch: .arguments(["--fullscreen=true", "{rom}"]),
                     homepage: "https://xenia.jp",
                     updates: .github("has207/xenia-edge")),

        EmulatorSpec(id: "mame", name: "MAME",
                     bundleIDs: ["org.mamedev.mame"], executableNames: ["mame"],
                     systems: ["arcade", "neogeo"],
                     launch: .arguments(["{rom}"]), directLaunch: nil, homepage: nil,
                     updates: .github("mamedev/mame")),

        EmulatorSpec(id: "openemu", name: "OpenEmu",
                     bundleIDs: ["org.openemu.OpenEmu"], executableNames: ["OpenEmu"],
                     systems: ["nes", "snes", "n64", "gb", "gbc", "gba", "nds", "genesis",
                               "mastersystem", "gamegear", "sega32x", "saturn", "dreamcast",
                               "pcengine", "neogeo", "ngp", "lynx", "atari2600", "ps1",
                               "psp", "arcade", "3do", "vb"],
                     launch: .document, directLaunch: nil,
                     homepage: "https://openemu.org",
                     updates: .github("OpenEmu/OpenEmu")),

        EmulatorSpec(id: "retroarch", name: "RetroArch",
                     bundleIDs: ["com.libretro.RetroArch"], executableNames: ["RetroArch"],
                     systems: SystemCatalog.all.map(\.id),
                     launch: .document, directLaunch: nil,
                     homepage: "https://retroarch.com",
                     updates: .github("libretro/RetroArch")),

        EmulatorSpec(id: "uzdoom", name: "UZDoom",
                     bundleIDs: ["org.zdoom.UZDoom"], executableNames: ["uzdoom"],
                     systems: ["doom"],
                     launch: .arguments(["-iwad", "{rom}"]),
                     directLaunch: .arguments(["-fullscreen", "-iwad", "{rom}"]), homepage: nil,
                     updates: .github("UZDoom/UZDoom")),

        EmulatorSpec(id: "gzdoom", name: "GZDoom",
                     bundleIDs: ["org.zdoom.gzdoom", "org.drdteam.gzdoom"],
                     executableNames: ["gzdoom"],
                     systems: ["doom"],
                     launch: .arguments(["-iwad", "{rom}"]),
                     directLaunch: .arguments(["-fullscreen", "-iwad", "{rom}"]), homepage: nil,
                     updates: .github("ZDoom/gzdoom")),

        EmulatorSpec(id: "dosbox", name: "DOSBox-X",
                     bundleIDs: ["com.dosbox-x.dosbox-x", "com.dosbox.dosbox"],
                     executableNames: ["dosbox-x", "DOSBox"],
                     systems: ["dos"],
                     launch: .arguments(["-conf", "{rom}"]), directLaunch: nil, homepage: nil,
                     updates: .github("joncampbell123/dosbox-x")),

        EmulatorSpec(id: "boxer", name: "Boxer",
                     bundleIDs: ["net.washboardabs.boxer"], executableNames: ["Boxer"],
                     systems: ["dos"],
                     launch: .document, directLaunch: nil, homepage: nil),

        EmulatorSpec(id: "crossover", name: "CrossOver",
                     bundleIDs: ["com.codeweavers.CrossOver"], executableNames: ["CrossOver"],
                     systems: ["windows"],
                     launch: .document, directLaunch: nil,
                     homepage: "https://www.codeweavers.com"),

        EmulatorSpec(id: "whisky", name: "Whisky",
                     bundleIDs: ["com.isaacmarovitz.Whisky"], executableNames: ["Whisky"],
                     systems: ["windows"],
                     launch: .document, directLaunch: nil, homepage: nil,
                     updates: .github("Whisky-App/Whisky")),

        EmulatorSpec(id: "porting-toolkit", name: "Game Porting Toolkit",
                     bundleIDs: ["com.apple.gameportingtoolkit"], executableNames: [],
                     systems: ["windows"],
                     launch: .document, directLaunch: nil, homepage: nil)
    ]

    static let byID: [String: EmulatorSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func spec(forBundleID bundleID: String) -> EmulatorSpec? {
        let id = bundleID.lowercased()
        return all.first { $0.bundleIDs.contains { $0.lowercased() == id } }
    }

    static func spec(forExecutable name: String) -> EmulatorSpec? {
        all.first { $0.executableNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }
}
