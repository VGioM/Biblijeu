//! Ce que Biblijeu sait sans toucher au disque : les consoles, les émulateurs
//! (Flatpak, paquets, AppImage), le nettoyage des noms de dumps, les sections
//! de la barre latérale, la recherche et le tri. Traduction de GameSystem.swift,
//! Emulator.swift, NameParser.swift et des parties pures de LibraryModel.swift.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::LazyLock;
use unicode_normalization::UnicodeNormalization;

pub struct System {
    pub id: &'static str, pub name: &'static str, pub short: &'static str, pub maker: &'static str, pub icon: &'static str,
    pub year: i32, pub libretro: Option<&'static str>, pub exts: &'static [&'static str], pub aliases: &'static [&'static str],
    pub emulators: &'static [&'static str],
}

macro_rules! sys {
    ($id:literal, $n:literal, $s:literal, $m:literal, $i:literal, $y:literal, $l:expr, [$($e:literal),*], [$($a:literal),*], [$($em:literal),*]) => {
        System { id: $id, name: $n, short: $s, maker: $m, icon: $i, year: $y, libretro: $l, exts: &[$($e),*], aliases: &[$($a),*], emulators: &[$($em),*] }
    };
}

pub static SYSTEMS: &[System] = &[
    sys!("nes", "Nintendo Entertainment System", "NES", "Nintendo", "gamepad", 1983, Some("Nintendo - Nintendo Entertainment System"), ["nes", "fds", "unf", "unif"], ["nes", "famicom", "nintendo entertainment system"], ["ares", "mesen", "retroarch"]),
    sys!("snes", "Super Nintendo", "SNES", "Nintendo", "gamepad", 1990, Some("Nintendo - Super Nintendo Entertainment System"), ["sfc", "smc", "swc", "fig", "bs"], ["snes", "super nintendo", "super famicom", "sfc"], ["snes9x", "ares", "mesen", "retroarch"]),
    sys!("n64", "Nintendo 64", "N64", "Nintendo", "gamepad", 1996, Some("Nintendo - Nintendo 64"), ["n64", "z64", "v64", "ndd"], ["n64", "nintendo 64"], ["ares", "simple64", "retroarch"]),
    sys!("gb", "Game Boy", "GB", "Nintendo", "gamepad", 1989, Some("Nintendo - Game Boy"), ["gb"], ["gb", "game boy", "gameboy"], ["mgba", "vbam", "ares", "retroarch"]),
    sys!("gbc", "Game Boy Color", "GBC", "Nintendo", "gamepad", 1998, Some("Nintendo - Game Boy Color"), ["gbc"], ["gbc", "game boy color", "gameboy color"], ["mgba", "vbam", "ares", "retroarch"]),
    sys!("gba", "Game Boy Advance", "GBA", "Nintendo", "gamepad", 2001, Some("Nintendo - Game Boy Advance"), ["gba", "agb"], ["gba", "game boy advance", "gameboy advance"], ["mgba", "vbam", "ares", "retroarch"]),
    sys!("nds", "Nintendo DS", "DS", "Nintendo", "stack", 2004, Some("Nintendo - Nintendo DS"), ["nds", "dsi", "ids", "srl"], ["nds", "ds", "nintendo ds"], ["melonds", "retroarch"]),
    sys!("n3ds", "Nintendo 3DS", "3DS", "Nintendo", "stack", 2011, Some("Nintendo - Nintendo 3DS"), ["3ds", "cci", "cxi", "cia", "3dsx"], ["3ds", "n3ds", "nintendo 3ds"], ["azahar", "lime3ds", "citra"]),
    sys!("gc", "Nintendo GameCube", "GameCube", "Nintendo", "disc", 2001, Some("Nintendo - GameCube"), ["gcm", "gcz", "rvz", "ciso", "iso", "wia"], ["gamecube", "game cube", "gc", "ngc"], ["dolphin"]),
    // Pas de « .wad » : un dump de chaîne Wii est rare, un wad Doom ne l'est pas.
    sys!("wii", "Wii", "Wii", "Nintendo", "disc", 2006, Some("Nintendo - Wii"), ["wbfs", "rvz", "wia", "iso"], ["wii"], ["dolphin"]),
    sys!("wiiu", "Nintendo Wii U", "Wii U", "Nintendo", "disc", 2012, Some("Nintendo - Wii U"), ["wud", "wux", "wua", "rpx"], ["wii u", "wiiu", "wii : wii u", "wii-wii u"], ["cemu"]),
    sys!("switch", "Nintendo Switch", "Switch", "Nintendo", "gamepad", 2017, None, ["xci", "nsp", "nsz", "xcz"], ["switch", "nintendo switch", "nsw"], ["ryujinx", "eden", "citron", "sudachi", "yuzu"]),
    sys!("vb", "Virtual Boy", "Virtual Boy", "Nintendo", "eye", 1995, Some("Nintendo - Virtual Boy"), ["vb", "vboy"], ["virtual boy", "vb"], ["ares", "retroarch"]),
    sys!("ps1", "PlayStation", "PS1", "Sony", "disc", 1994, Some("Sony - PlayStation"), ["cue", "chd", "pbp", "m3u", "ccd", "toc", "img", "ecm"], ["ps1", "psx", "playstation", "playstation 1", "psone"], ["duckstation", "ares", "retroarch"]),
    sys!("ps2", "PlayStation 2", "PS2", "Sony", "disc", 2000, Some("Sony - PlayStation 2"), ["iso", "chd", "cso", "gz", "bin", "mdf", "nrg"], ["ps2", "playstation 2"], ["pcsx2"]),
    sys!("ps3", "PlayStation 3", "PS3", "Sony", "disc", 2006, Some("Sony - PlayStation 3"), ["pkg", "self", "elf"], ["ps3", "playstation 3"], ["rpcs3"]),
    sys!("ps4", "PlayStation 4", "PS4", "Sony", "disc", 2013, None, ["pkg", "bin"], ["ps4", "playstation 4"], ["shadps4"]),
    sys!("psp", "PlayStation Portable", "PSP", "Sony", "stack", 2004, Some("Sony - PlayStation Portable"), ["cso", "pbp", "iso", "chd", "prx"], ["psp", "playstation portable"], ["ppsspp", "retroarch"]),
    sys!("vita", "PlayStation Vita", "Vita", "Sony", "stack", 2011, Some("Sony - PlayStation Vita"), ["vpk"], ["vita", "ps vita", "psvita"], ["vita3k"]),
    sys!("genesis", "Mega Drive", "Mega Drive", "Sega", "gamepad", 1988, Some("Sega - Mega Drive - Genesis"), ["md", "gen", "smd", "bin"], ["megadrive", "mega drive", "genesis", "md"], ["ares", "retroarch"]),
    sys!("mastersystem", "Master System", "Master System", "Sega", "gamepad", 1985, Some("Sega - Master System - Mark III"), ["sms"], ["master system", "sms", "mark iii"], ["ares", "retroarch"]),
    sys!("gamegear", "Game Gear", "Game Gear", "Sega", "gamepad", 1990, Some("Sega - Game Gear"), ["gg"], ["game gear", "gamegear", "gg"], ["ares", "retroarch"]),
    sys!("sega32x", "Sega 32X", "32X", "Sega", "gamepad", 1994, Some("Sega - 32X"), ["32x"], ["32x", "sega 32x"], ["ares", "retroarch"]),
    sys!("saturn", "Saturn", "Saturn", "Sega", "disc", 1994, Some("Sega - Saturn"), ["cue", "chd", "ccd", "mds"], ["saturn", "sega saturn"], ["ares", "retroarch"]),
    sys!("dreamcast", "Dreamcast", "Dreamcast", "Sega", "disc", 1998, Some("Sega - Dreamcast"), ["gdi", "cdi", "chd"], ["dreamcast", "dc"], ["flycast", "redream", "retroarch"]),
    sys!("pcengine", "PC Engine", "PC Engine", "NEC", "gamepad", 1987, Some("NEC - PC Engine - TurboGrafx 16"), ["pce", "sgx"], ["pc engine", "pcengine", "turbografx"], ["ares", "mesen", "retroarch"]),
    sys!("neogeo", "Neo Geo", "Neo Geo", "SNK", "gamepad", 1990, Some("SNK - Neo Geo"), ["neo"], ["neogeo", "neo geo"], ["mame", "retroarch"]),
    sys!("ngp", "Neo Geo Pocket", "NGP", "SNK", "gamepad", 1998, Some("SNK - Neo Geo Pocket Color"), ["ngp", "ngpc"], ["neo geo pocket", "ngp"], ["ares", "retroarch"]),
    sys!("wonderswan", "WonderSwan", "WonderSwan", "Bandai", "gamepad", 1999, Some("Bandai - WonderSwan Color"), ["ws", "wsc"], ["wonderswan"], ["ares", "retroarch"]),
    sys!("lynx", "Atari Lynx", "Lynx", "Atari", "gamepad", 1989, Some("Atari - Lynx"), ["lnx"], ["lynx"], ["ares", "retroarch"]),
    sys!("atari2600", "Atari 2600", "2600", "Atari", "gamepad", 1977, Some("Atari - 2600"), ["a26"], ["atari 2600", "2600", "vcs"], ["ares", "retroarch"]),
    sys!("xbox", "Xbox", "Xbox", "Microsoft", "disc", 2001, Some("Microsoft - Xbox"), ["xiso"], ["xbox"], ["xemu"]),
    sys!("xbox360", "Xbox 360", "X360", "Microsoft", "disc", 2005, None, ["xex", "iso"], ["xbox 360", "xbox360", "x360"], ["xenia"]),
    sys!("3do", "3DO", "3DO", "Panasonic", "disc", 1993, Some("The 3DO Company - 3DO"), ["iso", "cue", "chd"], ["3do"], ["retroarch"]),
    sys!("arcade", "Arcade", "Arcade", "Arcade", "star", 1980, Some("MAME"), ["zip", "7z"], ["arcade", "mame", "fbneo", "fba"], ["mame", "retroarch"]),
    sys!("amiga", "Amiga", "Amiga", "Commodore", "pc", 1985, Some("Commodore - Amiga"), ["adf", "adz", "ipf", "lha", "hdf"], ["amiga"], ["retroarch"]),
    sys!("c64", "Commodore 64", "C64", "Commodore", "pc", 1982, Some("Commodore - 64"), ["d64", "t64", "tap", "prg", "crt"], ["c64", "commodore 64"], ["retroarch"]),
    sys!("doom", "Doom", "Doom", "PC", "flame", 1993, Some("DOOM"), ["wad", "iwad", "pk3", "ipk3", "pk7"], ["doom", "wads"], ["uzdoom", "gzdoom", "retroarch"]),
    sys!("dos", "MS-DOS", "DOS", "PC", "terminal", 1981, Some("DOS"), ["dosz", "conf"], ["dos", "msdos", "ms-dos"], ["dosbox", "dosboxstaging", "retroarch"]),
    // Les jeux Windows passent par Proton, celui que Steam a installé.
    sys!("windows", "Jeu Windows", "Windows", "PC", "windows", 1995, None, ["exe", "msi", "bat", "lnk"], ["pc", "windows", "win"], ["proton"]),
    sys!("linux", "Jeu Linux", "Linux", "PC", "linux", 2000, None, ["appimage", "x86_64", "sh"], ["linux"], []),
];

pub fn system(id: &str) -> Option<&'static System> { SYSTEMS.iter().find(|s| s.id == id) }

pub static ALL_EXTS: LazyLock<std::collections::HashSet<&'static str>> = LazyLock::new(|| SYSTEMS.iter().flat_map(|s| s.exts.iter().copied()).collect());

/// Toutes les consoles qui revendiquent une extension, la plus spécifique d'abord.
pub fn systems_for_ext(ext: &str) -> Vec<&'static System> {
    let mut v: Vec<&System> = SYSTEMS.iter().filter(|s| s.exts.contains(&ext)).collect();
    v.sort_by(|a, b| a.exts.len().cmp(&b.exts.len()).then(a.year.cmp(&b.year)));
    v
}

/// La console qu'un nom de dossier désigne (« PS2 », « Wii : Wii U »…). L'alias le plus long d'abord.
pub fn system_for_folder(raw: &str) -> Option<&'static System> {
    let name = raw.to_lowercase().replace('_', " ").trim().to_string();
    let mut aliases: Vec<(&str, &System)> = SYSTEMS.iter().flat_map(|s| s.aliases.iter().map(move |a| (*a, s))).collect();
    aliases.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
    if let Some((_, s)) = aliases.iter().find(|(a, _)| *a == name) { return Some(s); }
    aliases.into_iter().find(|(a, _)| {
        name.match_indices(a).any(|(i, _)| {
            let before = name[..i].chars().last().map(|c| !c.is_ascii_alphanumeric()).unwrap_or(true);
            let after = name[i + a.len()..].chars().next().map(|c| !c.is_ascii_alphanumeric()).unwrap_or(true);
            before && after
        })
    }).map(|(_, s)| s)
}

// ── Émulateurs ────────────────────────────────────────────────────────────

#[derive(Debug)]
pub struct Resume { pub auto: Option<&'static [&'static str]>, pub slot: Option<&'static [&'static str]>, pub file: Option<&'static [&'static str]> }
const NO_RESUME: Resume = Resume { auto: None, slot: None, file: None };

#[derive(Debug)]
pub struct Emulator {
    pub id: &'static str, pub name: &'static str, pub systems: &'static [&'static str], pub flatpak: &'static [&'static str],
    pub bins: &'static [&'static str], pub appimage: Option<&'static str>, pub launch: &'static [&'static str],
    pub direct: Option<&'static [&'static str]>, pub homepage: Option<&'static str>, pub github: Option<&'static str>, pub resume: Resume,
}

const ROM: &[&str] = &["{rom}"];
const RETRO: &[&str] = &["nes", "snes", "n64", "gb", "gbc", "gba", "nds", "n3ds", "gc", "wii", "wiiu", "switch", "vb", "ps1", "ps2", "ps3", "ps4", "psp", "vita",
    "genesis", "mastersystem", "gamegear", "sega32x", "saturn", "dreamcast", "pcengine", "neogeo", "ngp", "wonderswan", "lynx", "atari2600", "xbox", "xbox360",
    "3do", "arcade", "amiga", "c64", "doom", "dos"];

macro_rules! emu {
    ($id:literal, $n:literal, [$($s:literal),*], fp: [$($f:literal),*], bins: [$($b:literal),*], img: $img:expr, launch: $l:expr, direct: $d:expr, home: $h:expr, gh: $g:expr, resume: $r:expr) => {
        Emulator { id: $id, name: $n, systems: &[$($s),*], flatpak: &[$($f),*], bins: &[$($b),*], appimage: $img, launch: $l, direct: $d, homepage: $h, github: $g, resume: $r }
    };
}

pub static EMULATORS: &[Emulator] = &[
    emu!("dolphin", "Dolphin", ["gc", "wii"], fp: ["org.DolphinEmu.dolphin-emu"], bins: ["dolphin-emu"], img: Some("dolphin"), launch: &["-e", "{rom}"], direct: Some(&["-b", "-e", "{rom}"]), home: Some("https://dolphin-emu.org"), gh: None, resume: Resume { auto: None, slot: None, file: Some(&["--save_state={state}"]) }),
    emu!("cemu", "Cemu", ["wiiu"], fp: ["info.cemu.Cemu"], bins: ["cemu", "Cemu"], img: Some("cemu"), launch: &["-g", "{rom}"], direct: Some(&["-f", "-g", "{rom}"]), home: Some("https://cemu.info"), gh: Some("cemu-project/Cemu"), resume: NO_RESUME),
    emu!("ryujinx", "Ryujinx", ["switch"], fp: ["io.github.ryubing.Ryujinx", "org.ryujinx.Ryujinx"], bins: ["Ryujinx", "ryujinx"], img: Some("ryujinx"), launch: ROM, direct: Some(&["--fullscreen", "{rom}"]), home: Some("https://ryujinx.app"), gh: None, resume: NO_RESUME),
    emu!("eden", "Eden", ["switch"], fp: [], bins: ["eden"], img: Some("eden"), launch: &["-g", "{rom}"], direct: Some(&["-f", "-g", "{rom}"]), home: None, gh: None, resume: NO_RESUME),
    emu!("citron", "Citron", ["switch"], fp: [], bins: ["citron"], img: Some("citron"), launch: ROM, direct: None, home: None, gh: None, resume: NO_RESUME),
    emu!("sudachi", "Sudachi", ["switch"], fp: [], bins: ["sudachi"], img: Some("sudachi"), launch: ROM, direct: Some(&["-f", "{rom}"]), home: None, gh: None, resume: NO_RESUME),
    emu!("yuzu", "Yuzu", ["switch"], fp: ["org.yuzu_emu.yuzu"], bins: ["yuzu"], img: Some("yuzu"), launch: ROM, direct: None, home: None, gh: None, resume: NO_RESUME),
    emu!("duckstation", "DuckStation", ["ps1"], fp: ["org.duckstation.DuckStation"], bins: ["duckstation-qt", "duckstation"], img: Some("duckstation"), launch: &["--", "{rom}"], direct: Some(&["-fullscreen", "-batch", "--", "{rom}"]), home: Some("https://duckstation.org"), gh: Some("stenzek/duckstation"),
        resume: Resume { auto: Some(&["-resume"]), slot: Some(&["-state", "{slot}"]), file: Some(&["-statefile", "{state}"]) }),
    // L'emplacement -1, c'est l'état que PCSX2 écrit en quittant.
    emu!("pcsx2", "PCSX2", ["ps2"], fp: ["net.pcsx2.PCSX2"], bins: ["pcsx2-qt", "pcsx2"], img: Some("pcsx2"), launch: &["--", "{rom}"], direct: Some(&["-batch", "-fullscreen", "--", "{rom}"]), home: Some("https://pcsx2.net"), gh: Some("PCSX2/pcsx2"),
        resume: Resume { auto: Some(&["-state", "-1"]), slot: Some(&["-state", "{slot}"]), file: Some(&["-statefile", "{state}"]) }),
    emu!("rpcs3", "RPCS3", ["ps3"], fp: ["net.rpcs3.RPCS3"], bins: ["rpcs3"], img: Some("rpcs3"), launch: ROM, direct: Some(&["--no-gui", "{rom}"]), home: None, gh: Some("RPCS3/rpcs3"), resume: NO_RESUME),
    emu!("shadps4", "shadPS4", ["ps4"], fp: ["net.shadps4.shadPS4"], bins: ["shadps4"], img: Some("shadps4"), launch: &["-g", "{rom}"], direct: None, home: None, gh: Some("shadps4-emu/shadPS4"), resume: NO_RESUME),
    emu!("ppsspp", "PPSSPP", ["psp"], fp: ["org.ppsspp.PPSSPP"], bins: ["PPSSPPSDL", "ppsspp", "PPSSPPQt"], img: Some("ppsspp"), launch: ROM, direct: Some(&["--fullscreen", "{rom}"]), home: Some("https://ppsspp.org"), gh: Some("hrydgard/ppsspp"), resume: Resume { auto: None, slot: None, file: Some(&["--state={state}"]) }),
    emu!("vita3k", "Vita3K", ["vita"], fp: ["org.vita3k.Vita3K"], bins: ["Vita3K", "vita3k"], img: Some("vita3k"), launch: &["-r", "{rom}"], direct: None, home: None, gh: Some("Vita3K/Vita3K"), resume: NO_RESUME),
    emu!("melonds", "melonDS", ["nds"], fp: ["net.kuribo64.melonDS"], bins: ["melonDS", "melonds"], img: Some("melonds"), launch: ROM, direct: Some(&["-f", "{rom}"]), home: None, gh: Some("melonDS-emu/melonDS"), resume: NO_RESUME),
    emu!("azahar", "Azahar", ["n3ds"], fp: ["org.azahar_emu.Azahar"], bins: ["azahar", "azahar-qt"], img: Some("azahar"), launch: ROM, direct: Some(&["-f", "{rom}"]), home: None, gh: Some("azahar-emu/azahar"), resume: NO_RESUME),
    emu!("lime3ds", "Lime3DS", ["n3ds"], fp: ["io.github.lime3ds.Lime3DS"], bins: ["lime3ds", "lime3ds-gui"], img: Some("lime3ds"), launch: ROM, direct: None, home: None, gh: None, resume: NO_RESUME),
    emu!("citra", "Citra", ["n3ds"], fp: ["org.citra_emu.citra"], bins: ["citra-qt", "citra"], img: Some("citra"), launch: ROM, direct: None, home: None, gh: None, resume: NO_RESUME),
    emu!("snes9x", "Snes9x", ["snes"], fp: ["com.snes9x.Snes9x"], bins: ["snes9x-gtk", "snes9x"], img: None, launch: ROM, direct: None, home: None, gh: Some("snes9xgit/snes9x"), resume: NO_RESUME),
    emu!("vbam", "VisualBoyAdvance-M", ["gba", "gb", "gbc"], fp: ["com.vba_m.visualboyadvance-m"], bins: ["visualboyadvance-m"], img: Some("visualboyadvance"), launch: ROM, direct: Some(&["-f", "{rom}"]), home: None, gh: None, resume: NO_RESUME),
    emu!("mgba", "mGBA", ["gba", "gb", "gbc"], fp: ["io.mgba.mGBA"], bins: ["mgba-qt", "mgba"], img: Some("mgba"), launch: ROM, direct: Some(&["-f", "{rom}"]), home: None, gh: Some("mgba-emu/mgba"), resume: NO_RESUME),
    emu!("mesen", "Mesen", ["nes", "snes", "gb", "gbc", "pcengine"], fp: [], bins: ["Mesen", "mesen"], img: Some("mesen"), launch: ROM, direct: None, home: None, gh: Some("SourMesen/Mesen2"), resume: NO_RESUME),
    emu!("ares", "ares", ["nes", "snes", "n64", "gb", "gbc", "gba", "genesis", "mastersystem", "gamegear", "sega32x", "saturn", "pcengine", "ngp", "wonderswan", "lynx", "atari2600", "vb", "ps1"],
        fp: ["dev.ares.ares"], bins: ["ares"], img: Some("ares"), launch: ROM, direct: Some(&["--fullscreen", "{rom}"]), home: Some("https://ares-emu.net"), gh: Some("ares-emulator/ares"), resume: NO_RESUME),
    emu!("simple64", "simple64", ["n64"], fp: ["io.github.simple64.simple64"], bins: ["simple64-gui"], img: Some("simple64"), launch: ROM, direct: None, home: None, gh: None, resume: NO_RESUME),
    emu!("flycast", "Flycast", ["dreamcast"], fp: ["org.flycast.Flycast"], bins: ["flycast"], img: Some("flycast"), launch: ROM, direct: None, home: None, gh: Some("flyinghead/flycast"), resume: NO_RESUME),
    emu!("redream", "redream", ["dreamcast"], fp: [], bins: ["redream"], img: None, launch: ROM, direct: None, home: None, gh: None, resume: NO_RESUME),
    emu!("xemu", "xemu", ["xbox"], fp: ["app.xemu.xemu"], bins: ["xemu"], img: Some("xemu"), launch: &["-dvd_path", "{rom}"], direct: None, home: None, gh: Some("xemu-project/xemu"), resume: NO_RESUME),
    emu!("xenia", "Xenia Canary", ["xbox360"], fp: [], bins: ["xenia_canary", "xenia"], img: Some("xenia"), launch: ROM, direct: Some(&["--fullscreen=true", "{rom}"]), home: None, gh: None, resume: NO_RESUME),
    emu!("mame", "MAME", ["arcade", "neogeo"], fp: ["org.mamedev.MAME"], bins: ["mame"], img: None, launch: ROM, direct: None, home: None, gh: Some("mamedev/mame"), resume: NO_RESUME),
    // RetroArch a besoin d'un cœur (-L) : choisi d'après la console, parmi ceux installés.
    emu!("retroarch", "RetroArch", [], fp: ["org.libretro.RetroArch"], bins: ["retroarch"], img: Some("retroarch"), launch: ROM, direct: Some(&["-f", "{rom}"]), home: Some("https://retroarch.com"), gh: Some("libretro/RetroArch"), resume: NO_RESUME),
    emu!("uzdoom", "UZDoom", ["doom"], fp: [], bins: ["uzdoom"], img: Some("uzdoom"), launch: &["-iwad", "{rom}"], direct: Some(&["-fullscreen", "-iwad", "{rom}"]), home: None, gh: Some("UZDoom/UZDoom"), resume: NO_RESUME),
    emu!("gzdoom", "GZDoom", ["doom"], fp: ["org.zdoom.GZDoom"], bins: ["gzdoom"], img: Some("gzdoom"), launch: &["-iwad", "{rom}"], direct: Some(&["-fullscreen", "-iwad", "{rom}"]), home: None, gh: None, resume: NO_RESUME),
    emu!("dosbox", "DOSBox-X", ["dos"], fp: ["com.dosbox_x.DOSBox-X"], bins: ["dosbox-x"], img: None, launch: &["-conf", "{rom}"], direct: None, home: None, gh: None, resume: NO_RESUME),
    emu!("dosboxstaging", "DOSBox Staging", ["dos"], fp: ["io.github.dosbox-staging"], bins: ["dosbox"], img: None, launch: &["-conf", "{rom}"], direct: None, home: None, gh: None, resume: NO_RESUME),
    // Pas un programme à trouver : présent dès que Steam a installé un Proton.
    emu!("proton", "Proton", ["windows"], fp: [], bins: [], img: None, launch: ROM, direct: None, home: None, gh: None, resume: NO_RESUME),
];

impl Emulator {
    pub fn runs(&self, sys: &str) -> bool { if self.id == "retroarch" { RETRO.contains(&sys) } else { self.systems.contains(&sys) } }
    pub fn resumes(&self) -> bool { self.resume.auto.is_some() || self.resume.slot.is_some() || self.resume.file.is_some() }
}

pub fn emulator(id: &str) -> Option<&'static Emulator> { EMULATORS.iter().find(|e| e.id == id) }

#[derive(Clone, Debug, PartialEq)]
pub enum ResumeReq { FromStart, Auto, Slot(u32), File(String) }

/// Les arguments qui font honorer une demande de reprise, ou None si l'émulateur ne sait pas.
pub fn resume_args(e: &Emulator, r: &ResumeReq) -> Option<Vec<String>> {
    let map = |a: &[&str], from: &str, to: &str| a.iter().map(|x| x.replace(from, to)).collect();
    match r {
        ResumeReq::FromStart => Some(vec![]),
        ResumeReq::Auto => e.resume.auto.map(|a| a.iter().map(|s| s.to_string()).collect()).or_else(|| e.resume.slot.map(|s| map(s, "{slot}", "1"))),
        ResumeReq::Slot(n) => e.resume.slot.map(|s| map(s, "{slot}", &n.to_string())),
        ResumeReq::File(p) => e.resume.file.map(|s| map(s, "{state}", p)),
    }
}

// ── Noms de dumps ─────────────────────────────────────────────────────────

const REGIONS: &[(&str, &str)] = &[("europe", "Europe"), ("usa", "États-Unis"), ("japan", "Japon"), ("world", "Monde"), ("france", "France"), ("germany", "Allemagne"),
    ("italy", "Italie"), ("spain", "Espagne"), ("korea", "Corée"), ("china", "Chine"), ("taiwan", "Taïwan"), ("brazil", "Brésil"), ("australia", "Australie"),
    ("canada", "Canada"), ("netherlands", "Pays-Bas"), ("sweden", "Suède"), ("norway", "Norvège"), ("denmark", "Danemark"), ("finland", "Finlande"),
    ("russia", "Russie"), ("asia", "Asie"), ("uk", "Royaume-Uni"), ("united kingdom", "Royaume-Uni"), ("hong kong", "Hong Kong"), ("greece", "Grèce"),
    ("portugal", "Portugal"), ("poland", "Pologne"), ("unknown", "Région inconnue"), ("usa, europe", "usa, europe"), ("japan, usa", "japan, usa"),
    ("europe, australia", "europe, australia"), ("japan, europe", "japan, europe")];
const LANGS: &[&str] = &["en", "fr", "de", "es", "it", "ja", "nl", "pt", "sv", "no", "da", "fi", "zh", "ko", "ru", "pl", "cs", "hu", "tr", "ar", "he", "el", "ca", "zh-hant", "zh-hans", "pt-br", "es-419"];

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Parsed { pub title: String, pub region: Option<String>, pub languages: Vec<String>, pub revision: Option<String>, pub disc: Option<u32>, pub tags: Vec<String>, pub raw: String }

fn region(l: &str) -> Option<String> { REGIONS.iter().find(|r| r.0 == l).map(|r| r.1.to_string()) }

pub fn parse_name(raw: &str) -> Parsed {
    let mut r = Parsed { title: raw.into(), raw: raw.into(), ..Default::default() };
    let mut working = String::new();
    let mut groups = vec![];
    let mut depth = None::<usize>;
    for (i, c) in raw.char_indices() {
        match (c, depth) {
            ('(' | '[', None) => depth = Some(i),
            (')' | ']', Some(s)) => { groups.push(raw[s + 1..i].to_string()); working.push(' '); depth = None; }
            (_, None) => working.push(c),
            _ => {}
        }
    }
    if let Some(s) = depth { working.push_str(&raw[s..]); }
    for g in groups {
        let t = g.trim();
        if t.is_empty() { continue; }
        let lower = t.to_lowercase();
        if let Some(reg) = region(&lower) { r.region = Some(reg); continue; }
        let parts: Vec<&str> = lower.split(',').map(|p| p.trim()).collect();
        if parts.iter().all(|p| LANGS.contains(p)) { r.languages = parts.iter().map(|p| p.to_uppercase()).collect(); continue; }
        let disc = ["disc", "disk", "disque", "cd"].iter().find_map(|w| lower.strip_prefix(w).map(|x| x.trim()).filter(|x| !x.is_empty() && x.chars().all(|c| c.is_ascii_digit())).and_then(|x| x.parse().ok()));
        if disc.is_some() { r.disc = disc; continue; }
        if lower.starts_with("rev ") || (lower.starts_with('v') && lower.len() > 1 && lower[1..].chars().all(|c| c.is_ascii_digit() || c == '.')) { r.revision = Some(t.into()); continue; }
        if t.len() >= 12 && t.chars().all(|c| c.is_ascii_hexdigit()) { continue; }
        r.tags.push(t.into());
    }
    let mut w = working.replace('_', " ");
    while w.contains("  ") { w = w.replace("  ", " "); }
    let mut w = w.trim_matches(|c: char| " -–—.·".contains(c)).to_string();
    // « Super-Mario-Sunshine-Europe-En-Fr-De-Es-It »
    if !w.contains(' ') && w.contains('-') {
        let mut tokens: Vec<&str> = w.split('-').collect();
        let (mut langs, mut reg) = (vec![], None);
        while let Some(last) = tokens.last() {
            let l = last.to_lowercase();
            if LANGS.contains(&l.as_str()) { langs.insert(0, last.to_uppercase()); tokens.pop(); }
            else if let Some(x) = region(&l) { reg = Some(x); tokens.pop(); }
            else { break; }
        }
        if r.region.is_none() { r.region = reg; }
        if r.languages.is_empty() { r.languages = langs; }
        w = tokens.join(" ");
    }
    // « Legend of Zelda, The » se lit mieux « The Legend of Zelda ».
    for a in ["The", "A", "An", "Le", "La", "Les", "L'", "Der", "Die", "Das", "El", "Los"] {
        let needle = format!(", {a}");
        if let Some(i) = w.find(&needle) {
            let after = &w[i + needle.len()..];
            if after.chars().next().map(|c| c.is_ascii_alphabetic()).unwrap_or(false) { continue; }
            w = format!("{a} {}{after}", &w[..i]).split_whitespace().collect::<Vec<_>>().join(" ");
            break;
        }
    }
    r.title = if w.is_empty() { raw.into() } else { w };
    r
}

/// Minuscules, sans accents ni ponctuation : pour comparer un nom de ROM à un index.
pub fn normalize(t: &str) -> String {
    let f: String = t.nfd().filter(|c| !('\u{300}'..='\u{36f}').contains(c)).collect::<String>().to_lowercase();
    f.chars().map(|c| if c.is_alphanumeric() { c } else { ' ' }).collect::<String>().split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn normalized_core(t: &str) -> String {
    let mut out = String::new();
    let mut depth = 0;
    for c in t.chars() { match c { '(' | '[' => depth += 1, ')' | ']' => { if depth > 0 { depth -= 1; } out.push(' '); } _ if depth == 0 => out.push(c), _ => {} } }
    normalize(&out)
}

const STOP: &[&str] = &["the", "a", "an", "of", "and", "le", "la", "les", "de", "du"];
pub fn tokens(t: &str) -> std::collections::HashSet<String> { normalize(t).split(' ').filter(|w| !w.is_empty() && !STOP.contains(w)).map(String::from).collect() }

// ── Vignettes ─────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Kind { Rom, Game, Emulator, Other }

impl Kind {
    pub fn label(self) -> &'static str { match self { Kind::Rom => "ROM", Kind::Game => "Jeu", Kind::Emulator => "Émulateur", Kind::Other => "Autre" } }
    pub fn all() -> [Kind; 4] { [Kind::Rom, Kind::Game, Kind::Emulator, Kind::Other] }
}

#[derive(Clone, Debug)]
pub struct Item {
    pub id: String, pub kind: Kind, pub title: String, pub sort_title: String, pub system: String, pub path: std::path::PathBuf,
    pub discs: Vec<std::path::PathBuf>, pub region: Option<String>, pub languages: Vec<String>, pub tags: Vec<String>, pub size: u64,
    pub added: i64, pub source_root: Option<String>, pub raw_name: String, pub local_art: Option<std::path::PathBuf>,
    pub steam_id: Option<String>, pub desktop_exec: Option<String>, pub version: Option<String>, pub emulator_id: Option<String>,
}

pub fn bytes(n: u64) -> String { if n == 0 { String::new() } else { crate::common::sys::bytes(n) } }

impl Item {
    pub fn sys(&self) -> Option<&'static System> { system(&self.system) }
    /// « SNES · France · 1,0 Mo »
    pub fn subtitle(&self) -> String {
        let mut p = vec![];
        if self.kind == Kind::Other { p.push("Autre".to_string()); } else if let Some(s) = self.sys() { p.push(s.short.into()); }
        if let Some(r) = &self.region { p.push(r.clone()); }
        if self.discs.len() > 1 { p.push(format!("{} disques", self.discs.len())); }
        if self.size > 0 { p.push(bytes(self.size)); }
        if self.kind != Kind::Rom { if let Some(v) = &self.version { p.push(format!("v{v}")); } }
        p.join(" · ")
    }
    pub fn icon(&self) -> &'static str {
        match self.kind { Kind::Emulator => "cpu", Kind::Other => "doc", _ => self.sys().map(|s| s.icon).unwrap_or("gamepad") }
    }
    pub fn haystack(&self) -> String {
        let s = self.sys();
        [self.title.as_str(), &self.raw_name, self.region.as_deref().unwrap_or(""), s.map(|s| s.name).unwrap_or(""), s.map(|s| s.short).unwrap_or(""), &self.tags.join(" ")].join(" ").to_lowercase()
    }
}

// ── État de chaque jeu ────────────────────────────────────────────────────

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GameState {
    pub last_played: Option<i64>, pub play_count: u32, pub favorite: bool, pub hidden: bool, #[serde(rename = "emulatorID")] pub emulator_id: Option<String>,
    #[serde(rename = "artworkURL")] pub artwork_url: Option<String>, pub custom_artwork_path: Option<String>, pub artwork_missing: bool,
    pub search_title: Option<String>, pub resume_slot: Option<u32>, pub state_file_path: Option<String>, pub kind_override: Option<Kind>,
    pub system_override: Option<String>, pub proton_version: Option<String>,
}

// ── Sections ──────────────────────────────────────────────────────────────

pub const SECTIONS: &[(&str, &str, &str)] = &[("all", "Tout", "grid"), ("recent", "Joués récemment", "history"), ("favorites", "Favoris", "heart"),
    ("roms", "ROM installées", "disc"), ("games", "Jeux installés", "app"), ("emulators", "Émulateurs", "cpu"), ("other", "Autres", "doc"),
    ("unplayable", "Sans émulateur", "warning"), ("updates", "Mises à jour", "downCircle"), ("backups", "Sauvegarde", "drive")];
pub const SORTS: &[(&str, &str)] = &[("title", "Titre"), ("recentlyPlayed", "Joué récemment"), ("recentlyAdded", "Ajouté récemment"), ("system", "Console"), ("size", "Taille")];

pub fn section_title(sel: &str) -> String {
    if let Some(id) = sel.strip_prefix("system:") { return system(id).map(|s| s.name.to_string()).unwrap_or(id.into()); }
    if let Some(p) = sel.strip_prefix("source:") { return p.rsplit('/').next().unwrap_or(p).into(); }
    SECTIONS.iter().find(|s| s.0 == sel).map(|s| s.1).unwrap_or("Tout").into()
}

pub fn in_section(it: &Item, sel: &str, st: &GameState, playable: bool) -> bool {
    match sel {
        "all" => it.kind != Kind::Emulator && it.kind != Kind::Other,
        "recent" => st.last_played.is_some(),
        "favorites" => st.favorite,
        "roms" => it.kind == Kind::Rom,
        "games" => it.kind == Kind::Game,
        "emulators" => it.kind == Kind::Emulator,
        "other" => it.kind == Kind::Other,
        "unplayable" => it.kind == Kind::Rom && !playable,
        s if s.starts_with("system:") => matches!(it.kind, Kind::Rom | Kind::Game) && it.system == s[7..],
        s if s.starts_with("source:") => it.source_root.as_deref().map(|r| r == &s[7..] || r.starts_with(&format!("{}/", &s[7..]))).unwrap_or(false),
        _ => true,
    }
}

pub fn sort_items(v: &mut [usize], items: &[Item], states: &HashMap<String, GameState>, sel: &str, sort: &str) {
    let lp = |i: usize| states.get(&items[i].id).and_then(|s| s.last_played).unwrap_or(0);
    if sel == "recent" { v.sort_by(|&a, &b| lp(b).cmp(&lp(a))); return; }
    match sort {
        "recentlyPlayed" => v.sort_by(|&a, &b| lp(b).cmp(&lp(a)).then(items[a].sort_title.cmp(&items[b].sort_title))),
        "recentlyAdded" => v.sort_by(|&a, &b| items[b].added.cmp(&items[a].added)),
        "size" => v.sort_by(|&a, &b| items[b].size.cmp(&items[a].size)),
        "system" => v.sort_by(|&a, &b| items[a].sys().map(|s| s.name).unwrap_or("").cmp(items[b].sys().map(|s| s.name).unwrap_or("")).then(items[a].sort_title.cmp(&items[b].sort_title))),
        _ => v.sort_by(|&a, &b| items[a].sort_title.cmp(&items[b].sort_title)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dump_names() {
        let p = parse_name("Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De)");
        assert_eq!(p.title, "The Legend of Zelda - Ocarina of Time");
        assert_eq!(p.region.as_deref(), Some("Europe"));
        assert_eq!(p.languages, vec!["EN", "FR", "DE"]);
        let h = parse_name("Super-Mario-Sunshine-Europe-En-Fr-De-Es-It");
        assert_eq!(h.title, "Super Mario Sunshine");
        assert_eq!(h.languages.len(), 5);
        assert_eq!(parse_name("Final Fantasy VII (France) (Disc 2)").disc, Some(2));
    }
    #[test]
    fn folders() {
        assert_eq!(system_for_folder("Wii U").map(|s| s.id), Some("wiiu"));
        assert_eq!(system_for_folder("Switch Firmware").map(|s| s.id), Some("switch"));
        assert!(system_for_folder("Mes trucs").is_none());
    }
    #[test]
    fn resume() {
        let duck = emulator("duckstation").unwrap();
        assert_eq!(resume_args(duck, &ResumeReq::Auto), Some(vec!["-resume".to_string()]));
        assert_eq!(resume_args(duck, &ResumeReq::Slot(3)), Some(vec!["-state".to_string(), "3".into()]));
        let dol = emulator("dolphin").unwrap();
        assert_eq!(resume_args(dol, &ResumeReq::File("/s.sav".into())), Some(vec!["--save_state=/s.sav".to_string()]));
        assert_eq!(resume_args(dol, &ResumeReq::Auto), None);
    }
}
