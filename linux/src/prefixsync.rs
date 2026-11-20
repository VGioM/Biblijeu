//! Les sauvegardes des jeux Windows ajoutés à Steam. Le jeu tourne dans le
//! préfixe que Steam lui a créé (compatdata/<numéro>), que Biblijeu le lance ou
//! que Steam le lance. Biblijeu en garde une copie de secours dans son propre
//! dossier de préfixes, synchronisée dans les deux sens : le fichier le plus
//! récent gagne. Retirer le jeu de Steam (et son compatdata) ne perd donc rien,
//! et un jeu joué avec Biblijeu avant d'être ajouté à Steam retrouve sa
//! progression dans le préfixe de Steam.
//!
//! Seul le dossier de l'utilisateur Windows (`drive_c/users/steamuser` :
//! Documents, AppData, Saved Games…) est synchronisé, sans les caches. Le reste
//! du préfixe (Windows, programmes installés) pèse lourd et se recrée.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const USER: &str = "pfx/drive_c/users/steamuser";

#[derive(Default, Debug)]
pub struct Report { pub to_steam: usize, pub to_copy: usize, pub full_copy: bool }

/// Synchronise le préfixe de Steam et la copie de Biblijeu.
pub fn sync(steam: &Path, mirror: &Path) -> Result<Report, String> {
    let mut r = Report::default();
    // Steam n'a encore rien lancé : il reçoit tout le préfixe de Biblijeu (programmes
    // installés dedans compris), Biblijeu garde le sien.
    if !steam.join("pfx/system.reg").exists() && mirror.join("pfx/system.reg").exists() {
        std::fs::create_dir_all(steam).map_err(|e| e.to_string())?;
        for e in std::fs::read_dir(mirror).map_err(|e| e.to_string())?.flatten() {
            let target = steam.join(e.file_name());
            if target.symlink_metadata().is_ok() { continue; }
            let ok = std::process::Command::new("cp").arg("-a").arg("--reflink=auto").arg(e.path()).arg(&target).status().map(|s| s.success()).unwrap_or(false);
            if !ok { let _ = std::fs::remove_dir_all(&target); return Err(format!("copie impossible de {}", e.path().display())); }
        }
        r.full_copy = true;
        return Ok(r);
    }
    let (a, b) = (steam.join(USER), mirror.join(USER));
    if !a.is_dir() && !b.is_dir() { return Ok(r); }
    let mut rels = vec![];
    list(&a, Path::new(""), &mut rels);
    list(&b, Path::new(""), &mut rels);
    rels.sort();
    rels.dedup();
    for rel in rels {
        let (pa, pb) = (a.join(&rel), b.join(&rel));
        let (ma, mb) = (mtime(&pa), mtime(&pb));
        // Deux secondes de marge : certains systèmes de fichiers arrondissent les dates.
        let newer = |x: SystemTime, y: Option<SystemTime>| y.map(|y| x > y + Duration::from_secs(2)).unwrap_or(true);
        match (ma, mb) {
            (Some(x), y) if newer(x, y) => { copy(&pa, &pb)?; r.to_copy += 1; }
            (x, Some(y)) if newer(y, x) => { copy(&pb, &pa)?; r.to_steam += 1; }
            _ => {}
        }
    }
    Ok(r)
}

/// Les fichiers sous `dir`, en chemins relatifs, sans les caches ni les liens.
fn list(root: &Path, rel: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(root.join(rel)) else { return };
    for e in rd.flatten() {
        let Ok(ft) = e.file_type() else { continue };
        if ft.is_symlink() { continue; }
        let name = e.file_name().to_string_lossy().to_lowercase();
        let r = rel.join(e.file_name());
        if ft.is_dir() {
            if name.contains("cache") || ["temp", "tmp", "crashdumps", "crashes", "logs", "d3dscache", "nvidia corporation"].contains(&name.as_str()) { continue; }
            list(root, &r, out);
        } else if ft.is_file() {
            out.push(r);
        }
    }
}

fn mtime(p: &Path) -> Option<SystemTime> { std::fs::symlink_metadata(p).ok().filter(|m| m.is_file()).and_then(|m| m.modified().ok()) }

/// Copie un fichier en gardant sa date, pour que la comparaison suivante le trouve à jour.
fn copy(from: &Path, to: &Path) -> Result<(), String> {
    if let Some(d) = to.parent() { std::fs::create_dir_all(d).map_err(|e| format!("{} : {e}", d.display()))?; }
    let tmp = to.with_extension("biblijeu-tmp");
    std::fs::copy(from, &tmp).map_err(|e| format!("{} : {e}", from.display()))?;
    if let Some(t) = mtime(from) { if let Ok(f) = std::fs::File::options().write(true).open(&tmp) { let _ = f.set_modified(t); } }
    std::fs::rename(&tmp, to).map_err(|e| format!("{} : {e}", to.display()))
}

/// Attend la fin du jeu (son .exe disparaît des processus), pour resynchroniser
/// juste après. Abandonne si le jeu n'apparaît jamais.
pub fn wait_for_exit(exe: &str) {
    let needle = exe.to_lowercase();
    let running = || std::fs::read_dir("/proc").map(|rd| rd.flatten().any(|e| {
        e.file_name().to_string_lossy().bytes().all(|b| b.is_ascii_digit())
            && std::fs::read(e.path().join("cmdline")).map(|b| String::from_utf8_lossy(&b).to_lowercase().replace('\\', "/").contains(&needle)).unwrap_or(false)
    })).unwrap_or(false);
    let start = std::time::Instant::now();
    let mut seen = false;
    let mut gone = 0;
    loop {
        std::thread::sleep(Duration::from_secs(10));
        if running() { seen = true; gone = 0; } else if seen { gone += 1; if gone >= 2 { return; } } else if start.elapsed() > Duration::from_secs(180) { return; }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn write(p: &Path, s: &str, age: u64) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
        let f = std::fs::File::options().write(true).open(p).unwrap();
        f.set_modified(SystemTime::now() - Duration::from_secs(age)).unwrap();
    }
    #[test]
    fn newest_wins_both_ways() {
        let t = std::env::temp_dir().join(format!("biblijeu-sync-{}", std::process::id()));
        let (steam, mirror) = (t.join("compatdata/1"), t.join("prefixes/jeu"));
        std::fs::create_dir_all(steam.join("pfx")).unwrap();
        std::fs::write(steam.join("pfx/system.reg"), "").unwrap();
        write(&steam.join(USER).join("Documents/save1"), "steam récent", 10);
        write(&mirror.join(USER).join("Documents/save1"), "biblijeu vieux", 1000);
        write(&steam.join(USER).join("AppData/Roaming/jeu/save2"), "steam vieux", 1000);
        write(&mirror.join(USER).join("AppData/Roaming/jeu/save2"), "biblijeu récent", 10);
        write(&mirror.join(USER).join("Saved Games/seulement-biblijeu"), "b", 10);
        write(&steam.join(USER).join("AppData/Local/ShaderCache/x"), "cache", 10);
        let r = sync(&steam, &mirror).unwrap();
        assert_eq!(std::fs::read_to_string(mirror.join(USER).join("Documents/save1")).unwrap(), "steam récent");
        assert_eq!(std::fs::read_to_string(steam.join(USER).join("AppData/Roaming/jeu/save2")).unwrap(), "biblijeu récent");
        assert!(steam.join(USER).join("Saved Games/seulement-biblijeu").exists());
        assert!(!mirror.join(USER).join("AppData/Local/ShaderCache/x").exists());
        assert_eq!((r.to_copy, r.to_steam), (1, 2));
        // Une deuxième passe n'a plus rien à faire.
        let r = sync(&steam, &mirror).unwrap();
        assert_eq!((r.to_copy, r.to_steam), (0, 0));
        let _ = std::fs::remove_dir_all(&t);
    }
    #[test]
    fn empty_steam_prefix_gets_full_copy() {
        let t = std::env::temp_dir().join(format!("biblijeu-sync2-{}", std::process::id()));
        let (steam, mirror) = (t.join("compatdata/1"), t.join("prefixes/jeu"));
        write(&mirror.join("pfx/system.reg"), "reg", 10);
        write(&mirror.join(USER).join("Documents/save"), "progression", 10);
        std::fs::create_dir_all(&steam).unwrap();
        assert!(sync(&steam, &mirror).unwrap().full_copy);
        assert_eq!(std::fs::read_to_string(steam.join(USER).join("Documents/save")).unwrap(), "progression");
        assert!(mirror.join(USER).join("Documents/save").exists());
        let _ = std::fs::remove_dir_all(&t);
    }
}
