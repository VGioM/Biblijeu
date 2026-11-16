//! L'onglet « Sauvegarde » : où chaque émulateur range ses sauvegardes sur
//! Windows (Documents, AppData, ou à côté de son .exe quand il est portable), et la copie incrémentale vers le
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

/// Le dossier de l'exe d'un émulateur détecté, suivi de `sub` : c'est là que vit
/// une installation portable (RetroArch, RPCS3, DuckStation avec portable.txt…).
fn ex(id: &str, sub: &str) -> Option<String> {
    crate::emulators::exe_dir(id).map(|d| d.join(sub).to_string_lossy().to_string())
}
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
    // Les chemins relatifs partent du dossier de l'utilisateur ; `ex(…)` donne
    // celui de l'émulateur portable, essayé d'abord.
    let c = |portable: Vec<Option<String>>, std: &[&str]| -> Vec<String> {
        portable.into_iter().flatten().chain(std.iter().map(|s| s.to_string())).collect()
    };
    let three = |id: &str, dir: &str| vec![
        sp("sdCard", &c(vec![ex(id, "user/sdmc")], &[&format!("AppData/Roaming/{dir}/sdmc")])).slug("sdmc", "Carte SD virtuelle"),
        sp("systemMemory", &c(vec![ex(id, "user/nand")], &[&format!("AppData/Roaming/{dir}/nand")])),
        sp("states", &c(vec![ex(id, "user/states")], &[&format!("AppData/Roaming/{dir}/states")])),
    ];
    let nx = |id: &str, n: &str| vec![
        sp("saves", &c(vec![ex(id, "user/nand/user/save")], &[&format!("AppData/Roaming/{n}/nand/user/save")])),
        sp("sdCard", &c(vec![ex(id, "user/sdmc")], &[&format!("AppData/Roaming/{n}/sdmc")])),
    ];
    let duck = ["Documents/DuckStation", "AppData/Local/DuckStation"];
    vec![
        ("dolphin", vec![
            sp("memoryCards", &c(vec![ex("dolphin", "User/GC")], &["AppData/Roaming/Dolphin Emulator/GC", "Documents/Dolphin Emulator/GC"])),
            sp("systemMemory", &c(vec![ex("dolphin", "User/Wii")], &["AppData/Roaming/Dolphin Emulator/Wii", "Documents/Dolphin Emulator/Wii"])),
            sp("states", &c(vec![ex("dolphin", "User/StateSaves")], &["AppData/Roaming/Dolphin Emulator/StateSaves", "Documents/Dolphin Emulator/StateSaves"])),
            sp("saves", &c(vec![ex("dolphin", "User/GBA")], &["AppData/Roaming/Dolphin Emulator/GBA", "Documents/Dolphin Emulator/GBA"])).slug("gba", "Sauvegardes Game Boy Advance"),
        ]),
        ("cemu", vec![sp("saves", &c(vec![ex("cemu", "mlc01/usr/save")], &["AppData/Roaming/Cemu/mlc01/usr/save"]))]),
        ("ryujinx", vec![
            sp("saves", &c(vec![ex("ryujinx", "portable/bis/user/save")], &["AppData/Roaming/Ryujinx/bis/user/save"])),
            // Ce qui dit à quel jeu appartient chaque dossier numéroté : inutile seul, indispensable avec.
            sp("saves", &c(vec![ex("ryujinx", "portable/bis/user/saveMeta")], &["AppData/Roaming/Ryujinx/bis/user/saveMeta"])).slug("saveMeta", "Index des sauvegardes"),
            sp("sdCard", &c(vec![ex("ryujinx", "portable/sdcard")], &["AppData/Roaming/Ryujinx/sdcard"])),
        ]),
        ("eden", nx("eden", "eden")), ("citron", nx("citron", "citron")), ("sudachi", nx("sudachi", "sudachi")), ("yuzu", nx("yuzu", "yuzu")),
        ("duckstation", vec![
            sp("memoryCards", &c(vec![ex("duckstation", "memcards")], &[&format!("{}/memcards", duck[0]), &format!("{}/memcards", duck[1])]))
                .ini(format!("{}/settings.ini", duck[0]), "Folders", "MemoryCards", duck[0].into())
                .ini(format!("{}/settings.ini", duck[1]), "Folders", "MemoryCards", duck[1].into()),
            sp("states", &c(vec![ex("duckstation", "savestates")], &[&format!("{}/savestates", duck[0]), &format!("{}/savestates", duck[1])]))
                .ini(format!("{}/settings.ini", duck[0]), "Folders", "SaveStates", duck[0].into())
                .ini(format!("{}/settings.ini", duck[1]), "Folders", "SaveStates", duck[1].into()),
        ]),
        ("pcsx2", vec![
            sp("memoryCards", &c(vec![ex("pcsx2", "memcards")], &["Documents/PCSX2/memcards"]))
                .ini("Documents/PCSX2/inis/PCSX2.ini".into(), "Folders", "MemoryCards", "Documents/PCSX2".into()),
            sp("states", &c(vec![ex("pcsx2", "sstates")], &["Documents/PCSX2/sstates"]))
                .ini("Documents/PCSX2/inis/PCSX2.ini".into(), "Folders", "Savestates", "Documents/PCSX2".into()),
        ]),
        ("rpcs3", vec![sp("saves", &c(vec![ex("rpcs3", "dev_hdd0/home")], &["AppData/Roaming/rpcs3/dev_hdd0/home"]))]),
        ("shadps4", vec![sp("saves", &c(vec![ex("shadps4", "user/savedata")], &["AppData/Roaming/shadPS4/savedata"]))]),
        ("ppsspp", vec![
            sp("saves", &c(vec![ex("ppsspp", "memstick/PSP/SAVEDATA")], &["Documents/PPSSPP/PSP/SAVEDATA"])),
            sp("states", &c(vec![ex("ppsspp", "memstick/PSP/PPSSPP_STATE")], &["Documents/PPSSPP/PSP/PPSSPP_STATE"])),
        ]),
        ("vita3k", vec![sp("saves", &c(vec![ex("vita3k", "ux0/user")], &["AppData/Roaming/Vita3K/Vita3K/ux0/user"]))]),
        ("azahar", three("azahar", "Azahar")),
        ("lime3ds", three("lime3ds", "Lime3DS")),
        ("citra", three("citra", "Citra")),
        ("mesen", vec![sp("saves", &c(vec![ex("mesen", "Saves")], &["Documents/Mesen2/Saves"])), sp("states", &c(vec![ex("mesen", "SaveStates")], &["Documents/Mesen2/SaveStates"]))]),
        ("simple64", vec![sp("saves", &c(vec![ex("simple64", "save")], &["AppData/Roaming/simple64/save"]))]),
        ("flycast", vec![sp("saves", &c(vec![ex("flycast", "data")], &["AppData/Roaming/flycast/data"])).only(&["bin", "sav", "state", "vmu"])]),
        ("redream", vec![sp("saves", &c(vec![ex("redream", "saves")], &[]))]),
        // L'EEPROM et le disque dur sont dans le même dossier, et le disque est une image de 8 Go.
        ("xemu", vec![sp("systemMemory", &c(vec![], &["AppData/Roaming/xemu/xemu"])).label("Mémoire système (EEPROM)").excluding(&["xbox_hdd.qcow2", "xbox_hdd.img"])]),
        ("xenia", vec![sp("saves", &c(vec![ex("xenia", "content")], &["Documents/Xenia/content"]))]),
        ("mame", vec![
            sp("systemMemory", &c(vec![ex("mame", "nvram")], &[])).slug("nvram", "Mémoire des bornes (NVRAM)"),
            sp("states", &c(vec![ex("mame", "sta")], &[])),
        ]),
        ("retroarch", vec![
            sp("saves", &c(vec![ex("retroarch", "saves")], &["AppData/Roaming/RetroArch/saves"])),
            sp("states", &c(vec![ex("retroarch", "states")], &["AppData/Roaming/RetroArch/states"])),
        ]),
        ("uzdoom", vec![sp("saves", &c(vec![ex("uzdoom", "save")], &["Saved Games/UZDoom", "Documents/My Games/UZDoom"])).only(&["zds"])]),
        ("gzdoom", vec![sp("saves", &c(vec![ex("gzdoom", "save")], &["Saved Games/GZDoom", "Documents/My Games/GZDoom"])).only(&["zds"])]),
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
    let full: PathBuf = if let Some(r) = c.strip_prefix("{prefixes}") { prefixes.join(r.trim_start_matches(['/', '\\'])) } else { home().join(c) };
    let mut found = vec![(PathBuf::new(), String::new())];
    for comp in full.components() {
        let part = comp.as_os_str().to_string_lossy().to_string();
        if part == "*" {
            let mut next = vec![];
            for (p, _) in &found {
                let Ok(rd) = std::fs::read_dir(p) else { continue };
                for e in rd.flatten() { let n = e.file_name().to_string_lossy().to_string(); if !n.starts_with('.') && is_dir(&e.path()) { next.push((e.path(), n)); } }
            }
            found = next;
        } else { for f in found.iter_mut() { f.0.push(comp); } }
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
                let p = if Path::new(&v).is_absolute() { PathBuf::from(v) } else { home().join(&i.relative_to).join(v) };
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

pub fn hostname() -> String { std::env::var("COMPUTERNAME").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "windows".into()) }

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
