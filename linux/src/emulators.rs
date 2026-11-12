//! Trouver les émulateurs installés et construire la commande qui démarre un
//! jeu. Un émulateur est cherché en Flatpak, dans le PATH puis parmi les
//! AppImage des dossiers d'applications. Les jeux Windows passent par un Proton
//! installé par Steam, lancé par umu-run quand il est là, avec un préfixe par jeu.

use crate::catalog::{self, Emulator, Item, Kind, ResumeReq};
use crate::common::sys;
use crate::steam;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};


#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum How { Flatpak, Native, AppImage, Proton }

#[derive(Clone, Debug)]
pub struct Installed {
    pub spec: &'static Emulator, pub how: How, pub target: Option<String>, pub version: Option<String>, pub installation: Option<String>,
}
impl Installed {
    pub fn id(&self) -> &'static str { self.spec.id }
    pub fn name(&self) -> &'static str { self.spec.name }
    pub fn how_label(&self) -> &'static str { match self.how { How::Flatpak => "Flatpak", How::Native => "Paquet", How::AppImage => "AppImage", How::Proton => "Steam" } }
}

pub struct FlatpakApp { pub version: Option<String>, pub installation: String }

/// Les applications Flatpak installées.
pub fn flatpak_apps() -> HashMap<String, FlatpakApp> {
    let mut apps = HashMap::new();
    if sys::which("flatpak").is_none() { return apps; }
    let Ok(out) = sys::clean_command("flatpak").args(["list", "--app", "--columns=application,version,installation"]).output() else { return apps };
    for l in String::from_utf8_lossy(&out.stdout).lines() {
        let mut p = l.split('\t');
        let id = p.next().unwrap_or("").trim();
        if id.is_empty() { continue; }
        let v = p.next().unwrap_or("").trim();
        let inst = p.next().unwrap_or("").trim();
        apps.insert(id.to_string(), FlatpakApp { version: (!v.is_empty()).then(|| v.into()), installation: if inst.is_empty() { "system".into() } else { inst.into() } });
    }
    apps
}

/// Les AppImage des dossiers d'applications, jusqu'à trois niveaux.
pub fn appimages(folders: &[String]) -> Vec<PathBuf> {
    fn walk(d: &Path, depth: u32, out: &mut Vec<PathBuf>) {
        let Ok(rd) = std::fs::read_dir(d) else { return };
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            let p = e.path();
            if p.is_dir() { if depth < 3 && !n.starts_with('.') { walk(&p, depth + 1, out); } }
            else if n.to_lowercase().ends_with(".appimage") { out.push(p); }
        }
    }
    let mut out = vec![];
    for f in folders { walk(Path::new(f), 0, &mut out); }
    out
}

pub fn version_from_name(n: &str) -> Option<String> {
    let re = fancy_regex::Regex::new(r"(\d+(?:\.\d+){1,3})").ok()?;
    re.captures(n).ok().flatten().map(|c| c[1].to_string())
}

/// Les émulateurs présents, chacun sous sa première forme trouvée : Flatpak, paquet, AppImage.
pub fn detect(app_folders: &[String]) -> Vec<Installed> {
    let flat = flatpak_apps();
    let images = appimages(app_folders);
    let mut found = vec![];
    for spec in catalog::EMULATORS {
        if spec.id == "proton" {
            let n = steam::protons().len();
            if n > 0 { found.push(Installed { spec, how: How::Proton, target: None, version: Some(format!("{n} version{}", if n > 1 { "s" } else { "" })), installation: None }); }
            continue;
        }
        if let Some(fid) = spec.flatpak.iter().find(|id| flat.contains_key(**id)) {
            let a = &flat[*fid];
            found.push(Installed { spec, how: How::Flatpak, target: Some(fid.to_string()), version: a.version.clone(), installation: Some(a.installation.clone()) });
            continue;
        }
        if let Some(b) = spec.bins.iter().find_map(|b| sys::which(b)) {
            found.push(Installed { spec, how: How::Native, target: Some(b.to_string_lossy().into()), version: None, installation: None });
            continue;
        }
        if let Some(pat) = spec.appimage {
            if let Some(img) = images.iter().find(|p| p.file_name().unwrap_or_default().to_string_lossy().to_lowercase().contains(pat)) {
                let n = img.file_name().unwrap_or_default().to_string_lossy().to_string();
                found.push(Installed { spec, how: How::AppImage, target: Some(img.to_string_lossy().into()), version: version_from_name(&n), installation: None });
            }
        }
    }
    found
}

// ── RetroArch ─────────────────────────────────────────────────────────────

fn ra_cores(sys: &str) -> &'static [&'static str] {
    match sys {
        "nes" => &["mesen", "nestopia", "fceumm"], "snes" => &["snes9x", "bsnes"], "n64" => &["mupen64plus_next", "parallel_n64"],
        "gb" | "gbc" => &["gambatte", "mgba", "sameboy"], "gba" => &["mgba", "vba_next"], "nds" => &["melonds", "desmume"], "vb" => &["mednafen_vb"],
        "ps1" => &["swanstation", "mednafen_psx_hw", "pcsx_rearmed"], "psp" => &["ppsspp"], "genesis" => &["genesis_plus_gx", "picodrive"],
        "mastersystem" => &["genesis_plus_gx", "smsplus"], "gamegear" => &["genesis_plus_gx"], "sega32x" => &["picodrive"],
        "saturn" => &["mednafen_saturn", "yabasanshiro"], "dreamcast" => &["flycast"], "pcengine" => &["mednafen_pce_fast", "mednafen_pce"],
        "neogeo" => &["fbneo"], "ngp" => &["mednafen_ngp"], "wonderswan" => &["mednafen_wswan"], "lynx" => &["handy", "mednafen_lynx"],
        "atari2600" => &["stella"], "3do" => &["opera"], "arcade" => &["fbneo", "mame"], "amiga" => &["puae"], "c64" => &["vice_x64sc"],
        "doom" => &["prboom"], "dos" => &["dosbox_pure"], _ => &[],
    }
}

pub fn retroarch_core(sys: &str, inst: &Installed) -> Option<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    let mut dirs = vec![home.join(".config/retroarch/cores"), "/usr/lib/libretro".into(), "/usr/lib64/libretro".into(), "/usr/lib/x86_64-linux-gnu/libretro".into()];
    if inst.how == How::Flatpak { dirs.insert(0, home.join(".var/app/org.libretro.RetroArch/config/retroarch/cores")); }
    ra_cores(sys).iter().find_map(|n| dirs.iter().map(|d| d.join(format!("{n}_libretro.so"))).find(|f| f.exists()))
}

/// Une console tourne si un émulateur installé la prend (RetroArch : s'il a le cœur).
pub fn runs(inst: &Installed, sys: &str) -> bool {
    if inst.spec.id == "retroarch" { inst.spec.runs(sys) && retroarch_core(sys, inst).is_some() } else { inst.spec.runs(sys) }
}

// ── Commande ──────────────────────────────────────────────────────────────

pub fn common_dir(files: &[String]) -> String {
    let parent = |f: &str| Path::new(f).parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
    let mut parts: Vec<String> = parent(&files[0]).split('/').map(String::from).collect();
    for f in &files[1..] {
        let q: Vec<String> = parent(f).split('/').map(String::from).collect();
        let i = parts.iter().zip(&q).take_while(|(a, b)| a == b).count();
        parts.truncate(i);
    }
    let s = parts.join("/");
    if s.is_empty() { "/".into() } else { s }
}

pub fn q(s: &str) -> String {
    if s.chars().any(|c| c.is_whitespace() || "'\"$".contains(c)) {
        let mut o = String::from("\"");
        for c in s.chars() { if "\"$`\\".contains(c) { o.push('\\'); } o.push(c); }
        o.push('"');
        o
    } else { s.into() }
}

pub fn slug(s: &str) -> String {
    let n: String = catalog::normalize(s).replace(' ', "-").chars().take(60).collect();
    if n.is_empty() { "jeu".into() } else { n }
}

/// « Exec » d'un .desktop, sans ses codes de champ (%f, %U…).
pub fn desktop_argv(exec: &str) -> Vec<String> {
    let mut argv = vec![];
    let (mut cur, mut quote, mut had) = (String::new(), false, false);
    let mut it = exec.chars().peekable();
    while let Some(c) = it.next() {
        if c == '"' { quote = !quote; had = true; continue; }
        if c == '\\' && quote { if let Some(n) = it.next() { cur.push(n); } continue; }
        if c == ' ' && !quote { if !cur.is_empty() || had { argv.push(std::mem::take(&mut cur)); } had = false; continue; }
        cur.push(c);
    }
    if !cur.is_empty() || had { argv.push(cur); }
    argv.into_iter().filter(|a| !(a.len() == 2 && a.starts_with('%') && "fFuUdDnNickvm".contains(&a[1..]))).map(|a| a.replace("%%", "%")).collect()
}

#[derive(Debug, Clone)]
pub enum Plan {
    Run { argv: Vec<String>, env: Vec<(String, String)>, cwd: PathBuf, preview: String, chmod: bool },
    Url(String),
    Open(PathBuf),
    Error(String),
}
impl Plan {
    pub fn preview(&self) -> String {
        match self { Plan::Run { preview, .. } => preview.clone(), Plan::Url(u) => format!("steam {u}"), Plan::Open(p) => format!("xdg-open {}", q(&p.to_string_lossy())), Plan::Error(e) => e.clone() }
    }
}

pub struct Opts<'a> { pub emulator: Option<&'a Installed>, pub direct: bool, pub disc: Option<PathBuf>, pub resume: ResumeReq, pub proton: Option<String>, pub prefixes: PathBuf }

pub fn pick_proton(wanted: Option<&str>) -> Option<steam::Proton> {
    let b = steam::protons();
    b.iter().find(|p| Some(p.name.as_str()) == wanted).or_else(|| b.iter().find(|p| p.name == "Proton - Experimental")).or(b.first()).cloned()
}

pub fn prefix_for(item: &Item, root: &Path) -> PathBuf { root.join(slug(&item.title)) }

fn proton_plan(exe: &Path, proton: &steam::Proton, prefix: &Path) -> Plan {
    let _ = std::fs::create_dir_all(prefix);
    let cwd = exe.parent().unwrap_or(Path::new("/")).to_path_buf();
    let e = exe.to_string_lossy().to_string();
    if let Some(umu) = sys::which("umu-run") {
        // umu lance Proton dans le conteneur Steam Linux Runtime, comme Steam.
        let pfx = prefix.join("pfx").to_string_lossy().to_string();
        let pp = proton.dir.to_string_lossy().to_string();
        return Plan::Run { preview: format!("WINEPREFIX={} PROTONPATH={} umu-run {}", q(&pfx), q(&pp), q(&e)), argv: vec![umu.to_string_lossy().into(), e],
            env: vec![("WINEPREFIX".into(), pfx), ("PROTONPATH".into(), pp), ("GAMEID".into(), "0".into()), ("STORE".into(), "none".into())], cwd, chmod: false };
    }
    let client = steam::root().unwrap_or(dirs::home_dir().unwrap_or_default().join(".local/share/Steam"));
    let env = vec![("STEAM_COMPAT_DATA_PATH".into(), prefix.to_string_lossy().to_string()), ("STEAM_COMPAT_CLIENT_INSTALL_PATH".into(), client.to_string_lossy().to_string())];
    let script = proton.dir.join("proton").to_string_lossy().to_string();
    let pre = format!("STEAM_COMPAT_DATA_PATH={}", q(&prefix.to_string_lossy()));
    if let Some(rt) = steam::sniper() {
        let rt = rt.to_string_lossy().to_string();
        return Plan::Run { preview: format!("{pre} {} --verb=waitforexitandrun -- {} waitforexitandrun {}", q(&rt), q(&script), q(&e)),
            argv: vec![rt, "--verb=waitforexitandrun".into(), "--".into(), script, "waitforexitandrun".into(), e], env, cwd, chmod: false };
    }
    Plan::Run { preview: format!("{pre} {} run {}", q(&script), q(&e)), argv: vec![script, "run".into(), e], env, cwd, chmod: false }
}

pub fn plan(item: &Item, o: &Opts) -> Plan {
    if let Some(id) = &item.steam_id { return Plan::Url(format!("steam://rungameid/{id}")); }
    if let Some(exec) = &item.desktop_exec {
        let argv = desktop_argv(exec);
        if argv.is_empty() { return Plan::Error("Commande vide dans le fichier .desktop.".into()); }
        return Plan::Run { preview: argv.iter().map(|a| q(a)).collect::<Vec<_>>().join(" "), argv, env: vec![], cwd: dirs::home_dir().unwrap_or_default(), chmod: false };
    }
    let cwd = item.path.parent().unwrap_or(Path::new("/")).to_path_buf();
    let p = item.path.to_string_lossy().to_string();
    if item.kind == Kind::Game && item.system == "linux" {
        if p.to_lowercase().ends_with(".sh") { return Plan::Run { preview: format!("sh {}", q(&p)), argv: vec!["/bin/sh".into(), p], env: vec![], cwd, chmod: false }; }
        return Plan::Run { preview: q(&p), argv: vec![p], env: vec![], cwd, chmod: true };
    }
    if item.kind != Kind::Rom && item.system != "windows" { return Plan::Open(item.path.clone()); }
    let rom = o.disc.clone().or_else(|| item.discs.first().cloned()).unwrap_or(item.path.clone());
    if !rom.exists() { return Plan::Error(format!("Le fichier est introuvable :\n{}", rom.display())); }

    if item.system == "windows" {
        let Some(pr) = pick_proton(o.proton.as_deref()) else {
            return Plan::Error("Aucun Proton trouvé. Installez « Proton Experimental » depuis Steam (Bibliothèque → Outils), ou GE-Proton avec ProtonUp-Qt / ProtonPlus.".into());
        };
        if rom.to_string_lossy().to_lowercase().ends_with(".lnk") { return Plan::Error("Un raccourci .lnk ne se lance pas directement : choisissez le .exe du jeu.".into()); }
        return proton_plan(&rom, &pr, &prefix_for(item, &o.prefixes));
    }

    let Some(em) = o.emulator else {
        let s = item.sys();
        let names: Vec<&str> = s.map(|s| s.emulators.iter().filter_map(|id| catalog::emulator(id).map(|e| e.name)).take(3).collect()).unwrap_or_default();
        let mut m = format!("Aucun émulateur installé pour {}.", s.map(|s| s.name).unwrap_or("cette console"));
        if !names.is_empty() { m += &format!("\nInstallez l'un de ces émulateurs : {}.", names.join(", ")); }
        return Plan::Error(m);
    };
    let Some(leading) = catalog::resume_args(em.spec, &o.resume) else {
        return Plan::Error(format!("{} ne sait pas reprendre depuis une sauvegarde d'état en ligne de commande.", em.name()));
    };
    let r = rom.to_string_lossy().to_string();
    let mut template: Vec<String> = (if o.direct { em.spec.direct } else { None }).unwrap_or(em.spec.launch).iter().map(|s| s.to_string()).collect();
    if em.spec.id == "retroarch" {
        let mut t = vec![];
        if let Some(c) = retroarch_core(&item.system, em) { t.push("-L".into()); t.push(c.to_string_lossy().into()); }
        t.extend((if o.direct { em.spec.direct } else { None }).unwrap_or(&["{rom}"]).iter().map(|s| s.to_string()));
        template = t;
    }
    // Les options vont devant : plusieurs émulateurs lient un drapeau au chemin (« -e <fichier> »).
    let mut args: Vec<String> = leading.into_iter().chain(template.into_iter().map(|a| a.replace("{rom}", &r))).collect();
    // Un .pk3 est un mod chargé par-dessus un IWAD.
    let lr = r.to_lowercase();
    if (em.spec.id == "uzdoom" || em.spec.id == "gzdoom") && !(lr.ends_with(".wad") || lr.ends_with(".iwad")) {
        for a in args.iter_mut() { if a == "-iwad" { *a = "-file".into(); } }
    }
    let mut files = vec![r.clone()];
    if let ResumeReq::File(f) = &o.resume { files.push(f.clone()); }
    let argv: Vec<String> = match em.how {
        How::Flatpak => ["flatpak".to_string(), "run".into(), format!("--filesystem={}", common_dir(&files)), em.target.clone().unwrap_or_default()].into_iter().chain(args).collect(),
        _ => std::iter::once(em.target.clone().unwrap_or_default()).chain(args).collect(),
    };
    Plan::Run { preview: argv.iter().map(|a| q(a)).collect::<Vec<_>>().join(" "), argv, env: vec![], cwd, chmod: em.how == How::AppImage }
}

/// Démarre la commande, détachée : fermer Biblijeu ne ferme pas le jeu.
pub fn run(p: &Plan) -> Result<(), String> {
    match p {
        Plan::Url(u) => { sys::open_url(u); Ok(()) }
        Plan::Open(path) => { sys::open_path(path); Ok(()) }
        Plan::Error(e) => Err(e.clone()),
        Plan::Run { argv, env, cwd, chmod, .. } => {
            if *chmod {
                use std::os::unix::fs::PermissionsExt;
                if let Ok(m) = std::fs::metadata(&argv[0]) { let _ = std::fs::set_permissions(&argv[0], std::fs::Permissions::from_mode(m.permissions().mode() | 0o755)); }
            }
            let mut c = sys::clean_command(&argv[0]);
            c.args(&argv[1..]).current_dir(cwd);
            for (k, v) in env { c.env(k, v); }
            sys::spawn_detached(c).map_err(|e| format!("Impossible de lancer {} : {e}", argv[0]))
        }
    }
}

/// Les émulateurs ouverts en ce moment : on ne restaure jamais par-dessus.
pub fn running_ids(installed: &[Installed]) -> HashSet<&'static str> {
    let mut cmdlines = vec![];
    if let Ok(rd) = std::fs::read_dir("/proc") {
        for e in rd.flatten() {
            if !e.file_name().to_string_lossy().bytes().all(|b| b.is_ascii_digit()) { continue; }
            if let Ok(b) = std::fs::read(e.path().join("cmdline")) { cmdlines.push(String::from_utf8_lossy(&b).replace('\0', " ")); }
        }
    }
    let mut ids = HashSet::new();
    for e in installed {
        let mut needles: Vec<String> = e.target.iter().cloned().collect();
        needles.extend(e.spec.flatpak.iter().map(|s| s.to_string()));
        needles.extend(e.spec.bins.iter().map(|b| format!("/{b}")));
        if cmdlines.iter().any(|c| needles.iter().any(|n| c.contains(n.as_str()))) { ids.insert(e.spec.id); }
    }
    ids
}

/// Une commande Flatpak (mise à jour, installation) dont on attend la fin.
pub fn flatpak(args: &[&str]) -> Result<(), String> {
    let out = sys::clean_command("flatpak").args(args).output().map_err(|e| e.to_string())?;
    if out.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or("échec").to_string()) }
}

/// Les mises à jour Flatpak disponibles parmi les émulateurs installés.
pub fn flatpak_updates(installed: &[Installed]) -> Vec<String> {
    let Ok(out) = sys::clean_command("flatpak").args(["remote-ls", "--updates", "--app", "--columns=application"]).output() else { return vec![] };
    let ids: HashSet<String> = String::from_utf8_lossy(&out.stdout).lines().map(|l| l.trim().to_string()).collect();
    installed.iter().filter(|e| e.how == How::Flatpak && e.target.as_ref().map(|t| ids.contains(t)).unwrap_or(false)).filter_map(|e| e.target.clone()).collect()
}


#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn desktop() {
        assert_eq!(desktop_argv("/usr/bin/flatpak run --branch=stable org.x.Y @@u %U @@"), vec!["/usr/bin/flatpak", "run", "--branch=stable", "org.x.Y", "@@u", "@@"]);
        assert_eq!(desktop_argv("\"/opt/My Game/run\" --x %f"), vec!["/opt/My Game/run", "--x"]);
    }
    #[test]
    fn dirs() {
        assert_eq!(common_dir(&["/a/b/c.iso".into(), "/a/b/d/e.sav".into()]), "/a/b");
        assert_eq!(slug("Hollow Knight: Silksong"), "hollow-knight-silksong");
        assert_eq!(version_from_name("rpcs3-v0.0.38-18000_linux64.AppImage").as_deref(), Some("0.0.38"));
    }
}
