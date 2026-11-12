//! L'état de Biblijeu et ce qui tourne en fond : analyse des dossiers, de Steam
//! et des applications, détection des émulateurs, jaquettes, mises à jour
//! Flatpak, sauvegardes. Traduction de main.js.

use crate::artwork::{self, Candidate, Libretro, SteamGridDb};
use crate::backup::{self, Folder, Manifest, Outcome, Rules};
use crate::catalog::{self, GameState, Item, Kind, ResumeReq};
use crate::common::images::{ImageCache, Source};
use crate::common::selfupdate::SelfUpdate;
use crate::common::store::{self, Settings};
use crate::common::sys;
use crate::common::theme;
use crate::common::ui::Toast;
use crate::emulators::{self, How, Installed, Plan};
use crate::{scanner, steam};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

pub const REPO: &str = "VGioM/Biblijeu";

#[derive(Clone)]
pub struct BackupFolder { pub folder: Folder, pub files: u64, pub bytes: u64, pub backed: Option<backup::Entry> }
#[derive(Clone)]
pub struct Group { pub emulator: String, pub name: String, pub installed: bool, pub folders: Vec<BackupFolder> }

#[derive(Default)]
pub struct BackupState {
    pub groups: Vec<Group>, pub scanning: bool, pub running: bool, pub last_summary: Option<String>, pub last_failures: Vec<String>,
    pub message: Option<String>, pub available: bool,
}

pub struct Scan { items: Vec<Item>, emulators: Vec<Installed>, emu_icons: HashMap<String, (PathBuf, Option<PathBuf>)> }

pub enum Bg {
    Scanned(Scan),
    Art(String, Option<String>),
    ArtDone { found: usize, total: usize, force: bool },
    Refetched(String, Option<String>, String),
    Candidates(String, Vec<Candidate>),
    KeyTest(bool),
    Updates(Option<HashMap<String, String>>),
    EmuDone(String, Result<String, String>),
    Groups(Vec<Group>, bool),
    BackupDone { summary: Option<String>, failures: Vec<String>, append: bool, to_backup: bool },
    BackupFinished,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Tab { Sources, Launch, Artwork, App }

pub struct Correction { pub id: String, pub query: String, pub results: Option<Vec<Candidate>> }

pub enum PickFor { RomFolder, Excluded, AppFolder, Application, BackupDest, StateFile(String), Artwork(String) }

pub struct App {
    pub p: theme::Palette,
    pub dir: PathBuf,
    pub settings: Settings,
    pub images: ImageCache,
    libretro: Arc<Libretro>,
    sgdb: Arc<SteamGridDb>,

    scanned: Vec<Item>,
    pub items: Vec<Item>,
    pub emulators: Vec<Installed>,
    pub emu_icons: HashMap<String, (PathBuf, Option<PathBuf>)>,
    pub protons: Vec<String>,
    pub has_umu: bool,
    pub has_flatpak: bool,
    pub states: HashMap<String, GameState>,
    states_dirty: Option<Instant>,

    pub scanning: bool,
    scan_again: bool,
    pub scan_progress: Arc<Mutex<String>>,
    pub art_progress: Arc<Mutex<Option<(usize, usize)>>>,
    pub error: Option<String>,
    pub info: Option<String>,
    pub flatpak_updates: HashMap<String, String>,
    pub updates_checked_at: Option<i64>,
    pub checking_updates: bool,
    pub emu_activity: Arc<Mutex<HashMap<String, String>>>,
    pub emu_notes: HashMap<String, String>,
    pub emu_problems: HashMap<String, String>,
    emu_queue: Vec<(String, bool)>,
    emu_busy: bool,
    pub backup: BackupState,
    pub backup_progress: Arc<Mutex<String>>,
    backup_cancel: Arc<AtomicBool>,
    last_auto: Instant,
    launch_backup_done: bool,

    pub search: String,
    pub focus_search: bool,
    pub selected: Option<String>,
    pub settings_tab: Option<Tab>,
    pub correction: Option<Correction>,
    pub confirm_restore: Option<(Option<String>, String)>,
    pub key_status: Option<Option<bool>>,
    picks: Vec<(PickFor, mpsc::Receiver<Vec<PathBuf>>)>,
    plan_cache: Option<(String, Plan, ResumeReq)>,

    watcher: Option<notify::RecommendedWatcher>,
    changed: Arc<Mutex<Option<Instant>>>,

    pub tx: mpsc::Sender<Bg>,
    rx: mpsc::Receiver<Bg>,
    pub toast: Toast,
    pub update: SelfUpdate,
    pub test: crate::common::testhook::TestHook,
    test_done: bool,
}

fn home() -> PathBuf { dirs::home_dir().unwrap_or_default() }

impl App {
    pub fn new(cc: &eframe::CreationContext) -> Self {
        let p = theme::MUSIC;
        theme::install(&cc.egui_ctx, &p);
        egui_extras::install_image_loaders(&cc.egui_ctx);
        let dir = store::support_dir("Biblijeu", Some("BIBLIJEU_SUPPORT"));
        let h = home();
        let app_folders: Vec<String> = ["Applications", "AppImages", "Games", "Emulation", ".local/bin"].iter().map(|x| h.join(x).to_string_lossy().to_string()).collect();
        let prefixes = dir.join("prefixes").to_string_lossy().to_string();
        let settings = Settings::new(dir.join("settings.json"), json!({
            "romFolders": [], "excludedFolders": [],
            "applicationFolders": app_folders,
            "scanApplications": true, "scanSteam": true, "manualApplications": [], "directLaunch": true, "resumeOnLaunch": true, "autoFetchArtwork": true,
            "steamGridDBKey": "", "preferredRegion": "Europe", "watchFolders": true, "cardSize": 168, "emulatorForSystem": {}, "protonVersion": "",
            "prefixesFolder": prefixes, "backupDestination": "", "autoBackup": false, "backupOnInterval": true,
            "backupIntervalMinutes": 30, "backupOnLaunch": true, "backupOnQuit": true, "backupKinds": backup::DEFAULT_KINDS, "backupExcludedEmulators": [],
            "autoInstallUpdates": false, "lastSelection": "all", "sortOrder": "title", "showInspector": true,
        }));
        let (tx, rx) = mpsc::channel();
        let states = store::read_json(&dir.join("play-state.json")).unwrap_or_default();
        let mut app = App {
            p, images: ImageCache::new(&cc.egui_ctx, store::cache_dir("Biblijeu").join("images"), 6),
            libretro: Arc::new(Libretro::new(dir.join("ThumbnailIndex"))), sgdb: Arc::new(SteamGridDb::new()), settings, dir,
            scanned: vec![], items: vec![], emulators: vec![], emu_icons: HashMap::new(), protons: vec![], has_umu: sys::which("umu-run").is_some(),
            has_flatpak: sys::which("flatpak").is_some(), states, states_dirty: None,
            scanning: false, scan_again: false, scan_progress: Arc::default(), art_progress: Arc::default(), error: None, info: None,
            flatpak_updates: HashMap::new(), updates_checked_at: None, checking_updates: false, emu_activity: Arc::default(),
            emu_notes: HashMap::new(), emu_problems: HashMap::new(), emu_queue: vec![], emu_busy: false,
            backup: BackupState::default(), backup_progress: Arc::default(), backup_cancel: Arc::default(), last_auto: Instant::now(), launch_backup_done: false,
            search: String::new(), focus_search: false, selected: None, settings_tab: None, correction: None, confirm_restore: None, key_status: None,
            picks: vec![], plan_cache: None, watcher: None, changed: Arc::default(),
            tx, rx, toast: Toast::default(), update: SelfUpdate::new(REPO, "Biblijeu"), test: Default::default(), test_done: false,
        };
        app.flatpak_updates = app.settings.get_as("flatpakUpdates").unwrap_or_default();
        app.updates_checked_at = app.settings.get("updatesCheckedAt").as_i64();
        app.rescan(&cc.egui_ctx);
        app
    }

    pub fn sel(&self) -> String { let s = self.settings.string("lastSelection"); if s.is_empty() { "all".into() } else { s } }
    pub fn st(&self, id: &str) -> GameState { self.states.get(id).cloned().unwrap_or_default() }
    pub fn item(&self, id: &str) -> Option<&Item> { self.items.iter().find(|i| i.id == id) }
    pub fn update_state(&mut self, id: &str, f: impl FnOnce(&mut GameState)) {
        f(self.states.entry(id.to_string()).or_default());
        self.states_dirty = Some(Instant::now());
        self.plan_cache = None;
    }
    pub fn save_states(&mut self) {
        let _ = store::write_json(&self.dir.join("play-state.json"), &self.states, true);
        self.states_dirty = None;
    }
    pub fn set_setting<T: serde::Serialize>(&mut self, ctx: &egui::Context, key: &str, v: T) {
        self.settings.set(key, v);
        self.plan_cache = None;
        if ["romFolders", "excludedFolders", "applicationFolders", "scanApplications", "scanSteam", "manualApplications"].contains(&key) { self.rescan(ctx); }
        if key == "watchFolders" { self.start_watching(ctx); }
        if key.starts_with("backup") || key == "autoBackup" { self.refresh_backups(ctx); }
    }
    pub fn add_to(&mut self, ctx: &egui::Context, key: &str, paths: Vec<PathBuf>) {
        let mut list = self.settings.strings(key);
        for p in paths { let s = p.to_string_lossy().to_string(); if !list.contains(&s) { list.push(s); } }
        self.set_setting(ctx, key, list);
    }
    pub fn remove_from(&mut self, ctx: &egui::Context, key: &str, p: &str) {
        let list: Vec<String> = self.settings.strings(key).into_iter().filter(|x| x != p).collect();
        self.set_setting(ctx, key, list);
    }
    pub fn prefixes(&self) -> PathBuf { PathBuf::from(self.settings.string("prefixesFolder")) }

    // ── Analyse ───────────────────────────────────────────────────────────

    pub fn rescan(&mut self, ctx: &egui::Context) {
        if self.scanning { self.scan_again = true; return; }
        self.scanning = true;
        *self.scan_progress.lock().unwrap() = "Analyse…".into();
        let (roots, ex, folders, steam_on, apps_on, manual) = (self.settings.strings("romFolders"), self.settings.strings("excludedFolders"),
            self.settings.strings("applicationFolders"), self.settings.bool("scanSteam"), self.settings.bool("scanApplications"), self.settings.strings("manualApplications"));
        let (tx, ctx2, progress) = (self.tx.clone(), ctx.clone(), self.scan_progress.clone());
        std::thread::spawn(move || {
            let report = |t: String| { *progress.lock().unwrap() = t; ctx2.request_repaint(); };
            let mut found = scanner::scan_roms(&roots, &ex, &report);
            if steam_on { report("Lecture de la bibliothèque Steam…".into()); found = merge_steam(found, steam::installed_games(), steam::shortcuts()); }
            let apps = scanner::scan_applications();
            if apps_on { found.extend(apps.games.iter().cloned()); }
            for p in manual {
                let path = PathBuf::from(&p);
                let Ok(m) = std::fs::metadata(&path) else { continue };
                if p.ends_with(".desktop") && apps.games.iter().any(|g| g.path == path) { continue; }
                let name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
                let title = ["appimage", "x86_64", "sh"].iter().fold(name.clone(), |t, e| {
                    let l = t.to_lowercase(); if l.ends_with(&format!(".{e}")) { t[..t.len() - e.len() - 1].to_string() } else { t }
                });
                found.insert(0, Item { id: scanner::identifier(&path, Some(m.len())), kind: Kind::Game, sort_title: catalog::normalize(&name), title,
                    system: if p.to_lowercase().ends_with(".exe") { "windows".into() } else { "linux".into() }, path, discs: vec![], region: None, languages: vec![],
                    tags: vec![], size: m.len(), added: mtime(&m), source_root: None, raw_name: name, local_art: None, steam_id: None, desktop_exec: None, version: None, emulator_id: None });
            }
            report("Recherche des émulateurs…".into());
            let emulators = emulators::detect(&folders);
            for e in emulators.iter().filter(|e| e.how != How::Proton) {
                let d = apps.emu_icons.get(e.id());
                found.push(Item { id: scanner::hash(&format!("emulator:{}", e.id())), kind: Kind::Emulator, title: e.name().into(), sort_title: catalog::normalize(e.name()),
                    system: String::new(), path: PathBuf::from(e.target.clone().unwrap_or_default()), discs: vec![], region: None, languages: vec![], tags: vec![], size: 0,
                    added: 0, source_root: None, raw_name: e.name().into(), local_art: d.and_then(|d| d.1.clone()),
                    desktop_exec: d.and_then(|d| scanner::parse_desktop(&d.0)).and_then(|m| m.get("Exec").cloned()), steam_id: None, version: e.version.clone(), emulator_id: Some(e.id().into()) });
            }
            let mut seen = HashSet::new();
            found.retain(|i| seen.insert(i.id.clone()));
            found.sort_by(|a, b| a.sort_title.cmp(&b.sort_title));
            let _ = tx.send(Bg::Scanned(Scan { items: found, emulators, emu_icons: apps.emu_icons }));
            ctx2.request_repaint();
        });
    }

    /// Les corrections de l'utilisateur par-dessus l'analyse.
    pub fn apply_overrides(&mut self) {
        self.items = self.scanned.iter().map(|it| {
            let mut o = it.clone();
            if let Some(st) = self.states.get(&it.id) {
                if let Some(k) = st.kind_override { o.kind = k; }
                if let Some(s) = st.system_override.as_ref().filter(|s| catalog::system(s).is_some()) { o.system = s.clone(); }
            }
            o
        }).collect();
        self.plan_cache = None;
    }

    pub fn start_watching(&mut self, ctx: &egui::Context) {
        use notify::{RecursiveMode, Watcher};
        self.watcher = None;
        if !self.settings.bool("watchFolders") { return; }
        let roots: Vec<String> = self.settings.strings("romFolders").into_iter().filter(|p| Path::new(p).exists()).collect();
        let ex = self.settings.strings("excludedFolders");
        let libs = if self.settings.bool("scanSteam") { steam::libraries() } else { vec![] };
        let (changed, ctx2, roots2, libs2) = (self.changed.clone(), ctx.clone(), roots.clone(), libs.clone());
        let w = notify::recommended_watcher(move |r: notify::Result<notify::Event>| {
            let Ok(ev) = r else { return };
            if matches!(ev.kind, notify::EventKind::Access(_)) { return; }
            let hit = ev.paths.iter().any(|p| {
                let s = p.to_string_lossy();
                // Steam : seulement un manifeste de jeu ajouté ou retiré, pas ses écritures permanentes.
                if libs2.iter().any(|l| p.parent() == Some(l.as_path())) {
                    let n = p.file_name().unwrap_or_default().to_string_lossy().to_string();
                    return n.starts_with("appmanifest_") && n.ends_with(".acf");
                }
                !scanner::ignores_change(&s, &roots2, &ex)
            });
            if hit { *changed.lock().unwrap() = Some(Instant::now()); ctx2.request_repaint_after(Duration::from_secs(3)); }
        });
        let Ok(mut w) = w else { return };
        for r in &roots { let _ = w.watch(Path::new(r), RecursiveMode::Recursive); }
        for l in &libs { let _ = w.watch(l, RecursiveMode::NonRecursive); }
        self.watcher = Some(w);
    }

    // ── Émulateurs et lancement ───────────────────────────────────────────

    pub fn emulator_for(&self, it: &Item) -> Option<&Installed> {
        if it.kind != Kind::Rom { return None; }
        let st = self.states.get(&it.id);
        let wanted = st.and_then(|s| s.emulator_id.clone());
        let by_id = |id: &str| self.emulators.iter().find(|e| e.id() == id && emulators::runs(e, &it.system))
            .or_else(|| if wanted.as_deref() == Some(id) { self.emulators.iter().find(|e| e.id() == id) } else { None });
        if let Some(w) = &wanted { if let Some(e) = by_id(w) { return Some(e); } }
        let s = it.sys()?;
        let prefs: HashMap<String, String> = self.settings.get_as("emulatorForSystem").unwrap_or_default();
        if let Some(e) = prefs.get(s.id).and_then(|p| by_id(p)) { return Some(e); }
        for id in s.emulators { if let Some(e) = self.emulators.iter().find(|e| e.id() == *id && emulators::runs(e, s.id)) { return Some(e); } }
        self.emulators.iter().find(|e| e.how != How::Proton && emulators::runs(e, s.id))
    }
    pub fn alternatives(&self, it: &Item) -> Vec<&Installed> { self.emulators.iter().filter(|e| e.how != How::Proton && emulators::runs(e, &it.system)).collect() }
    pub fn playable(&self, it: &Item) -> bool { it.kind != Kind::Rom || self.emulator_for(it).is_some() }

    /// Ce que « Reprendre » veut dire pour ce jeu : le fichier choisi, l'emplacement choisi, ou la dernière sauvegarde.
    pub fn resume_request(&self, it: &Item) -> ResumeReq {
        let Some(e) = self.emulator_for(it) else { return ResumeReq::FromStart };
        let st = self.st(&it.id);
        let mut wanted = vec![];
        if let Some(f) = st.state_file_path { wanted.push(ResumeReq::File(f)); }
        if let Some(s) = st.resume_slot { wanted.push(ResumeReq::Slot(s)); }
        if e.spec.resume.auto.is_some() { wanted.push(ResumeReq::Auto); }
        wanted.into_iter().find(|r| catalog::resume_args(e.spec, r).is_some()).unwrap_or(ResumeReq::FromStart)
    }

    pub fn plan_for(&self, it: &Item, emulator: Option<&str>, disc: Option<PathBuf>, from_start: bool) -> (Plan, ResumeReq) {
        let resume = if from_start || !self.settings.bool("resumeOnLaunch") { ResumeReq::FromStart } else { self.resume_request(it) };
        let em = match emulator { Some(id) => self.emulators.iter().find(|e| e.id() == id), None => self.emulator_for(it) };
        let st = self.st(&it.id);
        let proton = st.proton_version.clone().filter(|s| !s.is_empty()).or(Some(self.settings.string("protonVersion")).filter(|s| !s.is_empty()));
        let o = emulators::Opts { emulator: em, direct: self.settings.bool("directLaunch"), disc, resume: resume.clone(), proton, prefixes: self.prefixes() };
        (emulators::plan(it, &o), resume)
    }

    /// Le plan du jeu sélectionné, recalculé seulement quand quelque chose change.
    pub fn selected_plan(&mut self) -> Option<(Plan, ResumeReq)> {
        let it = self.selected.as_ref().and_then(|id| self.item(id))?.clone();
        let key = format!("{}|{:?}", it.id, it.kind);
        if let Some((k, p, r)) = &self.plan_cache { if *k == key { return Some((p.clone(), r.clone())); } }
        let (p, r) = self.plan_for(&it, None, None, false);
        self.plan_cache = Some((key, p.clone(), r.clone()));
        Some((p, r))
    }

    pub fn play(&mut self, ctx: &egui::Context, id: &str, emulator: Option<&str>, disc: Option<PathBuf>, from_start: bool) {
        let Some(it) = self.item(id).cloned() else { return };
        let (p, _) = self.plan_for(&it, emulator, disc, from_start);
        if let Plan::Error(e) = &p { self.error = Some(e.clone()); return; }
        if let Err(e) = emulators::run(&p) { self.error = Some(format!("{} n'a pas pu démarrer.\n{e}", it.title)); return; }
        self.update_state(id, |s| { s.last_played = Some(sys::now_ms()); s.play_count += 1; });
        self.toast.show(format!("{} démarre…", it.title));
        // Avant de jouer : les sauvegardes du disque, si elles sont plus récentes.
        let _ = ctx;
    }

    // ── Jaquettes ─────────────────────────────────────────────────────────

    fn has_no_cover(&self, it: &Item) -> bool {
        if !(it.kind == Kind::Rom || it.steam_id.is_some() || it.system == "windows") || it.local_art.is_some() { return false; }
        let st = self.states.get(&it.id);
        st.map(|s| s.custom_artwork_path.is_none() && s.artwork_url.is_none()).unwrap_or(true)
    }

    pub fn fetch_artwork(&mut self, ctx: &egui::Context, force: bool) {
        if self.art_progress.lock().unwrap().is_some() { if force { self.info = Some("Une recherche de jaquettes est déjà en cours.".into()); } return; }
        let pending: Vec<(Item, Option<String>)> = self.items.iter().filter(|it| self.has_no_cover(it) && (force || !self.states.get(&it.id).map(|s| s.artwork_missing).unwrap_or(false)))
            .map(|it| (it.clone(), self.states.get(&it.id).and_then(|s| s.search_title.clone()))).collect();
        if pending.is_empty() { if force { self.info = Some("Aucune jaquette manquante : tous les jeux en ont une.".into()); } return; }
        let total = pending.len();
        *self.art_progress.lock().unwrap() = Some((0, total));
        let (region, key) = (self.settings.string("preferredRegion"), self.settings.string("steamGridDBKey"));
        let queue = Arc::new(Mutex::new(pending));
        let found = Arc::new(Mutex::new(0usize));
        let left = Arc::new(Mutex::new(4usize));
        // Quatre à la fois : de quoi occuper la connexion, sans brusquer une archive publique.
        for _ in 0..4 {
            let (q, tx, ctx, lib, sg, prog, found, left, region, key) = (queue.clone(), self.tx.clone(), ctx.clone(), self.libretro.clone(), self.sgdb.clone(),
                self.art_progress.clone(), found.clone(), left.clone(), region.clone(), key.clone());
            std::thread::spawn(move || {
                loop {
                    let Some((it, search)) = q.lock().unwrap().pop() else { break };
                    let url = artwork::lookup(&lib, &sg, &it, search.as_deref(), &region, &key);
                    if url.is_some() { *found.lock().unwrap() += 1; }
                    let _ = tx.send(Bg::Art(it.id.clone(), url));
                    if let Some(p) = prog.lock().unwrap().as_mut() { p.0 += 1; }
                    ctx.request_repaint();
                }
                let mut l = left.lock().unwrap();
                *l -= 1;
                if *l == 0 { let _ = tx.send(Bg::ArtDone { found: *found.lock().unwrap(), total, force }); ctx.request_repaint(); }
            });
        }
    }

    pub fn refetch(&mut self, ctx: &egui::Context, id: &str, title: Option<String>) {
        let Some(it) = self.item(id).cloned() else { return };
        if let Some(t) = &title { self.update_state(id, |s| s.search_title = Some(t.clone())); }
        let search = title.clone().or(self.st(id).search_title);
        let (lib, sg, tx, ctx, region, key) = (self.libretro.clone(), self.sgdb.clone(), self.tx.clone(), ctx.clone(), self.settings.string("preferredRegion"), self.settings.string("steamGridDBKey"));
        std::thread::spawn(move || {
            let url = artwork::lookup(&lib, &sg, &it, search.as_deref(), &region, &key);
            let _ = tx.send(Bg::Refetched(it.id.clone(), url, title.unwrap_or(it.title.clone())));
            ctx.request_repaint();
        });
    }

    pub fn search_candidates(&mut self, ctx: &egui::Context) {
        let Some(c) = &mut self.correction else { return };
        c.results = None;
        let Some(it) = self.items.iter().find(|i| i.id == c.id).cloned() else { return };
        let q = c.query.trim().to_string();
        let (lib, tx, ctx, region, key) = (self.libretro.clone(), self.tx.clone(), ctx.clone(), self.settings.string("preferredRegion"), self.settings.string("steamGridDBKey"));
        std::thread::spawn(move || {
            let r = artwork::candidates(&lib, &it, (!q.is_empty()).then_some(q.as_str()), &region, &key);
            let _ = tx.send(Bg::Candidates(it.id.clone(), r));
            ctx.request_repaint();
        });
    }

    pub fn apply_artwork(&mut self, id: &str, url: String, title: &str) {
        let t = title.trim().to_string();
        self.update_state(id, |s| { s.artwork_url = Some(url); s.artwork_missing = false; s.custom_artwork_path = None; if !t.is_empty() { s.search_title = Some(t); } });
    }

    pub fn clear_artwork(&mut self, ctx: &egui::Context) {
        for s in self.states.values_mut() { s.artwork_url = None; s.artwork_missing = false; }
        self.states_dirty = Some(Instant::now());
        self.libretro.clear();
        self.images.clear(&store::cache_dir("Biblijeu").join("images"));
        self.fetch_artwork(ctx, false);
    }

    pub fn test_key(&mut self, ctx: &egui::Context) {
        self.key_status = Some(None);
        let (tx, ctx, key) = (self.tx.clone(), ctx.clone(), self.settings.string("steamGridDBKey"));
        std::thread::spawn(move || { let _ = tx.send(Bg::KeyTest(SteamGridDb::validate(&key))); ctx.request_repaint(); });
    }

    pub fn cover_source(&self, it: &Item) -> (Option<Source>, bool) {
        let st = self.states.get(&it.id);
        if let Some(p) = st.and_then(|s| s.custom_artwork_path.clone()) { return (Some(Source::File(p.into())), false); }
        if let Some(u) = st.and_then(|s| s.artwork_url.clone()) { return (Some(Source::Url(u)), false); }
        if let Some(p) = &it.local_art {
            let s = p.to_string_lossy();
            // Une icône d'application : centrée, à taille raisonnable.
            let icon = s.ends_with(".svg") || s.contains("/icons/") || s.contains("/pixmaps/");
            return (Some(Source::File(p.clone())), icon);
        }
        (None, false)
    }

    // ── Mises à jour des émulateurs (Flatpak) ─────────────────────────────

    /// Une fois par jour civil : les Flatpak d'émulateurs qui ont une mise à jour en attente.
    pub fn check_updates(&mut self, ctx: &egui::Context, force: bool) {
        if self.checking_updates || !self.has_flatpak { return; }
        if !force {
            if let Some(t) = self.updates_checked_at {
                let day = |ms: i64| chrono::DateTime::from_timestamp_millis(ms).map(|d| d.with_timezone(&chrono::Local).date_naive());
                if day(t) == day(sys::now_ms()) { return; }
            }
        }
        self.checking_updates = true;
        let ids: HashSet<String> = self.emulators.iter().filter(|e| e.how == How::Flatpak).filter_map(|e| e.target.clone()).collect();
        let (tx, ctx) = (self.tx.clone(), ctx.clone());
        std::thread::spawn(move || {
            let out = sys::clean_command("flatpak").env("LC_ALL", "C").args(["remote-ls", "--updates", "--app", "--columns=application,version"]).output();
            let r = out.ok().filter(|o| o.status.success()).map(|o| {
                String::from_utf8_lossy(&o.stdout).lines().filter_map(|l| {
                    let mut p = l.split('\t');
                    let id = p.next()?.trim().to_string();
                    let v = p.next().unwrap_or("").trim();
                    ids.contains(&id).then(|| (id, if v.is_empty() { "nouvelle version".into() } else { v.to_string() }))
                }).collect()
            });
            let _ = tx.send(Bg::Updates(r));
            ctx.request_repaint();
        });
    }

    /// Mise à jour (`install` = false) ou installation depuis Flathub, l'une après l'autre.
    pub fn queue_emulator(&mut self, ctx: &egui::Context, id: &str, install: bool) {
        if self.emu_queue.iter().any(|q| q.0 == id) { return; }
        self.emu_problems.remove(id);
        self.emu_notes.remove(id);
        self.emu_activity.lock().unwrap().insert(id.into(), if install { "En attente…" } else { "En attente…" }.into());
        self.emu_queue.push((id.into(), install));
        self.next_emulator(ctx);
    }

    fn next_emulator(&mut self, ctx: &egui::Context) {
        if self.emu_busy || self.emu_queue.is_empty() { return; }
        let (id, install) = self.emu_queue.remove(0);
        let args: Vec<Vec<String>> = if install {
            let Some(spec) = catalog::emulator(&id).filter(|s| !s.flatpak.is_empty()) else { return };
            // Pour l'utilisateur d'abord (sans mot de passe) ; sinon pour le système.
            ["--user", "--system"].iter().map(|w| vec!["install".into(), "-y".into(), "--noninteractive".into(), w.to_string(), "flathub".into(), spec.flatpak[0].into()]).collect()
        } else {
            let Some(e) = self.emulators.iter().find(|e| e.id() == id && e.how == How::Flatpak) else { return };
            if emulators::running_ids(std::slice::from_ref(e)).contains(e.id()) {
                self.emu_activity.lock().unwrap().remove(&id);
                self.emu_problems.insert(id.clone(), format!("{} est ouvert : quittez-le, puis réessayez.", e.name()));
                return self.next_emulator(ctx);
            }
            let w = if e.installation.as_deref() == Some("user") { "--user" } else { "--system" };
            vec![vec!["update".into(), "-y".into(), "--noninteractive".into(), w.into(), e.target.clone().unwrap_or_default()]]
        };
        self.emu_busy = true;
        let label = if install { "Installation" } else { "Mise à jour" };
        self.emu_activity.lock().unwrap().insert(id.clone(), format!("{label}…"));
        let (tx, ctx, act) = (self.tx.clone(), ctx.clone(), self.emu_activity.clone());
        std::thread::spawn(move || {
            let mut last = Err("échec".to_string());
            for a in args {
                last = run_flatpak(&a, |pct| { act.lock().unwrap().insert(id.clone(), format!("{label} {pct} %")); ctx.request_repaint(); });
                if last.is_ok() { break; }
            }
            let _ = tx.send(Bg::EmuDone(id, last.map(|_| if install { "Installé depuis Flathub.".into() } else { "Mis à jour.".into() })));
            ctx.request_repaint();
        });
    }

    pub fn missing_emulators(&self) -> Vec<&'static catalog::Emulator> {
        catalog::EMULATORS.iter().filter(|e| !e.flatpak.is_empty() && !self.emulators.iter().any(|x| x.id() == e.id)).collect()
    }

    // ── Sauvegardes ───────────────────────────────────────────────────────

    pub fn backup_root(&self) -> Option<PathBuf> { let d = self.settings.string("backupDestination"); (!d.is_empty()).then(|| PathBuf::from(d).join(backup::FOLDER_NAME)) }
    pub fn destination_available(&self) -> bool { let d = self.settings.string("backupDestination"); !d.is_empty() && backup::is_dir(Path::new(&d)) }
    pub fn emulator_name(id: &str) -> String {
        if id == backup::ROMS_ID { "Dossiers de ROM".into() } else if id == "proton" { "Jeux Windows (Proton)".into() } else { catalog::emulator(id).map(|e| e.name.to_string()).unwrap_or(id.into()) }
    }

    pub fn refresh_backups(&mut self, ctx: &egui::Context) {
        if self.backup.scanning { return; }
        self.backup.scanning = true;
        self.backup.available = self.destination_available();
        let installed: HashSet<String> = self.emulators.iter().map(|e| e.id().to_string()).collect();
        let (prefixes, roots, root, available) = (self.prefixes(), self.settings.strings("romFolders"), self.backup_root(), self.backup.available);
        let (tx, ctx) = (self.tx.clone(), ctx.clone());
        std::thread::spawn(move || {
            let groups = scan_groups(&prefixes, &roots, root.as_deref().filter(|_| available), &installed);
            let _ = tx.send(Bg::Groups(groups, available));
            ctx.request_repaint();
        });
    }

    fn selected_folders(&self, emulator: Option<&str>) -> Vec<Folder> {
        let kinds = self.settings.strings("backupKinds");
        let ex = self.settings.strings("backupExcludedEmulators");
        self.backup.groups.iter().filter(|g| match emulator { Some(e) => g.emulator == e, None => !ex.contains(&g.emulator) })
            .flat_map(|g| g.folders.iter().map(|f| f.folder.clone())).filter(|f| kinds.iter().any(|k| k == f.kind)).collect()
    }

    pub fn run_backup(&mut self, ctx: &egui::Context, to_backup: bool, emulator: Option<String>) {
        if self.backup.running { return; }
        if self.settings.string("backupDestination").is_empty() { self.backup.message = Some("Choisissez d'abord un dossier de sauvegarde.".into()); return; }
        if !self.destination_available() { self.backup.message = Some("Le dossier de sauvegarde est introuvable — le disque est-il branché ?".into()); return; }
        let folders = self.selected_folders(emulator.as_deref());
        if folders.is_empty() { self.backup.message = Some("Rien à copier : aucun dossier de sauvegarde retenu.".into()); return; }
        self.start_backup(ctx, folders, to_backup, None, false);
    }

    /// Automatique : vers le disque, puis retour des fichiers plus récents (jamais pour un émulateur ouvert).
    pub fn run_automatically(&mut self, ctx: &egui::Context, reason: &str) {
        if !self.settings.bool("autoBackup") || self.backup.running || self.settings.string("backupDestination").is_empty() || self.scanning || self.backup.scanning { return; }
        if !self.destination_available() { self.backup.last_summary = Some(format!("Ignorée ({reason}) : disque absent.")); return; }
        let folders = self.selected_folders(None);
        if folders.is_empty() { return; }
        self.start_backup(ctx, folders, true, Some(reason.to_string()), true);
    }

    fn start_backup(&mut self, ctx: &egui::Context, folders: Vec<Folder>, to_backup: bool, reason: Option<String>, then_pull: bool) {
        let Some(root) = self.backup_root() else { return };
        self.backup.running = true;
        self.backup_cancel.store(false, Ordering::SeqCst);
        let (tx, ctx, cancel, progress, emus) = (self.tx.clone(), ctx.clone(), self.backup_cancel.clone(), self.backup_progress.clone(), self.emulators.clone());
        std::thread::spawn(move || {
            let r = perform(&root, &folders, to_backup, false, reason.as_deref(), &cancel, &progress, &ctx);
            let _ = tx.send(Bg::BackupDone { summary: Some(r.0), failures: r.1, append: false, to_backup });
            if then_pull && !cancel.load(Ordering::SeqCst) {
                let running = emulators::running_ids(&emus);
                let pulls: Vec<Folder> = folders.into_iter().filter(|f| !running.contains(f.emulator.as_str())).collect();
                if !pulls.is_empty() {
                    let r = perform(&root, &pulls, false, true, reason.as_deref(), &cancel, &progress, &ctx);
                    let _ = tx.send(Bg::BackupDone { summary: (!r.0.is_empty()).then_some(r.0), failures: r.1, append: true, to_backup: false });
                }
            }
            *progress.lock().unwrap() = String::new();
            let _ = tx.send(Bg::BackupFinished);
            ctx.request_repaint();
        });
    }
    pub fn cancel_backup(&self) { self.backup_cancel.store(true, Ordering::SeqCst); }

    /// À la fermeture : la sauvegarde, 20 secondes au plus.
    pub fn backup_on_quit(&mut self) {
        if !(self.settings.bool("autoBackup") && self.settings.bool("backupOnQuit")) || !self.destination_available() || self.backup.groups.is_empty() { return; }
        self.cancel_backup();
        let deadline = Instant::now() + Duration::from_secs(20);
        while self.backup.running && Instant::now() < deadline { if let Ok(Bg::BackupFinished) = self.rx.recv_timeout(Duration::from_millis(200)) { self.backup.running = false; } }
        let Some(root) = self.backup_root() else { return };
        let folders = self.selected_folders(None);
        let cancel = Arc::new(AtomicBool::new(false));
        let (c2, progress) = (cancel.clone(), self.backup_progress.clone());
        let ctx = egui::Context::default();
        let h = std::thread::spawn(move || { perform(&root, &folders, true, false, Some("fermeture"), &c2, &progress, &ctx); });
        while !h.is_finished() && Instant::now() < deadline { std::thread::sleep(Duration::from_millis(100)); }
        cancel.store(true, Ordering::SeqCst);
        let _ = h.join();
        self.settings.set("backupLastRun", sys::now_ms());
    }

    // ── Fenêtres de choix ─────────────────────────────────────────────────

    pub fn pick(&mut self, what: PickFor) {
        use sys::Pick;
        let roms = self.settings.strings("romFolders").first().map(PathBuf::from);
        let rx = match &what {
            PickFor::RomFolder => sys::pick(Pick::Folders, "Choisissez un dossier contenant vos ROM ou vos jeux", None, &[]),
            PickFor::Excluded => sys::pick(Pick::Folders, "Choisissez les dossiers que Biblijeu doit ignorer", roms.as_deref(), &[]),
            PickFor::AppFolder => sys::pick(Pick::Folders, "Choisissez un dossier contenant des émulateurs ou des AppImage", None, &[]),
            PickFor::Application => sys::pick(Pick::Files, "Choisissez les programmes à ajouter comme jeux (AppImage, script, .exe…)", None, &[]),
            PickFor::BackupDest => sys::pick(Pick::Folder, "Choisissez où copier les sauvegardes (un disque externe, par exemple)", None, &[]),
            PickFor::StateFile(_) => sys::pick(Pick::File, "Choisissez le fichier de sauvegarde d'état", None, &[]),
            PickFor::Artwork(_) => sys::pick(Pick::File, "Choisissez une image", None, &[("Images", &["png", "jpg", "jpeg", "webp", "gif", "svg"])]),
        };
        self.picks.push((what, rx));
    }

    fn picked(&mut self, ctx: &egui::Context, what: PickFor, paths: Vec<PathBuf>) {
        if paths.is_empty() { return; }
        match what {
            PickFor::RomFolder => self.add_to(ctx, "romFolders", paths),
            PickFor::Excluded => self.add_to(ctx, "excludedFolders", paths),
            PickFor::AppFolder => self.add_to(ctx, "applicationFolders", paths),
            PickFor::Application => self.add_to(ctx, "manualApplications", paths),
            PickFor::BackupDest => { self.settings.set("backupDestination", paths[0].to_string_lossy()); self.refresh_backups(ctx); }
            PickFor::StateFile(id) => self.update_state(&id, |s| { s.state_file_path = Some(paths[0].to_string_lossy().into()); s.resume_slot = None; }),
            PickFor::Artwork(id) => self.update_state(&id, |s| s.custom_artwork_path = Some(paths[0].to_string_lossy().into())),
        }
    }

    // ── Chaque image ──────────────────────────────────────────────────────

    pub fn pump(&mut self, ctx: &egui::Context) {
        while let Ok(m) = self.rx.try_recv() {
            match m {
                Bg::Scanned(s) => {
                    self.scanned = s.items;
                    self.emulators = s.emulators;
                    self.emu_icons = s.emu_icons;
                    self.protons = steam::protons().into_iter().map(|p| p.name).collect();
                    self.has_umu = sys::which("umu-run").is_some();
                    self.apply_overrides();
                    self.scanning = false;
                    self.scan_progress.lock().unwrap().clear();
                    self.start_watching(ctx);
                    self.refresh_backups(ctx);
                    self.check_updates(ctx, false);
                    if self.settings.bool("autoFetchArtwork") { self.fetch_artwork(ctx, false); }
                    if std::mem::take(&mut self.scan_again) { self.rescan(ctx); }
                }
                Bg::Art(id, url) => self.update_state(&id, |s| { s.artwork_missing = url.is_none(); s.artwork_url = url; }),
                Bg::ArtDone { found, total, force } => {
                    *self.art_progress.lock().unwrap() = None;
                    if force {
                        let pl = |n: usize| if n > 1 { "s" } else { "" };
                        self.info = Some(if found == 0 {
                            format!("Aucune jaquette trouvée pour {total} jeu{}. Corrigez le titre de recherche dans le panneau d'informations, ou choisissez une image à la main.", if total > 1 { "x" } else { "" })
                        } else if found == total { format!("{found} jaquette{} trouvée{}.", pl(found), pl(found)) }
                        else { format!("{found} jaquette{} trouvée{} sur {total}. Les autres sont introuvables dans l'archive libretro et sur SteamGridDB.", pl(found), pl(found)) });
                    }
                }
                Bg::Refetched(id, url, title) => {
                    let found = url.is_some();
                    self.update_state(&id, |s| { if url.is_some() { s.custom_artwork_path = None; } s.artwork_missing = url.is_none(); s.artwork_url = url; });
                    if !found { self.toast.show(format!("Aucune jaquette trouvée pour « {title} ».")); }
                }
                Bg::Candidates(id, list) => if let Some(c) = &mut self.correction { if c.id == id { c.results = Some(list); } },
                Bg::KeyTest(ok) => self.key_status = Some(Some(ok)),
                Bg::Updates(r) => {
                    self.checking_updates = false;
                    if let Some(u) = r {
                        self.flatpak_updates = u;
                        self.updates_checked_at = Some(sys::now_ms());
                        self.settings.set("flatpakUpdates", &self.flatpak_updates);
                        self.settings.set("updatesCheckedAt", self.updates_checked_at);
                        if self.settings.bool("autoInstallUpdates") {
                            // Seulement les installations personnelles : celles du système demanderaient un mot de passe.
                            let due: Vec<String> = self.emulators.iter().filter(|e| e.how == How::Flatpak && e.installation.as_deref() == Some("user")
                                && e.target.as_ref().map(|t| self.flatpak_updates.contains_key(t)).unwrap_or(false)).map(|e| e.id().to_string()).collect();
                            for id in due { self.queue_emulator(ctx, &id, false); }
                        }
                    }
                }
                Bg::EmuDone(id, r) => {
                    self.emu_busy = false;
                    self.emu_activity.lock().unwrap().remove(&id);
                    match r {
                        Ok(note) => {
                            if let Some(t) = self.emulators.iter().find(|e| e.id() == id).and_then(|e| e.target.clone()) { self.flatpak_updates.remove(&t); self.settings.set("flatpakUpdates", &self.flatpak_updates); }
                            self.emu_notes.insert(id, note);
                        }
                        Err(e) => { self.emu_problems.insert(id, format!("L'opération a échoué : {e}")); }
                    }
                    if self.emu_queue.is_empty() { self.rescan(ctx); } else { self.next_emulator(ctx); }
                }
                Bg::Groups(g, available) => {
                    self.backup.groups = g;
                    self.backup.available = available;
                    self.backup.scanning = false;
                    if !self.launch_backup_done {
                        self.launch_backup_done = true;
                        if self.settings.bool("backupOnLaunch") { self.run_automatically(ctx, "lancement"); }
                    }
                }
                Bg::BackupDone { summary, failures, append, to_backup } => {
                    if to_backup { self.settings.set("backupLastRun", sys::now_ms()); }
                    if append {
                        self.backup.last_failures.extend(failures);
                        self.backup.last_failures.truncate(8);
                        if let Some(s) = summary { self.backup.last_summary = Some(format!("{} {s}", self.backup.last_summary.clone().unwrap_or_default()).trim().to_string()); }
                    } else { self.backup.last_failures = failures; self.backup.last_summary = summary; }
                }
                Bg::BackupFinished => { self.backup.running = false; self.refresh_backups(ctx); }
            }
        }
        // Les fenêtres de choix revenues.
        let mut i = 0;
        while i < self.picks.len() {
            match self.picks[i].1.try_recv() {
                Ok(paths) => { let (w, _) = self.picks.remove(i); self.picked(ctx, w, paths); }
                Err(mpsc::TryRecvError::Disconnected) => { self.picks.remove(i); }
                Err(_) => i += 1,
            }
        }
        if !self.picks.is_empty() { ctx.request_repaint_after(Duration::from_millis(200)); }
        // Un changement dans les dossiers, trois secondes après le dernier.
        let due = self.changed.lock().unwrap().map(|t| t.elapsed() >= Duration::from_secs(3)).unwrap_or(false);
        if due { *self.changed.lock().unwrap() = None; self.rescan(ctx); }
        if let Some(t) = self.states_dirty { if t.elapsed() >= Duration::from_millis(1500) { self.save_states(); } else { ctx.request_repaint_after(Duration::from_millis(1600)); } }
        if self.backup.running || self.art_progress.lock().unwrap().is_some() || self.scanning || !self.emu_activity.lock().unwrap().is_empty() {
            ctx.request_repaint_after(Duration::from_millis(250));
        }
        // La minuterie des sauvegardes.
        if self.settings.bool("autoBackup") && self.settings.bool("backupOnInterval") {
            let minutes = self.settings.f64("backupIntervalMinutes").clamp(1.0, 1440.0) as u64;
            if self.last_auto.elapsed() >= Duration::from_secs(minutes * 60) { self.last_auto = Instant::now(); self.run_automatically(ctx, "minuterie"); }
            ctx.request_repaint_after(Duration::from_secs(30));
        }
    }

    fn run_test_script(&mut self, ctx: &egui::Context) {
        if let Ok(s) = std::env::var("BIBLIJEU_TEST") {
            for part in s.split(',') {
                if let Some(sel) = part.strip_prefix("sel:") { self.settings.set("lastSelection", sel); }
                if let Some(n) = part.strip_prefix("select:") { self.selected = self.items.iter().find(|i| i.title.to_lowercase().contains(&n.to_lowercase())).map(|i| i.id.clone()); }
                if let Some(t) = part.strip_prefix("settings:") { self.settings_tab = Some(match t { "launch" => Tab::Launch, "artwork" => Tab::Artwork, "app" => Tab::App, _ => Tab::Sources }); }
                if part == "correct" { if let Some(id) = self.selected.clone() { let q = self.item(&id).map(|i| i.title.clone()).unwrap_or_default(); self.correction = Some(Correction { id, query: q, results: None }); self.search_candidates(ctx); } }
            }
        }
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.pump(ctx);
        self.images.begin_frame(ctx);
        if !self.scanning && !self.test_done { self.test_done = true; self.run_test_script(ctx); }
        crate::views::show(self, ctx);
        self.toast.ui(ctx, &self.p);
        let p = self.p;
        self.update.ui(ctx, &mut self.settings, &p);
        self.test.ui(ctx);
    }
    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        self.save_states();
        self.backup_on_quit();
        self.update.relaunch_if_needed();
    }
}

fn mtime(m: &std::fs::Metadata) -> i64 { m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_millis() as i64).unwrap_or(0) }

fn has_exe(d: &Path, depth: u32) -> bool {
    if depth > 4 { return false; }
    let Ok(rd) = std::fs::read_dir(d) else { return false };
    let es: Vec<_> = rd.flatten().collect();
    es.iter().any(|e| e.path().is_file() && e.file_name().to_string_lossy().to_lowercase().ends_with(".exe"))
        || es.iter().any(|e| e.path().is_dir() && has_exe(&e.path(), depth + 1))
}

/// Fusionne ce que Steam sait dans ce que l'analyse des dossiers a trouvé.
fn merge_steam(mut items: Vec<Item>, games: Vec<steam::Game>, shortcuts: Vec<steam::Shortcut>) -> Vec<Item> {
    let blank = |id: String, name: &str, sys: &str, path: PathBuf, added: i64, cover: Option<PathBuf>, steam: String| Item {
        id, kind: Kind::Game, title: name.into(), sort_title: catalog::normalize(name), system: sys.into(), path, discs: vec![], region: None, languages: vec![], tags: vec![],
        size: 0, added, source_root: None, raw_name: name.into(), local_art: cover, steam_id: Some(steam), desktop_exec: None, version: None, emulator_id: None };
    for g in games {
        let mut inside: Vec<usize> = items.iter().enumerate().filter(|(_, it)| it.path.starts_with(&g.folder)).map(|(i, _)| i).collect();
        // Un dossier de jeu est un seul jeu : son .exe, pas les outils posés à côté.
        let exe = |i: usize| items[i].path.to_string_lossy().to_lowercase().ends_with(".exe");
        inside.sort_by(|&a, &b| exe(b).cmp(&exe(a)).then(items[a].path.components().count().cmp(&items[b].path.components().count())));
        let cover = steam::cover(g.app_id);
        if let Some(&keep) = inside.first() {
            let it = &mut items[keep];
            it.kind = Kind::Game; it.title = g.name.clone(); it.sort_title = catalog::normalize(&g.name); it.steam_id = Some(g.app_id.to_string());
            if it.local_art.is_none() { it.local_art = cover; }
            let drop: HashSet<usize> = inside[1..].iter().copied().collect();
            items = items.into_iter().enumerate().filter(|(i, _)| !drop.contains(i)).map(|(_, x)| x).collect();
        } else {
            let added = std::fs::metadata(&g.folder).map(|m| mtime(&m)).unwrap_or(0);
            let sys = if has_exe(&g.folder, 0) { "windows" } else { "linux" };
            items.push(blank(scanner::hash(&format!("steam:{}", g.app_id)), &g.name, sys, g.folder.clone(), added, cover, g.app_id.to_string()));
        }
    }
    for s in shortcuts {
        let cover = steam::shortcut_cover(&s);
        if let Some(it) = items.iter_mut().find(|it| it.path == s.exe) {
            it.kind = Kind::Game; it.title = s.name.clone(); it.sort_title = catalog::normalize(&s.name); it.steam_id = Some(s.game_id.clone());
            if it.local_art.is_none() { it.local_art = cover; }
        } else {
            let l = s.exe.to_string_lossy().to_lowercase();
            let win = [".exe", ".bat", ".msi", ".lnk"].iter().any(|e| l.ends_with(e));
            items.push(blank(scanner::hash(&format!("steamshortcut:{}", s.game_id)), &s.name, if win { "windows" } else { "linux" }, s.exe.clone(), 0, cover, s.game_id.clone()));
        }
    }
    items
}

/// Une commande Flatpak ; `pct` reçoit l'avancement lu dans sa sortie.
fn run_flatpak(args: &[String], mut pct: impl FnMut(u32)) -> Result<(), String> {
    use std::process::Stdio;
    let mut c = sys::clean_command("flatpak").env("LC_ALL", "C").args(args).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    let mut out = c.stdout.take().unwrap();
    let mut err = c.stderr.take().unwrap();
    let errs = std::thread::spawn(move || { let mut s = String::new(); let _ = err.read_to_string(&mut s); s });
    let mut buf = [0u8; 4096];
    let mut text = String::new();
    while let Ok(n) = out.read(&mut buf) {
        if n == 0 { break; }
        let chunk = String::from_utf8_lossy(&buf[..n]).to_string();
        for l in chunk.split(['\r', '\n']) {
            if let Some(i) = l.find('%') { let d: String = l[..i].chars().rev().take_while(|c| c.is_ascii_digit()).collect::<Vec<_>>().into_iter().rev().collect(); if let Ok(v) = d.parse() { pct(v); } }
        }
        text += &chunk;
    }
    let st = c.wait().map_err(|e| e.to_string())?;
    let e = errs.join().unwrap_or_default();
    if st.success() { Ok(()) } else { Err(format!("{text}\n{e}").trim().lines().last().unwrap_or("échec").to_string()) }
}

fn scan_groups(prefixes: &Path, roots: &[String], root: Option<&Path>, installed: &HashSet<String>) -> Vec<Group> {
    let mut folders = backup::catalog_folders(prefixes);
    folders.extend(backup::rom_folders(roots));
    let manifest: Option<Manifest> = root.and_then(|r| store::read_json(&r.join(backup::MANIFEST)));
    let mut groups: Vec<Group> = vec![];
    for f in folders {
        let (files, bytes) = backup::measure(&f.url, &f.filter);
        let backed = manifest.as_ref().and_then(|m| m.entries.get(&f.subpath).cloned());
        let g = match groups.iter_mut().position(|g| g.emulator == f.emulator) {
            Some(i) => &mut groups[i],
            None => { groups.push(Group { emulator: f.emulator.clone(), name: App::emulator_name(&f.emulator), installed: f.emulator == backup::ROMS_ID || installed.contains(&f.emulator), folders: vec![] }); groups.last_mut().unwrap() }
        };
        g.folders.push(BackupFolder { folder: f, files, bytes, backed });
    }
    groups.sort_by(|a, b| (a.emulator == backup::ROMS_ID).cmp(&(b.emulator == backup::ROMS_ID)).then(a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    groups
}

/// Une passe de copie, et son résumé.
fn perform(root: &Path, folders: &[Folder], to_backup: bool, pulling: bool, reason: Option<&str>, cancel: &AtomicBool, progress: &Mutex<String>, ctx: &egui::Context) -> (String, Vec<String>) {
    let mf = root.join(backup::MANIFEST);
    let mut manifest: Manifest = store::read_json(&mf).unwrap_or_default();
    let mut total = Outcome::default();
    let (mut changed, mut touched) = (false, 0);
    for f in folders {
        if cancel.load(Ordering::SeqCst) { total.cancelled = true; break; }
        *progress.lock().unwrap() = format!("{} — {}, {}…", if to_backup { "Sauvegarder" } else { "Restaurer" }, App::emulator_name(&f.emulator), f.title);
        ctx.request_repaint();
        let bk = root.join(&f.subpath);
        if !to_backup && !backup::is_dir(&bk) { continue; }   // rien à remettre
        let (src, dst) = if to_backup { (f.url.clone(), bk) } else { (bk, f.url.clone()) };
        let rules = if to_backup { Rules { newest_wins: true, only_existing: false } } else if pulling { Rules { newest_wins: true, only_existing: true } } else { Rules::default() };
        let out = backup::copy_tree(&src, &dst, &f.filter, rules, cancel);
        touched += 1;
        let ok = out.failures.is_empty() && !out.cancelled;
        let copied = out.copied;
        total.add(out);
        // Seule une copie complète, sans échec, est notée comme sauvegarde.
        if to_backup && ok {
            let (files, bytes) = backup::measure(&f.url, &f.filter);
            let e = backup::Entry { emulator: f.emulator.clone(), kind: f.kind.into(), source: f.url.to_string_lossy().into(), files, bytes, date: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true) };
            let old = manifest.entries.get(&f.subpath);
            if old.map(|o| copied > 0 || o.files != e.files || o.bytes != e.bytes || o.source != e.source).unwrap_or(true) { manifest.entries.insert(f.subpath.clone(), e); changed = true; }
        }
    }
    if to_backup && changed {
        // Un passage où tout était à jour ne réécrit rien sur le disque.
        manifest.updated = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        manifest.machine = backup::hostname();
        let _ = store::write_json(&mf, &manifest, false);
    }
    let failures: Vec<String> = total.failures.iter().take(8).cloned().collect();
    if pulling { return (if total.copied > 0 { format!("Repris du disque, plus récents : {} fichier(s).", total.copied) } else { String::new() }, failures); }
    let when = chrono::Local::now().format("%H:%M").to_string();
    let why = reason.map(|r| format!(" ({r})")).unwrap_or_default();
    let mut text = if total.cancelled { format!("{when} — interrompue après {} fichier(s).", total.copied) }
        else if total.copied == 0 { format!("{when}{why} — rien à copier, les {} fichiers étaient déjà à jour.", total.identical) }
        else { format!("{when}{why} — {} : {} fichier(s), {}, sur {touched} dossier(s).", if to_backup { "Sauvegardés" } else { "Restaurés" }, total.copied, sys::bytes(total.bytes)) };
    if total.kept_newer > 0 { text += &format!(" {} fichier(s) plus récent(s) {} conservé(s).", total.kept_newer, if to_backup { "sur le disque" } else { "sur ce PC" }); }
    if !total.failures.is_empty() { text += &format!(" {} échec(s).", total.failures.len()); }
    (text, failures)
}
