//! Ce que le client Steam pour Windows sait : ses bibliothèques, les jeux
//! installés (lancés par Steam), les jeux ajoutés à la main et les jaquettes
//! déjà téléchargées. Traduction de Steam.swift.

use std::collections::HashMap;
use std::path::{Path, PathBuf};


/// Le dossier de Steam : celui que Steam écrit dans le registre
/// (HKCU\Software\Valve\Steam, SteamPath), sinon l'emplacement habituel.
pub fn root() -> Option<PathBuf> {
    let reg = crate::common::sys::clean_command("reg").args(["query", r"HKCU\Software\Valve\Steam", "/v", "SteamPath"]).output().ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).lines().find_map(|l| l.split_once("REG_SZ").map(|(_, v)| PathBuf::from(v.trim().replace('/', "\\")))));
    let env = |k: &str| std::env::var_os(k).map(|p| PathBuf::from(p).join("Steam"));
    reg.into_iter().chain([env("ProgramFiles(x86)"), env("ProgramFiles")].into_iter().flatten())
        .find(|p| p.join("steamapps").exists())
}

/// Toutes les valeurs écrites `"clé"  "valeur"` dans un fichier VDF ou ACF.
pub fn values(key: &str, text: &str) -> Vec<String> {
    let mut out = vec![];
    let needle = format!("\"{}\"", key.to_lowercase());
    let lower = text.to_lowercase();
    let mut from = 0;
    while let Some(i) = lower[from..].find(&needle) {
        let start = from + i + needle.len();
        let rest = &text[start..];
        let t = rest.trim_start_matches([' ', '\t']);
        if let Some(body) = t.strip_prefix('"') {
            let mut v = String::new();
            let mut esc = false;
            for c in body.chars() {
                if esc { v.push(c); esc = false; } else if c == '\\' { esc = true; } else if c == '"' { break; } else { v.push(c); }
            }
            out.push(v);
        }
        from = start;
    }
    out
}

/// Chaque dossier steamapps, celui par défaut d'abord.
pub fn libraries() -> Vec<PathBuf> {
    let Some(r) = root() else { return vec![] };
    let main = r.join("steamapps");
    let mut out = vec![main.clone()];
    if let Ok(t) = std::fs::read_to_string(main.join("libraryfolders.vdf")) {
        for p in values("path", &t) {
            let s = PathBuf::from(p).join("steamapps");
            let real = std::fs::canonicalize(&s).unwrap_or(s.clone());
            if !out.iter().any(|x| std::fs::canonicalize(x).unwrap_or(x.clone()) == real) { out.push(s); }
        }
    }
    out.into_iter().filter(|p| p.exists()).collect()
}

pub struct Game { pub app_id: u64, pub name: String, pub folder: PathBuf }

const TOOLS: &[&str] = &["redistributable", "steamworks", "steam linux runtime", "proton", "steamvr", "steamlinuxruntime"];

/// Les jeux entièrement installés, sans les runtimes que Steam installe avec.
pub fn installed_games() -> Vec<Game> {
    let mut out = vec![];
    for lib in libraries() {
        let Ok(rd) = std::fs::read_dir(&lib) else { continue };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if !(n.starts_with("appmanifest_") && n.ends_with(".acf")) { continue; }
            let Ok(t) = std::fs::read_to_string(e.path()) else { continue };
            let (Some(id), Some(name), Some(dir), Some(flags)) = (values("appid", &t).first().and_then(|x| x.parse().ok()), values("name", &t).first().cloned(),
                values("installdir", &t).first().cloned(), values("StateFlags", &t).first().and_then(|x| x.parse::<u64>().ok())) else { continue };
            if flags & 4 == 0 || TOOLS.iter().any(|w| name.to_lowercase().contains(w)) { continue; }
            let folder = lib.join("common").join(dir);
            if folder.exists() { out.push(Game { app_id: id, name, folder }); }
        }
    }
    out
}

// ── Jeux ajoutés à la main ────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum Vdf { Table(HashMap<String, Vdf>), Str(String), Int(u32) }

/// Les clés-valeurs binaires de Valve, le format de shortcuts.vdf.
pub fn parse_binary_vdf(b: &[u8]) -> HashMap<String, Vdf> {
    fn s(b: &[u8], i: &mut usize) -> Option<String> {
        let end = b[*i..].iter().position(|&c| c == 0)? + *i;
        let v = String::from_utf8_lossy(&b[*i..end]).to_string();
        *i = end + 1;
        Some(v)
    }
    fn table(b: &[u8], i: &mut usize) -> Option<HashMap<String, Vdf>> {
        let mut out = HashMap::new();
        while *i < b.len() {
            let t = b[*i];
            *i += 1;
            if t == 8 { return Some(out); }
            let k = s(b, i)?;
            match t {
                0 => { out.insert(k, Vdf::Table(table(b, i)?)); }
                1 => { out.insert(k, Vdf::Str(s(b, i)?)); }
                2 => { if *i + 4 > b.len() { return None; } out.insert(k, Vdf::Int(u32::from_le_bytes(b[*i..*i + 4].try_into().ok()?))); *i += 4; }
                _ => return None,
            }
        }
        Some(out)
    }
    let mut i = 0;
    table(b, &mut i).unwrap_or_default()
}

pub struct Shortcut { pub game_id: String, pub name: String, pub exe: PathBuf, pub user: PathBuf, pub short_id: u32 }

pub fn shortcuts() -> Vec<Shortcut> {
    let Some(r) = root() else { return vec![] };
    let mut out = vec![];
    let mut seen = std::collections::HashSet::new();
    let Ok(rd) = std::fs::read_dir(r.join("userdata")) else { return out };
    for u in rd.flatten() {
        if u.file_name().to_string_lossy().parse::<u64>().is_err() { continue; }
        let Ok(data) = std::fs::read(u.path().join("config/shortcuts.vdf")) else { continue };
        let Some(Vdf::Table(list)) = parse_binary_vdf(&data).remove("shortcuts") else { continue };
        for entry in list.values() {
            let Vdf::Table(e) = entry else { continue };
            let f = |k: &str| e.iter().find(|(x, _)| x.eq_ignore_ascii_case(k)).map(|(_, v)| v.clone());
            let (Some(Vdf::Int(id)), Some(Vdf::Str(name)), Some(Vdf::Str(exe))) = (f("appid"), f("AppName"), f("Exe")) else { continue };
            if name.is_empty() || exe.is_empty() || matches!(f("IsHidden"), Some(Vdf::Int(h)) if h != 0) { continue; }
            // Ce que Steam ouvre : l'identifiant du raccourci en haut, la marque « raccourci » en bas.
            let game_id = ((id as u64) << 32 | 0x0200_0000).to_string();
            if !seen.insert(game_id.clone()) { continue; }
            out.push(Shortcut { game_id, name, exe: PathBuf::from(exe.trim_matches(|c| c == '"' || c == ' ')), user: u.path(), short_id: id });
        }
    }
    out
}

// ── Jaquettes ─────────────────────────────────────────────────────────────

fn find_file(dir: &Path, names: &[&str], depth: u32) -> Option<PathBuf> {
    if depth > 2 { return None; }
    let rd: Vec<_> = std::fs::read_dir(dir).ok()?.flatten().collect();
    if let Some(e) = rd.iter().find(|e| e.path().is_file() && names.contains(&e.file_name().to_string_lossy().as_ref())) { return Some(e.path()); }
    rd.iter().filter(|e| e.path().is_dir()).find_map(|e| find_file(&e.path(), names, depth + 1))
}

/// La jaquette que Steam a déjà téléchargée pour sa propre bibliothèque.
pub fn cover(app_id: u64) -> Option<PathBuf> {
    let cache = root()?.join("appcache/librarycache");
    let flat = cache.join(format!("{app_id}_library_600x900.jpg"));
    if flat.exists() { return Some(flat); }
    find_file(&cache.join(app_id.to_string()), &["library_600x900.jpg", "library_capsule.jpg"], 0)
}

pub fn shortcut_cover(s: &Shortcut) -> Option<PathBuf> {
    ["png", "jpg"].iter().map(|e| s.user.join(format!("config/grid/{}p.{e}", s.short_id))).find(|p| p.exists())
}

// ── Proton ────────────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct Proton { pub name: String, pub dir: PathBuf }

/// Pas de Proton sous Windows : les jeux s'y lancent tels quels.
pub fn protons() -> Vec<Proton> { vec![] }

/// Pas de Steam Linux Runtime sous Windows.
pub fn sniper() -> Option<PathBuf> { None }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn binary_vdf() {
        let mut b = vec![0u8];
        b.extend(b"shortcuts\0");
        b.push(0); b.extend(b"0\0");
        b.push(2); b.extend(b"appid\0"); b.extend(123456u32.to_le_bytes());
        b.push(1); b.extend(b"AppName\0"); b.extend("Mon Jeu".as_bytes()); b.push(0);
        b.extend([8, 8, 8]);
        let v = parse_binary_vdf(&b);
        let Some(Vdf::Table(s)) = v.get("shortcuts") else { panic!() };
        let Some(Vdf::Table(e)) = s.get("0") else { panic!() };
        assert_eq!(e.get("appid"), Some(&Vdf::Int(123456)));
        assert_eq!(e.get("AppName"), Some(&Vdf::Str("Mon Jeu".into())));
    }
    #[test]
    fn text_vdf() {
        assert_eq!(values("path", "\"0\"\n{\n\t\"path\"\t\t\"/home/x/Steam\"\n}\n\"1\" { \"path\" \"/mnt/Lib\" }"), vec!["/home/x/Steam", "/mnt/Lib"]);
    }
}
