//! Trouver les émulateurs installés et construire la commande qui démarre un
//! jeu. Sous Windows, un émulateur est un .exe : installé (Program Files,
//! AppData\Local\Programs, Scoop), dans le PATH, ou portable dans un des
//! dossiers d'émulateurs des réglages. Les jeux Windows se lancent directement.

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
    pub fn how_label(&self) -> &'static str { match self.how { How::Flatpak => "Flatpak", How::Native => "Installé", How::AppImage => "Portable", How::Proton => "Steam" } }
}

/// Les noms d'exe de chaque émulateur sous Windows, en minuscules et sans
/// « .exe ». Un nom qui finit par `*` est un préfixe (« duckstation-qt-x64-ReleaseLTCG »).
pub fn win_exes(id: &str) -> &'static [&'static str] {
    match id {
        "dolphin" => &["dolphin"], "cemu" => &["cemu"], "ryujinx" => &["ryujinx"],
        "eden" => &["eden"], "citron" => &["citron"], "sudachi" => &["sudachi"], "yuzu" => &["yuzu"],
        "duckstation" => &["duckstation-qt*", "duckstation"], "pcsx2" => &["pcsx2-qt", "pcsx2-qtx64*", "pcsx2"],
        "rpcs3" => &["rpcs3"], "shadps4" => &["shadps4", "shadps4qtlauncher"], "ppsspp" => &["ppssppwindows64", "ppssppwindows"],
        "vita3k" => &["vita3k"], "melonds" => &["melonds"], "azahar" => &["azahar", "azahar-qt"], "lime3ds" => &["lime3ds", "lime3ds-gui", "lime3ds-qt"],
        "citra" => &["citra-qt", "citra"], "snes9x" => &["snes9x-x64", "snes9x"], "vbam" => &["visualboyadvance-m"], "mgba" => &["mgba"],
        "mesen" => &["mesen"], "ares" => &["ares"], "simple64" => &["simple64-gui"], "flycast" => &["flycast"], "redream" => &["redream"],
        "xemu" => &["xemu"], "xenia" => &["xenia_canary", "xenia"], "mame" => &["mame", "mame64"], "retroarch" => &["retroarch"],
        "uzdoom" => &["uzdoom"], "gzdoom" => &["gzdoom"], "dosbox" => &["dosbox-x"], "dosboxstaging" => &["dosbox"],
        _ => &[],
    }
}

fn exe_matches(stem: &str, names: &[&str]) -> bool {
    names.iter().any(|n| match n.strip_suffix('*') { Some(pre) => stem.starts_with(pre), None => stem == *n })
}

/// Les .exe des dossiers donnés, jusqu'à `depth` niveaux.
fn exes(dir: &Path, depth: u32, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let n = e.file_name().to_string_lossy().to_lowercase();
        let Ok(t) = e.file_type() else { continue };
        if t.is_dir() {
            if depth > 0 && !n.starts_with('.') && !["windows", "$recycle.bin", "system volume information", "windowsapps", "common files", "microsoft", "node_modules"].contains(&n.as_str()) {
                exes(&e.path(), depth - 1, out);
            }
        } else if n.ends_with(".exe") { out.push(e.path()); }
    }
}

/// Les dossiers où Windows installe les programmes (deux niveaux suffisent :
/// « Program Files\\Dolphin\\Dolphin.exe »), et ceux de Scoop.
fn standard_dirs() -> Vec<(PathBuf, u32)> {
    let env = |k: &str| std::env::var_os(k).map(PathBuf::from);
    let mut v: Vec<(PathBuf, u32)> = vec![];
    for k in ["ProgramFiles", "ProgramFiles(x86)"] { if let Some(p) = env(k) { v.push((p, 2)); } }
    if let Some(l) = env("LOCALAPPDATA") { v.push((l.join("Programs"), 2)); }
    if let Some(h) = dirs::home_dir() { v.push((h.join("scoop").join("apps"), 3)); }
    for d in [r"C:\RetroArch-Win64", r"C:\RetroArch", r"C:\Emulators", r"C:\Emulateurs"] { v.push((PathBuf::from(d), 2)); }
    v
}

pub fn version_from_name(n: &str) -> Option<String> {
    let re = fancy_regex::Regex::new(r"(\d+(?:\.\d+){1,3})").ok()?;
    re.captures(n).ok().flatten().map(|c| c[1].to_string())
}

static DIRS: std::sync::LazyLock<std::sync::Mutex<HashMap<String, PathBuf>>> = std::sync::LazyLock::new(Default::default);

/// Le dossier de l'exe d'un émulateur trouvé à la dernière analyse.
pub fn exe_dir(id: &str) -> Option<PathBuf> { DIRS.lock().ok()?.get(id).cloned() }

/// Les émulateurs présents : d'abord les portables des dossiers des réglages,
/// puis ceux installés, puis le PATH.
pub fn detect(app_folders: &[String]) -> Vec<Installed> {
    let mut portable = vec![];
    for f in app_folders { exes(Path::new(f), 3, &mut portable); }
    let mut standard = vec![];
    for (d, depth) in standard_dirs() { exes(&d, depth, &mut standard); }
    let stem = |p: &Path| p.file_stem().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
    let mut found = vec![];
    let mut dirs_map = HashMap::new();
    for spec in catalog::EMULATORS {
        let names = win_exes(spec.id);
        if names.is_empty() { continue; }
        let pick = |list: &[PathBuf]| {
            let mut m: Vec<&PathBuf> = list.iter().filter(|p| exe_matches(&stem(p), names)).collect();
            // Le plus proche de la racine, puis le nom le plus court (« Dolphin » avant « DolphinTool »).
            m.sort_by_key(|p| (p.components().count(), stem(p).len()));
            m.first().map(|p| p.to_path_buf())
        };
        let (how, exe) = if let Some(e) = pick(&portable) { (How::AppImage, e) }
            else if let Some(e) = pick(&standard) { (How::Native, e) }
            else if let Some(e) = names.iter().filter(|n| !n.ends_with('*')).find_map(|n| sys::which(&format!("{n}.exe"))) { (How::Native, e) }
            else { continue };
        let folder = exe.parent().map(|d| d.file_name().unwrap_or_default().to_string_lossy().to_string()).unwrap_or_default();
        if let Some(d) = exe.parent() { dirs_map.insert(spec.id.to_string(), d.to_path_buf()); }
        found.push(Installed { spec, how, target: Some(exe.to_string_lossy().into()), version: version_from_name(&folder), installation: None });
    }
    if let Ok(mut m) = DIRS.lock() { *m = dirs_map; }
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
    let mut dirs: Vec<PathBuf> = vec![];
    if let Some(d) = inst.target.as_ref().and_then(|t| Path::new(t).parent().map(|p| p.to_path_buf())) { dirs.push(d.join("cores")); }
    if let Some(a) = dirs::config_dir() { dirs.push(a.join("RetroArch").join("cores")); }
    ra_cores(sys).iter().find_map(|n| dirs.iter().map(|d| d.join(format!("{n}_libretro.dll"))).find(|f| f.exists()))
}

/// Une console tourne si un émulateur installé la prend (RetroArch : s'il a le cœur).
pub fn runs(inst: &Installed, sys: &str) -> bool {
    if inst.spec.id == "retroarch" { inst.spec.runs(sys) && retroarch_core(sys, inst).is_some() } else { inst.spec.runs(sys) }
}

// ── Commande ──────────────────────────────────────────────────────────────

pub fn common_dir(files: &[String]) -> String {
    let parent = |f: &str| Path::new(f).parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let mut acc = parent(&files[0]);
    for f in &files[1..] {
        let q = parent(f);
        let common: PathBuf = acc.components().zip(q.components()).take_while(|(a, b)| a == b).map(|(a, _)| a).collect();
        acc = common;
    }
    acc.to_string_lossy().to_string()
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
        match self { Plan::Run { preview, .. } => preview.clone(), Plan::Url(u) => format!("steam {u}"), Plan::Open(p) => format!("ouvrir {}", q(&p.to_string_lossy())), Plan::Error(e) => e.clone() }
    }
}

pub struct Opts<'a> { pub emulator: Option<&'a Installed>, pub direct: bool, pub disc: Option<PathBuf>, pub resume: ResumeReq, pub proton: Option<String>, pub prefixes: PathBuf }

pub fn prefix_for(item: &Item, root: &Path) -> PathBuf { root.join(slug(&item.title)) }

pub fn plan(item: &Item, o: &Opts) -> Plan {
    if let Some(id) = &item.steam_id { return Plan::Url(format!("steam://rungameid/{id}")); }
    if let Some(exec) = &item.desktop_exec {
        let argv = desktop_argv(exec);
        if argv.is_empty() { return Plan::Error("Commande vide dans le fichier .desktop.".into()); }
        return Plan::Run { preview: argv.iter().map(|a| q(a)).collect::<Vec<_>>().join(" "), argv, env: vec![], cwd: dirs::home_dir().unwrap_or_default(), chmod: false };
    }
    let cwd = item.path.parent().unwrap_or(Path::new("C:\\")).to_path_buf();
    if item.kind == Kind::Game && item.system == "linux" { return Plan::Error("Un jeu Linux ne se lance pas sous Windows.".into()); }
    if item.kind != Kind::Rom && item.system != "windows" { return Plan::Open(item.path.clone()); }
    let rom = o.disc.clone().or_else(|| item.discs.first().cloned()).unwrap_or(item.path.clone());
    if !rom.exists() { return Plan::Error(format!("Le fichier est introuvable :\n{}", rom.display())); }

    if item.system == "windows" {
        // Un jeu Windows se lance tel quel ; un raccourci, un .bat ou un .msi passent par Windows.
        let l = rom.to_string_lossy().to_lowercase();
        if !l.ends_with(".exe") { return Plan::Open(rom); }
        let e = rom.to_string_lossy().to_string();
        return Plan::Run { preview: q(&e), argv: vec![e], env: vec![], cwd: rom.parent().unwrap_or(&cwd).to_path_buf(), chmod: false };
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
    let _ = files;
    let target = em.target.clone().unwrap_or_default();
    // L'émulateur démarre dans son dossier : une installation portable y lit sa configuration.
    let cwd = Path::new(&target).parent().map(|p| p.to_path_buf()).unwrap_or(cwd);
    let argv: Vec<String> = std::iter::once(target).chain(args).collect();
    Plan::Run { preview: argv.iter().map(|a| q(a)).collect::<Vec<_>>().join(" "), argv, env: vec![], cwd, chmod: false }
}

/// Démarre la commande, détachée : fermer Biblijeu ne ferme pas le jeu.
pub fn run(p: &Plan) -> Result<(), String> {
    match p {
        Plan::Url(u) => { sys::open_url(u); Ok(()) }
        Plan::Open(path) => { sys::open_path(path); Ok(()) }
        Plan::Error(e) => Err(e.clone()),
        Plan::Run { argv, env, cwd, .. } => {
            let mut c = std::process::Command::new(&argv[0]);
            c.args(&argv[1..]).current_dir(cwd);
            for (k, v) in env { c.env(k, v); }
            sys::spawn_detached(c).map_err(|e| format!("Impossible de lancer {} : {e}", argv[0]))
        }
    }
}

/// Les émulateurs ouverts en ce moment : on ne restaure jamais par-dessus.
pub fn running_ids(installed: &[Installed]) -> HashSet<&'static str> {
    let out = sys::clean_command("tasklist").args(["/FO", "CSV", "/NH"]).output();
    let names: HashSet<String> = out.map(|o| String::from_utf8_lossy(&o.stdout).lines()
        .filter_map(|l| l.split(',').next().map(|n| n.trim_matches('"').to_lowercase())).collect()).unwrap_or_default();
    installed.iter().filter(|e| e.target.as_ref().and_then(|t| Path::new(t).file_name()).map(|n| names.contains(&n.to_string_lossy().to_lowercase())).unwrap_or(false))
        .map(|e| e.spec.id).collect()
}

/// Pas de Flatpak sous Windows.
pub fn flatpak(_args: &[&str]) -> Result<(), String> { Err("Flatpak n'existe pas sous Windows.".into()) }
pub fn flatpak_updates(_installed: &[Installed]) -> Vec<String> { vec![] }


#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exe_names() {
        assert!(exe_matches("duckstation-qt-x64-releaseltcg", win_exes("duckstation")));
        assert!(exe_matches("dolphin", win_exes("dolphin")));
        assert!(!exe_matches("dolphintool", win_exes("dolphin")));
        assert!(!exe_matches("dosbox-x", win_exes("dosboxstaging")));
    }
    #[test]
    fn desktop() {
        assert_eq!(desktop_argv("/usr/bin/flatpak run --branch=stable org.x.Y @@u %U @@"), vec!["/usr/bin/flatpak", "run", "--branch=stable", "org.x.Y", "@@u", "@@"]);
        assert_eq!(desktop_argv("\"/opt/My Game/run\" --x %f"), vec!["/opt/My Game/run", "--x"]);
    }
    #[test]
    fn dirs() {
        assert_eq!(common_dir(&[r"C:\a\b\c.iso".into(), r"C:\a\b\d\e.sav".into()]), r"C:\a\b");
        assert_eq!(slug("Hollow Knight: Silksong"), "hollow-knight-silksong");
        assert_eq!(version_from_name("rpcs3-v0.0.38-18000_linux64.AppImage").as_deref(), Some("0.0.38"));
    }
}
