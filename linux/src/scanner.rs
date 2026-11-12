//! Parcourt les dossiers de ROM et les applications installées.
//!
//! Deux choses compliquent « lister chaque fichier » : les images de disque
//! viennent avec des pistes qui ne doivent pas apparaître comme des jeux, et une
//! extension comme `.iso` appartient à six consoles — c'est le dossier qui
//! tranche. Traduction de RomScanner.swift et SwitchTitle.swift ; les
//! applications sont lues dans les fichiers .desktop (Flatpak compris).

use crate::catalog::{self, Item, Kind, System};
use std::collections::{HashMap, HashSet};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

/// Tri naturel (« Proton 10 » après « Proton 9 »).
pub fn natural(a: &str, b: &str) -> std::cmp::Ordering {
    fn key(s: &str) -> Vec<(u8, u64, String)> {
        let mut out = vec![];
        let mut num = String::new();
        for c in s.to_lowercase().chars() {
            if c.is_ascii_digit() { num.push(c); continue; }
            if !num.is_empty() { out.push((0, num.parse().unwrap_or(0), String::new())); num.clear(); }
            out.push((1, 0, c.to_string()));
        }
        if !num.is_empty() { out.push((0, num.parse().unwrap_or(0), String::new())); }
        out
    }
    key(a).cmp(&key(b))
}

fn fnv(t: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in t.bytes() { h = (h ^ b as u64).wrapping_mul(0x100000001b3); }
    let mut n = h;
    let digits = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut s = vec![];
    loop { s.push(digits[(n % 36) as usize]); n /= 36; if n == 0 { break; } }
    s.reverse();
    String::from_utf8(s).unwrap()
}
pub fn hash(t: &str) -> String { fnv(t) }

/// Nom du fichier et taille, jamais le dossier : une bibliothèque déplacée reste la même.
pub fn identifier(p: &Path, size: Option<u64>) -> String {
    let size = size.unwrap_or_else(|| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0));
    fnv(&format!("{}:{size}", p.file_name().unwrap_or_default().to_string_lossy().to_lowercase()))
}

const SKIPPED: &[&str] = &["firmware", "keys", "prod.keys", "bios", "system", "systems", "saves", "savestates", "states", "cheats", "screenshots", "manuals",
    "covers", "artwork", "media", "themes", "cores", "logs", "playlists", "updates", "update", "dlc", "patches", "mods", "config", "cache", "__macosx", "assets",
    "shaders", "overlays", "thumbnails", "temp", "fabs", "prefabs", "addons", "modules", "presets", "engines", "tools", "language", "ports", "docs", "licenses",
    "theme", "scripts", "save", "log", "biblijeu sauvegardes", "lost+found", ".trash-1000", "lib", "lib64", "libs"];

/// Dossiers de travail : « .noindex », « _build » de nxnative, « .partial » en cours d'écriture.
pub fn is_work_folder(n: &str) -> bool { n.ends_with(".noindex") || n.ends_with("_build") || n.ends_with(".partial") }

const NOISE: &[&str] = &["unins", "setup", "install", "vcredist", "dxsetup", "dxwebsetup", "directx", "crashreport", "crashhandler", "updater", "update",
    "redist", "config", "settings", "readme", "uninstall", "activation", "unitycrashhandler", "launcherhelper", "bssndrpt", "crashpad", "reporter",
    "easyanticheat", "eac_launcher", "battleye", "beservice", "quicksfv", "dxdiag", "vc_redist", "dotnet", "physx", "oalinst", "ue4prereq", "uninst"];
const TRACKS: &[&str] = &["bin", "img", "raw", "wav", "mp3", "ape", "flac", "sub", "ccd", "mds", "ecm"];
const SHEETS: &[&str] = &["cue", "gdi", "m3u", "toc"];
const EVERYDAY: &[&str] = &["md", "bin", "img", "gz", "elf", "raw", "dat", "txt", "sub", "wav", "mp3", "flac", "ape", "zip", "7z", "bat", "lnk", "msi", "sh", "x86_64", "pkg"];

fn excluded(p: &str, ex: &[String]) -> bool { ex.iter().any(|e| p == e || p.starts_with(&format!("{e}/"))) }

/// Un changement signalé dans un dossier que l'analyse n'explore jamais ne relance rien.
pub fn ignores_change(p: &str, roots: &[String], ex: &[String]) -> bool {
    if excluded(p, ex) { return true; }
    let Some(root) = roots.iter().find(|r| p.starts_with(&format!("{r}/"))) else { return false };
    let inner: Vec<String> = p[root.len() + 1..].split('/').map(|s| s.to_lowercase()).collect();
    inner[..inner.len().saturating_sub(1)].iter().any(|x| SKIPPED.contains(&x.as_str()) || is_work_folder(x) || x.starts_with('.'))
}

fn head(p: &Path, n: usize) -> Vec<u8> {
    use std::io::Read;
    let mut b = vec![0u8; n];
    match std::fs::File::open(p).and_then(|mut f| f.read(&mut b)) { Ok(k) => { b.truncate(k); b } Err(_) => vec![] }
}
pub fn is_elf(p: &Path) -> bool { head(p, 4) == [0x7f, b'E', b'L', b'F'] }

/// Switch : seulement le jeu de base, pas ses mises à jour ni ses DLC.
fn switch_title_id(p: &Path) -> Option<u64> {
    let h = head(p, 16);
    if h.len() == 16 && &h[..4] == b"PFS0" {
        let count = u32::from_le_bytes(h[4..8].try_into().ok()?) as usize;
        let ts = u32::from_le_bytes(h[8..12].try_into().ok()?) as usize;
        if count > 0 && count < 4096 && ts < (1 << 20) {
            let all = head(p, 16 + count * 0x18 + ts);
            if all.len() == 16 + count * 0x18 + ts {
                let table = &all[16..];
                let names = &table[count * 0x18..];
                for i in 0..count {
                    let off = u32::from_le_bytes(table[i * 0x18 + 0x10..i * 0x18 + 0x14].try_into().ok()?) as usize;
                    if off >= names.len() { continue; }
                    let end = names[off..].iter().position(|&c| c == 0).map(|x| x + off).unwrap_or(names.len());
                    let n = String::from_utf8_lossy(&names[off..end]);
                    if n.len() == 36 && n.ends_with(".tik") { return u64::from_str_radix(&n[..16], 16).ok(); }
                }
            }
        }
    }
    let n = p.file_name()?.to_string_lossy().to_string();
    let i = n.find('[')?;
    let id = n.get(i + 1..i + 17)?;
    if n.get(i + 17..i + 18) == Some("]") { u64::from_str_radix(id, 16).ok() } else { None }
}
fn switch_base(p: &Path) -> bool { switch_title_id(p).map(|id| id & 0xfff == 0).unwrap_or(true) }

fn referenced(sheet: &Path) -> Vec<PathBuf> {
    let Ok(b) = std::fs::read(sheet) else { return vec![] };
    let text = String::from_utf8_lossy(&b);
    let dir = sheet.parent().unwrap_or(Path::new("/"));
    let ext = sheet.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    let mut names = vec![];
    for line in text.lines() {
        let l = line.trim();
        if l.is_empty() || l.starts_with('#') { continue; }
        let quoted = || { let a = l.find('"')?; let b = l[a + 1..].find('"')? + a + 1; Some(l[a + 1..b].to_string()) };
        if l.to_uppercase().starts_with("FILE ") { if let Some(q) = quoted() { names.push(q) } else { let parts: Vec<&str> = l[5..].trim().split(' ').collect(); if parts.len() > 1 { names.push(parts[..parts.len() - 1].join(" ")); } } }
        else if ext == "m3u" { names.push(l.to_string()); }
        else if ext == "gdi" { if let Some(q) = quoted() { names.push(q) } else { let p: Vec<&str> = l.split_whitespace().collect(); if p.len() >= 5 { names.push(p[4].into()); } } }
    }
    let mut seen = HashSet::new();
    names.into_iter().map(|n| dir.join(n)).filter(|p| seen.insert(p.clone()) && p.exists()).collect()
}

/// Ce que le jeu pèse vraiment : une feuille de pistes pèse cent octets, ses pistes 700 Mo.
fn game_size(p: &Path, declared: u64) -> u64 {
    let ext = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if !SHEETS.contains(&ext.as_str()) { return declared; }
    declared + referenced(p).iter().map(|r| std::fs::metadata(r).map(|m| m.len()).unwrap_or_else(|_| game_size(r, 0))).sum::<u64>()
}

fn tree_size(d: &Path, depth: u32) -> u64 {
    if depth > 12 { return 0; }
    std::fs::read_dir(d).map(|rd| rd.flatten().map(|e| { let p = e.path(); if p.is_dir() { tree_size(&p, depth + 1) } else { e.metadata().map(|m| m.len()).unwrap_or(0) } }).sum()).unwrap_or(0)
}

fn consoles_named_by(name: &str) -> Vec<&'static System> {
    let mut out: Vec<&System> = vec![];
    let mut parts = vec![name.to_string()];
    parts.extend(name.split([':', '&', '+', ',', '/']).map(|s| s.trim().to_string()).filter(|s| !s.is_empty() && s != name));
    for p in parts { if let Some(s) = catalog::system_for_folder(&p) { if !out.iter().any(|x| x.id == s.id) { out.push(s); } } }
    out
}

fn folder_hints(file: &Path, root: &Path) -> Vec<&'static System> {
    let mut dir = file.parent();
    while let Some(d) = dir {
        if !d.starts_with(root) { break; }
        let f = consoles_named_by(&d.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default());
        if !f.is_empty() { return f; }
        if d == root { break; }
        dir = d.parent();
    }
    consoles_named_by(&root.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default())
}

/// L'extension restreint, le dossier tranche entre les consoles qui la partagent.
fn resolve_system(file: &Path, ext: &str, root: &Path) -> Option<&'static System> {
    let cands = catalog::systems_for_ext(ext);
    let hints = folder_hints(file, root);
    if !hints.is_empty() { return hints.into_iter().find(|h| cands.iter().any(|c| c.id == h.id) || h.exts.contains(&ext)); }
    // Hors de tout dossier de console, seulement un format qui ne peut être que ça.
    if cands.len() != 1 || EVERYDAY.contains(&ext) { return None; }
    cands.into_iter().next()
}

fn mtime(m: &std::fs::Metadata) -> i64 { m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0) }

fn make_item(p: &Path, sys: &System, root: &Path, size: Option<u64>) -> Item {
    let parsed = catalog::parse_name(&p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default());
    let meta = std::fs::metadata(p).ok();
    let mut title = parsed.title.clone();
    // « Launcher.exe » : c'est le dossier qui porte le nom du jeu.
    if sys.id == "windows" || sys.id == "linux" {
        // Le dossier qui porte le nom du jeu : celui juste sous la racine, quand le
        // programme est rangé plus bas (« Jeu/Bin/Win64/jeu.exe »), sauf s'il nomme une console.
        let parent = p.parent().and_then(|d| d.file_name()).map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let top = p.strip_prefix(root).ok().and_then(|r| { let c: Vec<_> = r.components().collect(); (c.len() > 2).then(|| c[0].as_os_str().to_string_lossy().to_string()) })
            .filter(|t| catalog::system_for_folder(t).is_none());
        if let Some(t) = top { title = catalog::parse_name(&t).title; } else {
            let folder = catalog::parse_name(&parent).title;
            let generic = ["launcher", "start", "play", "game", "run"].contains(&title.to_lowercase().as_str());
            if generic || catalog::normalize(&folder).contains(&catalog::normalize(&title)) { title = folder; }
        }
    }
    let declared = meta.as_ref().map(|m| m.len()).unwrap_or(0);
    Item {
        id: identifier(p, Some(declared)), kind: if sys.id == "linux" || sys.id == "windows" { Kind::Game } else { Kind::Rom }, sort_title: catalog::normalize(&title), title,
        system: sys.id.into(), path: p.to_path_buf(), discs: vec![], region: parsed.region, languages: parsed.languages, tags: parsed.tags,
        size: size.unwrap_or_else(|| game_size(p, declared)), added: meta.as_ref().map(mtime).unwrap_or(0), source_root: Some(root.to_string_lossy().into()),
        raw_name: parsed.raw, local_art: None, steam_id: None, desktop_exec: None, version: None, emulator_id: None,
    }
}

struct F { name: String, path: PathBuf, ext: String, meta: std::fs::Metadata }

fn plausible_exe(p: &Path, dir: &Path) -> bool {
    let n = p.file_stem().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
    if NOISE.iter().any(|w| n.starts_with(w) || n.contains(w)) { return false; }
    let parent = dir.file_name().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
    ["launcher", "start", "play"].contains(&n.as_str()) || n.contains("game") || parent.contains(&n) || n.contains(&parent) || n.len() > 3
}

fn score_launcher(p: &Path, folder: &str) -> i32 {
    let n = catalog::normalize(&p.file_name().unwrap_or_default().to_string_lossy().to_lowercase().trim_end_matches(".exe").trim_end_matches(".x86_64").trim_end_matches(".sh").to_string());
    if n == folder { 100 } else if ["launcher", "start", "play", "game", "run"].contains(&n.as_str()) { 90 } else if folder.contains(&n) || n.contains(folder) { 80 } else { 10 }
}

/// Le programme qui lance le jeu installé dans ce dossier (Windows ou Linux), s'il en est un.
fn installed_launcher(dir: &Path, files: &[F]) -> Option<(PathBuf, &'static str)> {
    let folder = catalog::normalize(&dir.file_name().unwrap_or_default().to_string_lossy());
    let exes: Vec<&F> = files.iter().filter(|f| f.ext == "exe").collect();
    if !exes.is_empty() {
        let mut cand: Vec<&F> = exes.iter().copied().filter(|f| plausible_exe(&f.path, dir)).collect();
        if cand.is_empty() { return if exes.len() > 2 { Some((exes[0].path.clone(), "windows")) } else { None }; }
        // À égalité, le plus gros : c'est le jeu, pas un outil posé à côté.
        cand.sort_by(|a, b| score_launcher(&b.path, &folder).cmp(&score_launcher(&a.path, &folder)).then(b.meta.len().cmp(&a.meta.len())));
        return Some((cand[0].path.clone(), "windows"));
    }
    // Un jeu Linux : un programme ELF exécutable (ou un .x86_64, un start.sh) à la racine.
    // Une AppImage, elle, est un jeu à elle seule : elle ne désigne pas son dossier.
    let mut natives: Vec<&F> = files.iter().filter(|f| {
        let l = f.name.to_lowercase();
        f.meta.is_file() && f.meta.permissions().mode() & 0o111 != 0 && !l.contains(".so") && !l.ends_with(".dll") && !l.ends_with(".py") && !l.ends_with(".pl")
            && (l.ends_with(".x86_64") || (l.ends_with(".sh") && ["start", "run", "launch"].iter().any(|w| l.starts_with(w))) || (!l.contains('.') && is_elf(&f.path)))
            && !NOISE.iter().any(|w| l.contains(w))
    }).collect();
    if natives.is_empty() { return None; }
    natives.sort_by(|a, b| score_launcher(&b.path, &folder).cmp(&score_launcher(&a.path, &folder)).then(b.meta.len().cmp(&a.meta.len())));
    Some((natives[0].path.clone(), "linux"))
}

fn games_in(dir: &Path, files: &[F], root: &Path) -> Vec<Item> {
    let exts: HashSet<&str> = files.iter().map(|f| f.ext.as_str()).collect();
    let playlist = exts.contains("m3u");
    let sheet = SHEETS.iter().any(|e| exts.contains(e));
    let mut out = vec![];
    for f in files {
        let e = f.ext.as_str();
        if e.is_empty() || !catalog::ALL_EXTS.contains(e) { continue; }
        if playlist && e != "m3u" && (SHEETS.contains(&e) || TRACKS.contains(&e)) { continue; }
        if sheet && TRACKS.contains(&e) { continue; }
        if ["exe", "msi", "bat", "lnk"].contains(&e) && !plausible_exe(&f.path, dir) { continue; }
        // Un .zip n'est un jeu d'arcade que là où le dossier le dit.
        if (e == "zip" || e == "7z") && folder_hints(&f.path, root).first().map(|s| s.id) != Some("arcade") { continue; }
        if e == "sh" && f.meta.permissions().mode() & 0o111 == 0 { continue; }
        if f.name.starts_with("._") { continue; }
        let Some(s) = resolve_system(&f.path, e, root) else { continue };
        if s.id == "switch" && !switch_base(&f.path) { continue; }
        out.push(make_item(&f.path, s, root, None));
    }
    out
}

fn scan_root(root: &Path, ex: &[String], progress: &dyn Fn(String)) -> Vec<Item> {
    let mut items = vec![];
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        let (mut files, mut subdirs) = (vec![], vec![]);
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') { continue; }
            let p = e.path();
            let Ok(meta) = std::fs::metadata(&p) else { continue };
            if meta.is_dir() {
                let n = name.to_lowercase();
                if SKIPPED.contains(&n.as_str()) || is_work_folder(&n) || excluded(&p.to_string_lossy(), ex) { continue; }
                if SKIPPED.iter().any(|s| n.starts_with(&format!("{s} ")) || n.ends_with(&format!(" {s}"))) { continue; }
                subdirs.push(p);
            } else {
                let ext = p.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
                files.push(F { name, path: p, ext, meta });
            }
        }
        progress(format!("Analyse de {}…", dir.file_name().unwrap_or_default().to_string_lossy()));
        // Un jeu installé est tout un arbre autour d'un lanceur : on indexe le lanceur et on s'arrête.
        if dir != root {
            if let Some((l, sys)) = installed_launcher(&dir, &files) { items.push(make_item(&l, catalog::system(sys).unwrap(), root, Some(tree_size(&dir, 0)))); continue; }
        }
        stack.extend(subdirs);
        items.extend(games_in(&dir, &files, root));
    }
    items
}

/// « Final Fantasy VII (France) (Disc 1..3) » est un seul jeu à trois disques.
fn group_multi_disc(items: Vec<Item>) -> Vec<Item> {
    let mut groups: Vec<(String, Vec<(u32, Item)>)> = vec![];
    let mut out = vec![];
    for it in items {
        let disc = catalog::parse_name(&it.path.file_stem().unwrap_or_default().to_string_lossy()).disc;
        match disc {
            Some(d) if it.kind == Kind::Rom => {
                let key = format!("{}|{}|{}", it.path.parent().unwrap_or(Path::new("")).display(), it.system, catalog::normalized_core(&it.title));
                match groups.iter_mut().find(|g| g.0 == key) { Some(g) => g.1.push((d, it)), None => groups.push((key, vec![(d, it)])) }
            }
            _ => out.push(it),
        }
    }
    for (_, mut m) in groups {
        m.sort_by_key(|x| x.0);
        if m.len() == 1 { out.push(m.remove(0).1); continue; }
        let mut first = m[0].1.clone();
        first.discs = m.iter().map(|x| x.1.path.clone()).collect();
        first.size = m.iter().map(|x| x.1.size).sum();
        out.push(first);
    }
    out
}

pub fn scan_roms(roots: &[String], ex: &[String], progress: &dyn Fn(String)) -> Vec<Item> {
    let mut real: Vec<String> = ex.to_vec();
    for e in ex { if let Ok(r) = std::fs::canonicalize(e) { real.push(r.to_string_lossy().into()); } }
    let mut items = vec![];
    for r in roots {
        let root = Path::new(r);
        if !root.exists() || excluded(r, &real) { continue; }
        items.extend(scan_root(root, &real, progress));
    }
    group_multi_disc(items)
}

// ── Applications (.desktop) ───────────────────────────────────────────────

fn data_dirs() -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    let mut v = vec![std::env::var("XDG_DATA_HOME").map(PathBuf::from).unwrap_or(home.join(".local/share"))];
    v.extend(std::env::var("XDG_DATA_DIRS").unwrap_or("/usr/local/share:/usr/share".into()).split(':').map(PathBuf::from));
    v.push(home.join(".local/share/flatpak/exports/share"));
    v.push("/var/lib/flatpak/exports/share".into());
    let mut seen = HashSet::new();
    v.into_iter().filter(|p| seen.insert(p.clone())).collect()
}

pub fn parse_desktop(p: &Path) -> Option<HashMap<String, String>> {
    let t = std::fs::read_to_string(p).ok()?;
    let mut out = HashMap::new();
    let mut main = false;
    for l in t.lines() {
        if l.starts_with('[') { main = l.trim() == "[Desktop Entry]"; continue; }
        if !main { continue; }
        if let Some((k, v)) = l.split_once('=') { out.entry(k.trim().to_string()).or_insert(v.trim().to_string()); }
    }
    Some(out)
}

/// L'icône d'une application, d'après son nom dans le thème (la plus grande trouvée).
pub fn find_icon(name: &str) -> Option<PathBuf> {
    if name.is_empty() { return None; }
    if name.starts_with('/') { return Path::new(name).exists().then(|| PathBuf::from(name)); }
    let mut best: Option<(i32, PathBuf)> = None;
    for base in data_dirs() {
        for theme in ["hicolor", "breeze", "Adwaita"] {
            let Ok(rd) = std::fs::read_dir(base.join("icons").join(theme)) else { continue };
            for s in rd.flatten() {
                let size = if s.file_name() == "scalable" { 10000 } else { s.file_name().to_string_lossy().split('x').next().and_then(|x| x.parse().ok()).unwrap_or(0) };
                for ext in ["png", "svg"] {
                    let f = s.path().join("apps").join(format!("{name}.{ext}"));
                    if f.exists() && best.as_ref().map(|b| size > b.0).unwrap_or(true) { best = Some((size, f)); }
                }
            }
        }
        for ext in ["png", "svg"] { let f = base.join("pixmaps").join(format!("{name}.{ext}")); if best.is_none() && f.exists() { best = Some((0, f)); } }
    }
    best.map(|b| b.1)
}

pub struct Apps { pub games: Vec<Item>, pub emu_icons: HashMap<String, (PathBuf, Option<PathBuf>)> }

/// Les jeux (Categories=Game) et lanceurs installés, et les .desktop des émulateurs.
pub fn scan_applications() -> Apps {
    let launchers = ["com.heroicgameslauncher.hgl", "net.lutris.Lutris", "com.usebottles.bottles", "io.itch.itch", "com.hypixel.HytaleLauncher", "com.valvesoftware.Steam", "steam"];
    let not_games = ["big picture", "steam-runtime", "valve-", "steamvr", "proton", "protontricks", "winetricks", "gamemode", "mangohud", "controller", "piper",
        "solaar", "antimicrox", "sunshine", "moonlight", "protonplus", "pupgui", "dosbox-x-conf"];
    let mut games = vec![];
    let mut emu_icons = HashMap::new();
    let mut seen = HashSet::new();
    for base in data_dirs() {
        let Ok(rd) = std::fs::read_dir(base.join("applications")) else { continue };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if !n.ends_with(".desktop") || !seen.insert(n.clone()) { continue; }
            let Some(d) = parse_desktop(&e.path()) else { continue };
            let g = |k: &str| d.get(k).cloned().unwrap_or_default();
            if g("Type") != "Application" || g("NoDisplay") == "true" || g("Hidden") == "true" || g("Exec").is_empty() { continue; }
            let id = n.trim_end_matches(".desktop").to_string();
            let exec = g("Exec");
            // Les raccourcis que Steam crée pour ses jeux : Steam les connaît déjà.
            if exec.contains("steam://rungameid/") { continue; }
            let prog = exec.split_whitespace().next().unwrap_or("").rsplit('/').next().unwrap_or("").to_string();
            if let Some(em) = catalog::EMULATORS.iter().find(|em| em.flatpak.contains(&id.as_str()) || (!prog.is_empty() && em.bins.contains(&prog.as_str()))) {
                emu_icons.insert(em.id.to_string(), (e.path(), find_icon(&g("Icon"))));
                continue;
            }
            let cats: Vec<String> = g("Categories").split(';').map(String::from).collect();
            let name = if g("Name").is_empty() { id.clone() } else { g("Name") };
            let game = cats.iter().any(|c| c == "Game") && !cats.iter().any(|c| c == "Emulator");
            if !(game || launchers.iter().any(|l| id.starts_with(l))) { continue; }
            let lname = format!("{} {}", id.to_lowercase(), name.to_lowercase());
            if not_games.iter().any(|w| lname.contains(w)) || cats.iter().any(|c| c == "Settings" || c == "System") { continue; }
            let added = e.metadata().map(|m| mtime(&m)).unwrap_or(0);
            games.push(Item {
                id: fnv(&format!("desktop:{id}")), kind: Kind::Game, sort_title: catalog::normalize(&name), title: name.clone(), system: "linux".into(),
                path: e.path(), discs: vec![], region: None, languages: vec![], tags: vec![], size: 0, added, source_root: None, raw_name: name,
                local_art: find_icon(&g("Icon")), steam_id: None, desktop_exec: Some(exec), version: None, emulator_id: None,
            });
        }
    }
    Apps { games, emu_icons }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fx { root: PathBuf }
    impl Fx {
        fn new() -> Fx { let r = std::env::temp_dir().join(format!("bj-{}-{}", std::process::id(), crate::common::sys::now_ms() + rand())); std::fs::create_dir_all(&r).unwrap(); Fx { root: r } }
        fn file(&self, rel: &str, content: &[u8], mode: Option<u32>) { let p = self.root.join(rel); std::fs::create_dir_all(p.parent().unwrap()).unwrap(); std::fs::write(&p, content).unwrap(); if let Some(m) = mode { std::fs::set_permissions(&p, std::fs::Permissions::from_mode(m)).unwrap(); } }
        fn scan(&self, ex: &[String]) -> Vec<Item> { scan_roms(&[self.root.to_string_lossy().into()], ex, &|_| {}) }
    }
    fn rand() -> i64 { static N: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0); N.fetch_add(1000, std::sync::atomic::Ordering::SeqCst) }
    impl Drop for Fx { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.root); } }

    #[test]
    fn folder_decides() {
        let f = Fx::new();
        f.file("PS2/Shadow of the Colossus (Europe).iso", b"x", None);
        f.file("GameCube/Pikmin (Europe).iso", b"x", None);
        f.file("Wii/Zelda Twilight Princess.iso", b"x", None);
        let by: HashMap<String, String> = f.scan(&[]).into_iter().map(|i| (i.title, i.system)).collect();
        assert_eq!(by["Shadow of the Colossus"], "ps2");
        assert_eq!(by["Pikmin"], "gc");
        assert_eq!(by["Zelda Twilight Princess"], "wii");
    }
    #[test]
    fn ambiguous_and_unique() {
        let f = Fx::new();
        f.file("Something.iso", b"x", None);
        f.file("notes.md", b"x", None);
        f.file("Super Mario 64 (USA).z64", b"x", None);
        let i = f.scan(&[]);
        assert_eq!(i.len(), 1);
        assert_eq!(i[0].system, "n64");
    }
    #[test]
    fn sheets_and_discs() {
        let f = Fx::new();
        f.file("PS1/Tekken 3 (Europe).cue", b"FILE \"Tekken 3 (Europe) (Track 1).bin\" BINARY", None);
        f.file("PS1/Tekken 3 (Europe) (Track 1).bin", &[b'x'; 700], None);
        for d in 1..=3 { f.file(&format!("PS1/Final Fantasy VII (France) (Disc {d}).chd"), b"x", None); }
        let items = f.scan(&[]);
        assert_eq!(items.len(), 2);
        let t = items.iter().find(|i| i.title == "Tekken 3").unwrap();
        assert!(t.size >= 700);
        let ff = items.iter().find(|i| i.discs.len() == 3).unwrap();
        assert!(ff.discs[0].to_string_lossy().ends_with("(Disc 1).chd"));
    }
    #[test]
    fn skipped_folders_zip_and_windows() {
        let f = Fx::new();
        f.file("Switch/Updates/Game Update.nsp", b"x", None);
        f.file("Switch/0100ABCD_build/romfs.iso", b"x", None);
        f.file("N64/saves/Mario.z64", b"x", None);
        f.file("Downloads/emulator-source.zip", b"x", None);
        f.file("MAME/pacman.zip", b"x", None);
        f.file("PC/Obsidian Quest/ObsidianQuest.exe", b"x", None);
        f.file("PC/Obsidian Quest/unins000.exe", b"x", None);
        f.file("PC/Obsidian Quest/data/maps/level01.wad", b"x", None);
        let items = f.scan(&[]);
        let mut v: Vec<(String, String)> = items.iter().map(|i| (i.system.clone(), i.path.file_name().unwrap().to_string_lossy().into())).collect();
        v.sort();
        assert_eq!(v, vec![("arcade".into(), "pacman.zip".into()), ("windows".into(), "ObsidianQuest.exe".into())]);
    }
    #[test]
    fn linux_games() {
        let f = Fx::new();
        let mut elf = vec![0x7f, b'E', b'L', b'F']; elf.extend([0u8; 60]);
        f.file("Linux/Hollow Quest/HollowQuest", &elf, Some(0o755));
        f.file("Linux/Hollow Quest/libfoo.so", &elf, Some(0o755));
        f.file("Linux/Celeste.AppImage", b"x", Some(0o755));
        let mut names: Vec<String> = f.scan(&[]).iter().map(|i| i.path.file_name().unwrap().to_string_lossy().into()).collect();
        names.sort();
        assert_eq!(names, vec!["Celeste.AppImage", "HollowQuest"]);
    }
    #[test]
    fn excluded_and_changes() {
        let f = Fx::new();
        f.file("N64/._Super Mario 64.z64", b"x", None);
        f.file("N64/Mario.z64", b"x", None);
        f.file("Old/Zelda.z64", b"x", None);
        let old = f.root.join("Old").to_string_lossy().to_string();
        let t: Vec<String> = f.scan(&[old]).into_iter().map(|i| i.title).collect();
        assert_eq!(t, vec!["Mario"]);
        let roots = vec!["/media/roms".to_string()];
        assert!(ignores_change("/media/roms/Switch/0100_build/a/b.bin", &roots, &[]));
        assert!(ignores_change("/media/roms/N64/saves/mario.eep", &roots, &[]));
        assert!(!ignores_change("/media/roms/N64/Zelda.z64", &roots, &[]));
    }
}
