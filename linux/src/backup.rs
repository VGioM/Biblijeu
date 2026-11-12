//! L'onglet « Sauvegarde » : où chaque émulateur range ses sauvegardes sur
//! Linux (natif ou Flatpak, dans ~/.var/app), et la copie incrémentale vers le
//! disque choisi. Rien n'est jamais supprimé ; la partie la plus récente gagne ;
//! aucune ROM n'est copiée ; les liens symboliques ne sont ni suivis ni copiés ;
//! la copie n'entre jamais dans son propre dossier.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

pub const KINDS: &[(&str, &str, &str)] = &[
    ("saves", "Sauvegardes", "Le fichier de sauvegarde du jeu : votre partie."),
    ("states", "Sauvegardes d'état", "Un instantané de la machine, repris à l'image près. Volumineux et réécrit sans cesse, mais c'est la partie en cours."),
    ("memoryCards", "Cartes mémoire", "Les cartes mémoire GameCube, PlayStation et PS2 : toutes vos parties de ces consoles y sont."),
    ("systemMemory", "Mémoire système", "La mémoire propre de la console — NAND, EEPROM, NVRAM. Les sauvegardes Wii et 3DS y vivent, ainsi que les scores des bornes d'arcade."),
    ("sdCard", "Carte SD", "La carte SD virtuelle d'un émulateur Switch ou 3DS : c'est là que vont les jeux, mods et DLC installés. Des copies de jeux plutôt que des sauvegardes — décoché par défaut."),
];
pub const DEFAULT_KINDS: &[&str] = &["saves", "states", "memoryCards", "systemMemory"];
pub fn kind_label(k: &str) -> &'static str { KINDS.iter().find(|x| x.0 == k).map(|x| x.1).unwrap_or("Sauvegardes") }

pub const ROMS_ID: &str = "roms";
pub const FOLDER_NAME: &str = "Biblijeu Sauvegardes";
pub const MANIFEST: &str = "Biblijeu.json";

struct Ini { file: String, section: &'static str, key: &'static str, relative_to: String }
struct Spec { kind: &'static str, candidates: Vec<String>, slug: Option<&'static str>, label: Option<&'static str>, only: &'static [&'static str], excluding: &'static [&'static str], settings: Vec<Ini> }

fn fp(id: &str, sub: &str) -> String { format!(".var/app/{id}/{sub}") }
fn sp(kind: &'static str, c: &[String]) -> Spec { Spec { kind, candidates: c.to_vec(), slug: None, label: None, only: &[], excluding: &[], settings: vec![] } }
impl Spec {
    fn slug(mut self, s: &'static str, l: &'static str) -> Self { self.slug = Some(s); self.label = Some(l); self }
    fn label(mut self, l: &'static str) -> Self { self.label = Some(l); self }
    fn only(mut self, o: &'static [&'static str]) -> Self { self.only = o; self }
    fn excluding(mut self, o: &'static [&'static str]) -> Self { self.excluding = o; self }
    fn ini(mut self, file: String, section: &'static str, key: &'static str, rel: String) -> Self { self.settings.push(Ini { file, section, key, relative_to: rel }); self }
}
macro_rules! v { ($($e:expr),*) => { vec![$($e.to_string()),*] }; }

fn catalog() -> Vec<(&'static str, Vec<Spec>)> {
    let dol = "org.DolphinEmu.dolphin-emu";
    let duck = "org.duckstation.DuckStation";
    let p2 = "net.pcsx2.PCSX2";
    let ryu = ["io.github.ryubing.Ryujinx", "org.ryujinx.Ryujinx"];
    let three = |dir: &str, id: &str| vec![
        sp("sdCard", &v![format!(".local/share/{dir}/sdmc"), fp(id, &format!("data/{dir}/sdmc"))]).slug("sdmc", "Carte SD virtuelle"),
        sp("systemMemory", &v![format!(".local/share/{dir}/nand"), fp(id, &format!("data/{dir}/nand"))]),
        sp("states", &v![format!(".local/share/{dir}/states"), fp(id, &format!("data/{dir}/states"))]),
    ];
    let nx = |n: &str| vec![sp("saves", &v![format!(".local/share/{n}/nand/user/save")]), sp("sdCard", &v![format!(".local/share/{n}/sdmc")])];
    let up = "pfx/drive_c/users/steamuser";
    vec![
        ("dolphin", vec![
            sp("memoryCards", &v![".local/share/dolphin-emu/GC", fp(dol, "data/dolphin-emu/GC")]),
            sp("systemMemory", &v![".local/share/dolphin-emu/Wii", fp(dol, "data/dolphin-emu/Wii")]),
            sp("states", &v![".local/share/dolphin-emu/StateSaves", fp(dol, "data/dolphin-emu/StateSaves")]),
            sp("saves", &v![".local/share/dolphin-emu/GBA", fp(dol, "data/dolphin-emu/GBA")]).slug("gba", "Sauvegardes Game Boy Advance"),
        ]),
        ("cemu", vec![sp("saves", &v![".local/share/Cemu/mlc01/usr/save", fp("info.cemu.Cemu", "data/Cemu/mlc01/usr/save")])]),
        ("ryujinx", vec![
            sp("saves", &v![".config/Ryujinx/bis/user/save", fp(ryu[0], "config/Ryujinx/bis/user/save"), fp(ryu[1], "config/Ryujinx/bis/user/save")]),
            // Ce qui dit à quel jeu appartient chaque dossier numéroté : inutile seul, indispensable avec.
            sp("saves", &v![".config/Ryujinx/bis/user/saveMeta", fp(ryu[0], "config/Ryujinx/bis/user/saveMeta"), fp(ryu[1], "config/Ryujinx/bis/user/saveMeta")]).slug("saveMeta", "Index des sauvegardes"),
            sp("sdCard", &v![".config/Ryujinx/sdcard", fp(ryu[0], "config/Ryujinx/sdcard")]),
        ]),
        ("eden", nx("eden")), ("citron", nx("citron")), ("sudachi", nx("sudachi")),
        ("yuzu", vec![sp("saves", &v![".local/share/yuzu/nand/user/save", fp("org.yuzu_emu.yuzu", "data/yuzu/nand/user/save")]), sp("sdCard", &v![".local/share/yuzu/sdmc"])]),
        ("duckstation", vec![
            sp("memoryCards", &v![".local/share/duckstation/memcards", fp(duck, "config/duckstation/memcards")])
                .ini(".local/share/duckstation/settings.ini".into(), "Folders", "MemoryCards", ".local/share/duckstation".into())
                .ini(fp(duck, "config/duckstation/settings.ini"), "Folders", "MemoryCards", fp(duck, "config/duckstation")),
            sp("states", &v![".local/share/duckstation/savestates", fp(duck, "config/duckstation/savestates")])
                .ini(".local/share/duckstation/settings.ini".into(), "Folders", "SaveStates", ".local/share/duckstation".into())
                .ini(fp(duck, "config/duckstation/settings.ini"), "Folders", "SaveStates", fp(duck, "config/duckstation")),
        ]),
        ("pcsx2", vec![
            sp("memoryCards", &v![".config/PCSX2/memcards", fp(p2, "config/PCSX2/memcards")])
                .ini(".config/PCSX2/inis/PCSX2.ini".into(), "Folders", "MemoryCards", ".config/PCSX2".into())
                .ini(fp(p2, "config/PCSX2/inis/PCSX2.ini"), "Folders", "MemoryCards", fp(p2, "config/PCSX2")),
            sp("states", &v![".config/PCSX2/sstates", fp(p2, "config/PCSX2/sstates")])
                .ini(".config/PCSX2/inis/PCSX2.ini".into(), "Folders", "Savestates", ".config/PCSX2".into())
                .ini(fp(p2, "config/PCSX2/inis/PCSX2.ini"), "Folders", "Savestates", fp(p2, "config/PCSX2")),
        ]),
        ("rpcs3", vec![sp("saves", &v![".config/rpcs3/dev_hdd0/home", fp("net.rpcs3.RPCS3", "config/rpcs3/dev_hdd0/home")])]),
        ("shadps4", vec![sp("saves", &v![".local/share/shadPS4/savedata", fp("net.shadps4.shadPS4", "data/shadPS4/savedata")])]),
        ("ppsspp", vec![
            sp("saves", &v![".config/ppsspp/PSP/SAVEDATA", fp("org.ppsspp.PPSSPP", "config/ppsspp/PSP/SAVEDATA")]),
            sp("states", &v![".config/ppsspp/PSP/PPSSPP_STATE", fp("org.ppsspp.PPSSPP", "config/ppsspp/PSP/PPSSPP_STATE")]),
        ]),
        ("vita3k", vec![sp("saves", &v![".local/share/Vita3K/Vita3K/ux0/user", fp("org.vita3k.Vita3K", "data/Vita3K/Vita3K/ux0/user")])]),
        ("azahar", three("azahar-emu", "org.azahar_emu.Azahar")),
        ("lime3ds", three("lime3ds-emu", "io.github.lime3ds.Lime3DS")),
        ("citra", three("citra-emu", "org.citra_emu.citra")),
        ("mesen", vec![sp("saves", &v![".config/Mesen2/Saves", "Documents/Mesen2/Saves"]), sp("states", &v![".config/Mesen2/SaveStates", "Documents/Mesen2/SaveStates"])]),
        ("simple64", vec![sp("saves", &v![".local/share/simple64/save", ".local/share/mupen64plus/save", fp("io.github.simple64.simple64", "data/simple64/save")])]),
        ("flycast", vec![sp("saves", &v![".local/share/flycast", fp("org.flycast.Flycast", "data/flycast")]).only(&["bin", "sav", "state", "vmu"])]),
        ("redream", vec![sp("saves", &v![".redream/saves"])]),
        // L'EEPROM et le disque dur sont dans le même dossier, et le disque est une image de 8 Go.
        ("xemu", vec![sp("systemMemory", &v![".local/share/xemu/xemu", fp("app.xemu.xemu", "data/xemu/xemu")]).label("Mémoire système (EEPROM)").excluding(&["xbox_hdd.qcow2", "xbox_hdd.img"])]),
        ("xenia", vec![sp("saves", &v![".local/share/Xenia/content", "Documents/Xenia/content"])]),
        ("mame", vec![
            sp("systemMemory", &v![".mame/nvram", fp("org.mamedev.MAME", ".mame/nvram")]).slug("nvram", "Mémoire des bornes (NVRAM)"),
            sp("states", &v![".mame/sta", fp("org.mamedev.MAME", ".mame/sta")]),
        ]),
        ("retroarch", vec![
            sp("saves", &v![".config/retroarch/saves", fp("org.libretro.RetroArch", "config/retroarch/saves")]),
            sp("states", &v![".config/retroarch/states", fp("org.libretro.RetroArch", "config/retroarch/states")]),
        ]),
        ("uzdoom", vec![sp("saves", &v![".local/share/games/uzdoom", ".config/uzdoom/savegames"]).only(&["zds"])]),
        ("gzdoom", vec![sp("saves", &v![".local/share/games/gzdoom", ".config/gzdoom/savegames", fp("org.zdoom.GZDoom", ".config/gzdoom/savegames"), fp("org.zdoom.GZDoom", "data/games/gzdoom")]).only(&["zds"])]),
        // Un jeu Windows sauvegarde dans son préfixe Proton (un par jeu, nommé d'après lui).
        ("proton", vec![
            sp("saves", &v![format!("{{prefixes}}/*/{up}/Saved Games")]).slug("saved-games", "Jeux sauvegardés (Saved Games)"),
            sp("saves", &v![format!("{{prefixes}}/*/{up}/AppData/Roaming")]).slug("appdata", "Données d'application (AppData)"),
            sp("saves", &v![format!("{{prefixes}}/*/{up}/AppData/LocalLow")]).slug("locallow", "Données locales (LocalLow)"),
            sp("saves", &v![format!("{{prefixes}}/*/{up}/Documents")]).slug("documents", "Documents"),
        ]),
    ]
}

#[derive(Clone, Debug, Default)]
pub struct Filter { pub excluding: Vec<String>, pub only: Vec<String>, pub skips_work: bool }

#[derive(Clone, Debug)]
pub struct Folder { pub emulator: String, pub kind: &'static str, pub title: String, pub url: PathBuf, pub subpath: String, pub filter: Filter }

fn folder(emu: &str, kind: &'static str, slug: &str, label: Option<&str>, url: PathBuf, variant: &str, filter: Filter) -> Folder {
    let subpath = if variant.is_empty() { format!("{emu}/{slug}") } else { format!("{emu}/{slug}/{variant}") };
    let l = label.unwrap_or(kind_label(kind));
    Folder { emulator: emu.into(), kind, title: if variant.is_empty() { l.into() } else { format!("{l} — {variant}") }, url, subpath, filter }
}

pub fn is_dir(p: &Path) -> bool { std::fs::metadata(p).map(|m| m.is_dir()).unwrap_or(false) }
fn home() -> PathBuf { dirs::home_dir().unwrap_or_default() }

/// Une valeur dans un .ini : ce que l'émulateur dit lui-même de son dossier gagne.
pub fn read_ini(file: &Path, section: &str, key: &str) -> Option<String> {
    let t = std::fs::read_to_string(file).ok()?;
    let mut cur = String::new();
    for l in t.lines() {
        let l = l.trim();
        if l.starts_with('[') && l.ends_with(']') { cur = l[1..l.len() - 1].trim().to_string(); continue; }
        if !cur.eq_ignore_ascii_case(section) { continue; }
        if let Some((k, v)) = l.split_once('=') { if k.trim().eq_ignore_ascii_case(key) { let v = v.trim().trim_matches('"'); return (!v.is_empty()).then(|| v.into()); } }
    }
    None
}

/// Développe un chemin du catalogue ; `*` nomme le dossier dans la sauvegarde.
fn expand(c: &str, prefixes: &Path) -> Vec<(PathBuf, String)> {
    let full = if let Some(r) = c.strip_prefix("{prefixes}") { format!("{}{r}", prefixes.display()) } else { home().join(c).to_string_lossy().into() };
    let mut found = vec![(PathBuf::from("/"), String::new())];
    for part in full.split('/').skip(1) {
        if part.is_empty() { continue; }
        if part == "*" {
            let mut next = vec![];
            for (p, _) in &found {
                let Ok(rd) = std::fs::read_dir(p) else { continue };
                for e in rd.flatten() { let n = e.file_name().to_string_lossy().to_string(); if !n.starts_with('.') && is_dir(&e.path()) { next.push((e.path(), n)); } }
            }
            found = next;
        } else { for f in found.iter_mut() { f.0.push(part); } }
    }
    found.into_iter().filter(|f| is_dir(&f.0)).collect()
}

pub fn catalog_folders(prefixes: &Path) -> Vec<Folder> {
    let mut out = vec![];
    for (emu, specs) in catalog() {
        for s in specs {
            let slug = s.slug.unwrap_or(s.kind);
            let filter = Filter { excluding: s.excluding.iter().map(|x| x.to_string()).collect(), only: s.only.iter().map(|x| x.to_string()).collect(), skips_work: false };
            // Ce que l'émulateur écrit dans sa configuration passe avant tout.
            let configured = s.settings.iter().find_map(|i| {
                let v = read_ini(&home().join(&i.file), i.section, i.key)?;
                let p = if v.starts_with('/') { PathBuf::from(v) } else { home().join(&i.relative_to).join(v) };
                is_dir(&p).then_some(p)
            });
            if let Some(p) = configured { out.push(folder(emu, s.kind, slug, s.label, p, "", filter)); continue; }
            let mut seen = HashSet::new();
            for c in &s.candidates {
                for (p, variant) in expand(c, prefixes) {
                    if !seen.insert(variant.clone()) { continue; }   // natif et Flatpak : le premier trouvé
                    out.push(folder(emu, s.kind, slug, s.label, p, &variant, filter.clone()));
                }
            }
        }
    }
    out
}

// ── Sauvegardes posées à côté du jeu ──────────────────────────────────────

fn fingerprint(p: &str) -> String { let mut h: u32 = 5381; for b in p.bytes() { h = (h.wrapping_mul(33).wrapping_add(b as u32)) & 0xfffffff; } format!("{:04x}", h & 0xffff) }

pub fn rom_folders(roots: &[String]) -> Vec<Folder> {
    let base = |r: &str| Path::new(r).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let saves: Vec<String> = ["srm", "sav", "dsv", "rtc", "eep", "fla", "mpk", "sra", "gme", "mcr", "mcd"].iter().map(|s| s.to_string()).collect();
    let mut states: Vec<String> = vec!["mln".into(), "sgm".into(), "state".into()];
    for i in 0..10 { states.push(format!("ss{i}")); states.push(format!("st{i}")); }
    for i in 1..10 { states.push(format!("state{i}")); }
    let mut out = vec![];
    for r in roots {
        if !is_dir(Path::new(r)) { continue; }
        let b = base(r);
        let n = if b.is_empty() { "dossier".into() } else { b.clone() };
        let name = if roots.iter().filter(|x| base(x) == b).count() == 1 { n } else { format!("{n}-{}", fingerprint(r)) };
        out.push(Folder { emulator: ROMS_ID.into(), kind: "saves", title: format!("Sauvegardes — {b}"), url: r.into(), subpath: format!("{ROMS_ID}/{name}/saves"),
            filter: Filter { excluding: vec![], only: saves.clone(), skips_work: true } });
        out.push(Folder { emulator: ROMS_ID.into(), kind: "states", title: format!("Sauvegardes d'état — {b}"), url: r.into(), subpath: format!("{ROMS_ID}/{name}/states"),
            filter: Filter { excluding: vec![], only: states.clone(), skips_work: true } });
    }
    out
}

// ── Moteur de copie ───────────────────────────────────────────────────────

const IGNORED: &[&str] = &[".DS_Store", ".directory", "Thumbs.db"];

fn wants(f: &Filter, name: &str) -> bool {
    if f.excluding.iter().any(|x| x == name) { return false; }
    if f.only.is_empty() { return true; }
    let ext = Path::new(name).extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    f.only.iter().any(|x| *x == ext)
}
fn skips(f: &Filter, name: &str) -> bool {
    if f.excluding.iter().any(|x| x == name) { return true; }
    if !f.skips_work { return false; }
    let n = name.to_lowercase();
    crate::scanner::is_work_folder(&n) || n == "biblijeu sauvegardes"
}

fn mtime_ms(m: &std::fs::Metadata) -> i64 { m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0) }

pub fn measure(dir: &Path, f: &Filter) -> (u64, u64) {
    fn walk(d: &Path, f: &Filter, out: &mut (u64, u64), depth: u32) {
        if depth > 40 { return; }
        let Ok(rd) = std::fs::read_dir(d) else { return };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            let Ok(t) = e.file_type() else { continue };
            if IGNORED.contains(&n.as_str()) || t.is_symlink() { continue; }
            if t.is_dir() { if !skips(f, &n) { walk(&e.path(), f, out, depth + 1); } continue; }
            if !t.is_file() || !wants(f, &n) { continue; }
            if let Ok(m) = e.metadata() { out.0 += 1; out.1 += m.len(); }
        }
    }
    let mut out = (0, 0);
    walk(dir, f, &mut out, 0);
    out
}

#[derive(Clone, Copy, Default)]
pub struct Rules { pub newest_wins: bool, pub only_existing: bool }

#[derive(Default, Debug, Clone)]
pub struct Outcome { pub copied: u64, pub identical: u64, pub kept_newer: u64, pub bytes: u64, pub failures: Vec<String>, pub cancelled: bool }
impl Outcome {
    pub fn add(&mut self, o: Outcome) { self.copied += o.copied; self.identical += o.identical; self.kept_newer += o.kept_newer; self.bytes += o.bytes; self.failures.extend(o.failures); self.cancelled |= o.cancelled; }
}

/// Copie `src` dans `dst`. Un fichier de même taille et même date (à la seconde
/// près) n'est pas recopié ; rien n'est supprimé à l'arrivée.
pub fn copy_tree(src: &Path, dst: &Path, f: &Filter, rules: Rules, cancel: &AtomicBool) -> Outcome {
    let mut out = Outcome::default();
    if !is_dir(src) { out.failures.push(format!("Dossier introuvable : {}", src.display())); return out; }
    if rules.only_existing && !dst.exists() { return out; }
    if let Err(e) = std::fs::create_dir_all(dst) { out.failures.push(format!("Impossible de créer {} : {e}", dst.display())); return out; }
    let own = std::fs::canonicalize(dst).unwrap_or(dst.to_path_buf());
    fn walk(s0: &Path, s: &Path, d: &Path, f: &Filter, rules: Rules, cancel: &AtomicBool, own: &Path, out: &mut Outcome) {
        let Ok(rd) = std::fs::read_dir(s) else { return };
        for e in rd.flatten() {
            if cancel.load(Ordering::Relaxed) { out.cancelled = true; return; }
            let n = e.file_name().to_string_lossy().to_string();
            let Ok(t) = e.file_type() else { continue };
            if IGNORED.contains(&n.as_str()) || t.is_symlink() { continue; }
            let (sp, dp) = (e.path(), d.join(&n));
            if t.is_dir() {
                // Une ROM et ses copies sur le même disque : ne jamais copier ses propres copies.
                if std::fs::canonicalize(&sp).map(|c| c == own).unwrap_or(false) || skips(f, &n) { continue; }
                // Recréé d'avance seulement quand tout est copié : une copie filtrée ne
                // doit pas reconstruire l'arborescence entière d'une ludothèque.
                if f.only.is_empty() && !rules.only_existing { let _ = std::fs::create_dir_all(&dp); }
                walk(s0, &sp, &dp, f, rules, cancel, own, out);
                if out.cancelled { return; }
                continue;
            }
            if !t.is_file() || !wants(f, &n) { continue; }
            let Ok(st) = e.metadata() else { continue };
            let theirs = std::fs::metadata(&dp).ok();
            let (sm, size) = (mtime_ms(&st), st.len());
            if let Some(th) = &theirs { if th.len() == size && (mtime_ms(th) - sm).abs() < 1000 { out.identical += 1; continue; } }
            if rules.only_existing && theirs.is_none() { continue; }
            if rules.newest_wins { if let Some(th) = &theirs { if mtime_ms(th) - sm >= 1000 { out.kept_newer += 1; continue; } } }
            // Écrit à côté puis renommé : une sauvegarde à moitié écrite est pire qu'une ancienne.
            let r = (|| -> std::io::Result<()> {
                if let Some(p) = dp.parent() { std::fs::create_dir_all(p)?; }
                let tmp = PathBuf::from(format!("{}.biblijeu-tmp", dp.display()));
                std::fs::copy(&sp, &tmp)?;
                let file = std::fs::File::options().write(true).open(&tmp)?;
                file.set_modified(st.modified()?)?;
                drop(file);
                std::fs::rename(&tmp, &dp)
            })();
            match r {
                Ok(()) => { out.copied += 1; out.bytes += size; }
                Err(err) => if out.failures.len() < 8 { out.failures.push(format!("{} : {err}", sp.strip_prefix(s0).unwrap_or(&sp).display())); },
            }
        }
    }
    walk(src, src, dst, f, rules, cancel, &own, &mut out);
    out
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Entry { pub emulator: String, pub kind: String, pub source: String, pub files: u64, pub bytes: u64, pub date: String }

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct Manifest { #[serde(default)] pub updated: String, #[serde(default)] pub machine: String, #[serde(default)] pub entries: BTreeMap<String, Entry> }

pub fn hostname() -> String { std::fs::read_to_string("/etc/hostname").map(|s| s.trim().to_string()).unwrap_or_else(|_| "linux".into()) }

#[cfg(test)]
mod tests {
    use super::*;
    fn tmp(n: &str) -> PathBuf { let p = std::env::temp_dir().join(format!("bj-bk-{}-{n}", std::process::id())); let _ = std::fs::remove_dir_all(&p); std::fs::create_dir_all(&p).unwrap(); p }
    fn touch(p: &Path, c: &str, age_s: u64) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, c).unwrap();
        let t = std::time::SystemTime::now() - std::time::Duration::from_secs(age_s);
        std::fs::File::options().write(true).open(p).unwrap().set_modified(t).unwrap();
    }
    #[test]
    fn copies_newest_and_never_deletes() {
        let (a, b) = (tmp("a"), tmp("b"));
        touch(&a.join("x/save.srm"), "new", 10);
        touch(&a.join("keep.sav"), "old", 500);
        touch(&b.join("keep.sav"), "newer on disk", 5);
        touch(&b.join("only-there.sav"), "z", 5);
        let c = AtomicBool::new(false);
        let o = copy_tree(&a, &b, &Filter::default(), Rules { newest_wins: true, only_existing: false }, &c);
        assert_eq!((o.copied, o.kept_newer), (1, 1));
        assert_eq!(std::fs::read_to_string(b.join("x/save.srm")).unwrap(), "new");
        assert!(b.join("only-there.sav").exists());
        let again = copy_tree(&a, &b, &Filter::default(), Rules { newest_wins: true, only_existing: false }, &c);
        assert_eq!((again.copied, again.identical), (0, 1));
        let _ = (std::fs::remove_dir_all(a), std::fs::remove_dir_all(b));
    }
    #[test]
    fn filters_and_own_folder() {
        let a = tmp("roms");
        touch(&a.join("N64/Mario.z64"), "rom", 10);
        touch(&a.join("N64/Mario.eep"), "save", 10);
        let dst = a.join(FOLDER_NAME).join("roms/x/saves");
        let f = rom_folders(&[a.to_string_lossy().into()]).remove(0).filter;
        let o = copy_tree(&a, &dst, &f, Rules::default(), &AtomicBool::new(false));
        assert_eq!(o.copied, 1);
        assert!(dst.join("N64/Mario.eep").exists() && !dst.join("N64/Mario.z64").exists());
        assert_eq!(measure(&a, &f).0, 1);
        let _ = std::fs::remove_dir_all(a);
    }
    #[test]
    fn ini() {
        let d = tmp("ini");
        std::fs::write(d.join("s.ini"), "[Main]\nX=1\n[Folders]\nMemoryCards = \"cards\"\n").unwrap();
        assert_eq!(read_ini(&d.join("s.ini"), "folders", "memorycards").as_deref(), Some("cards"));
        let _ = std::fs::remove_dir_all(d);
    }
}
