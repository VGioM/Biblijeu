// Biblijeu pour Linux : une bibliothèque de jeux qui regarde vos dossiers de
// ROM, vos jeux Steam et vos applications, reconnaît les consoles, retrouve les
// jaquettes et lance chaque jeu avec le bon émulateur — les jeux Windows avec
// Proton. Elle copie aussi les sauvegardes des émulateurs sur le disque choisi.
'use strict';

const { app, BrowserWindow, ipcMain, dialog, shell, Menu, clipboard } = require('electron');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');
const S = require('./shared');
const Scanner = require('./scanner');
const Emu = require('./emulators');
const Steam = require('./steam');
const Art = require('./artwork');
const Backup = require('./backup');
const { Settings, readJSON, writeJSON } = require('./store');
const SelfUpdate = require('./selfupdate');

app.setName('Biblijeu');
const REPO = 'VGioM/Biblijeu';
const home = os.homedir();
const supportDir = app.getPath('userData');
fs.mkdirSync(supportDir, { recursive: true });

const settings = new Settings(path.join(supportDir, 'settings.json'), {
  romFolders: [], excludedFolders: [],
  applicationFolders: ['~/Applications', '~/AppImages', '~/Games', '~/Emulation', '~/.local/bin'].map((p) => p.replace('~', home)),
  scanApplications: true, scanSteam: true, manualApplications: [], directLaunch: true, resumeOnLaunch: true, autoFetchArtwork: true,
  steamGridDBKey: '', preferredRegion: 'Europe', watchFolders: true, cardSize: 168, emulatorForSystem: {}, protonVersion: '',
  prefixesFolder: path.join(supportDir, 'prefixes'), backupDestination: '', autoBackup: false, backupOnInterval: true,
  backupIntervalMinutes: 30, backupOnLaunch: true, backupOnQuit: true, backupKinds: Backup.DEFAULT_KINDS, backupExcludedEmulators: [],
  autoInstallUpdates: false, lastSelection: 'all', sortOrder: 'title', showInspector: true,
});

let win = null;
const libretro = new Art.Libretro(path.join(supportDir, 'ThumbnailIndex'));
const sgdb = new Art.SteamGridDB();

// ── État de chaque jeu (favoris, historique, choix, jaquettes) ─────────────

const Play = {
  file: path.join(supportDir, 'play-state.json'),
  states: {},
  timer: null,
  load() { this.states = readJSON(this.file, {}); },
  get(id) { return this.states[id] || {}; },
  update(id, change) { const s = { ...this.get(id) }; change(s); this.states[id] = s; this.schedule(); push('states'); },
  schedule() { clearTimeout(this.timer); this.timer = setTimeout(() => this.save(), 1500); },
  // L'ancien fichier est gardé : c'est le seul état irremplaçable.
  save() { clearTimeout(this.timer); writeJSON(this.file, this.states, { backup: true }); },
};
Play.load();

// ── Envoi à l'interface ────────────────────────────────────────────────────

const M = {
  items: [], scanned: [], emulators: [], isScanning: false, scanProgress: '', isFetchingArtwork: false, artworkProgress: 0,
  errorMessage: null, infoMessage: null, flatpakUpdates: {}, updatesCheckedAt: null, isCheckingUpdates: false,
  emulatorActivity: {}, emulatorNotes: {}, emulatorProblems: {}, desktopByEmu: {},
  backup: { groups: [], isScanning: false, isRunning: false, progress: '', lastRun: null, lastSummary: null, lastFailures: [], message: null, available: false },
};

const dirty = new Set();
let pushTimer = null;
function push(...parts) {
  for (const p of parts.length ? parts : ['items', 'states', 'status']) dirty.add(p);
  if (pushTimer) return;
  pushTimer = setTimeout(() => {
    pushTimer = null;
    if (!win || win.isDestroyed()) { dirty.clear(); return; }
    const msg = {};
    if (dirty.has('items')) { msg.items = M.items; msg.emulators = M.emulators.map(publicEmulator); }
    if (dirty.has('states')) msg.states = Play.states;
    msg.status = {
      isScanning: M.isScanning, scanProgress: M.scanProgress, isFetchingArtwork: M.isFetchingArtwork, artworkProgress: M.artworkProgress,
      errorMessage: M.errorMessage, infoMessage: M.infoMessage, settings: settings.all(), flatpakUpdates: M.flatpakUpdates,
      updatesCheckedAt: M.updatesCheckedAt, isCheckingUpdates: M.isCheckingUpdates, emulatorActivity: M.emulatorActivity,
      emulatorNotes: M.emulatorNotes, emulatorProblems: M.emulatorProblems, backup: M.backup, protons: Steam.protonBuilds().map((b) => b.name),
      hasFlatpak: !!Emu.which('flatpak'), hasUmu: !!Emu.which('umu-run'), autoUpdate: SelfUpdate.automatic(), version: app.getVersion(),
      missing: missingEmulators(), kinds: Backup.KINDS,
    };
    dirty.clear();
    win.webContents.send('state', msg);
  }, 80);
}

const publicEmulator = (e) => ({ id: e.id, name: e.name, kind: e.kind, target: e.target, version: e.version, installation: e.installation,
  systems: e.spec.systems, homepage: e.spec.homepage, github: e.spec.github, flatpak: e.spec.flatpak, resume: S.resumeSupported(e.spec),
  resumeKinds: Object.keys(e.spec.resume || {}), icon: M.desktopByEmu[e.id] && M.desktopByEmu[e.id].icon });

// ── Analyse ────────────────────────────────────────────────────────────────

/** Fusionne ce que Steam sait dans ce que l'analyse des dossiers a trouvé. */
function mergeSteam(scanned, games, shortcuts) {
  let items = scanned;
  for (const g of games) {
    const prefix = g.folder + '/';
    const inside = items.map((it, i) => (it.path.startsWith(prefix) ? i : -1)).filter((i) => i >= 0);
    // Un dossier de jeu est un seul jeu : son .exe, pas les outils posés à côté.
    const ranked = inside.sort((a, b) => {
      const ae = /\.exe$/i.test(items[a].path), be = /\.exe$/i.test(items[b].path);
      return ae !== be ? (ae ? -1 : 1) : items[a].path.split('/').length - items[b].path.split('/').length;
    });
    const keep = ranked[0];
    const cover = Steam.cover(g.appID);
    if (keep != null) {
      Object.assign(items[keep], { kind: 'game', title: g.name, sortTitle: S.normalize(g.name), steamGameID: String(g.appID), localArtwork: items[keep].localArtwork || cover });
      const drop = new Set(inside.filter((i) => i !== keep));
      items = items.filter((_, i) => !drop.has(i));
    } else {
      let st; try { st = fs.statSync(g.folder); } catch { st = { mtimeMs: 0 }; }
      items.push({ id: Scanner.hash('steam:' + g.appID), kind: 'game', title: g.name, sortTitle: S.normalize(g.name),
        systemID: hasExe(g.folder) ? 'windows' : 'linux', path: g.folder, discs: [], region: null, languages: [], tags: [], fileSize: 0,
        dateAdded: st.mtimeMs, sourceRoot: null, rawName: g.name, localArtwork: cover, steamGameID: String(g.appID), desktopExec: null });
    }
  }
  for (const s of shortcuts) {
    const i = items.findIndex((it) => it.path === s.executable);
    const cover = Steam.shortcutCover(s);
    if (i >= 0) Object.assign(items[i], { kind: 'game', title: s.name, sortTitle: S.normalize(s.name), steamGameID: s.gameID, localArtwork: items[i].localArtwork || cover });
    else {
      const windows = /\.(exe|bat|msi|lnk)$/i.test(s.executable);
      items.push({ id: Scanner.hash('steamshortcut:' + s.gameID), kind: 'game', title: s.name, sortTitle: S.normalize(s.name),
        systemID: windows ? 'windows' : 'linux', path: s.executable, discs: [], region: null, languages: [], tags: [], fileSize: 0,
        dateAdded: 0, sourceRoot: null, rawName: s.name, localArtwork: cover, steamGameID: s.gameID, desktopExec: null });
    }
  }
  return items;
}

function hasExe(dir, depth = 0) {
  if (depth > 4) return false;
  let entries; try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return false; }
  if (entries.some((e) => e.isFile() && /\.exe$/i.test(e.name))) return true;
  return entries.some((e) => e.isDirectory() && hasExe(path.join(dir, e.name), depth + 1));
}

function emulatorItem(e) {
  const d = M.desktopByEmu[e.id];
  return { id: Scanner.hash('emulator:' + e.id), kind: 'emulator', title: e.name, sortTitle: S.normalize(e.name), systemID: '', path: e.target || '',
    discs: [], region: null, languages: [], tags: [], fileSize: 0, dateAdded: 0, sourceRoot: null, rawName: e.name,
    localArtwork: d && d.icon, steamGameID: null, desktopExec: d ? Scanner.parseDesktop(d.file).Exec : null, appVersion: e.version, emulatorID: e.id };
}

let scanning = false, scanAgain = false;
async function rescan() {
  if (scanning) { scanAgain = true; return; }
  scanning = true;
  M.isScanning = true; M.scanProgress = 'Analyse…';
  push('status');
  const report = (t) => { M.scanProgress = t; push('status'); };
  await new Promise((r) => setImmediate(r));
  try {
    let found = Scanner.scanRoms(settings.get('romFolders'), settings.get('excludedFolders'), report);
    if (settings.get('scanSteam')) {
      report('Lecture de la bibliothèque Steam…');
      found = mergeSteam(found, Steam.installedGames(), Steam.shortcuts());
    }
    const apps = Scanner.scanApplications();
    M.desktopByEmu = apps.desktopByEmu;
    if (settings.get('scanApplications')) found.push(...apps.games);
    for (const p of settings.get('manualApplications')) {
      if (!fs.existsSync(p)) continue;
      const it = p.endsWith('.desktop') ? apps.games.find((g) => g.path === p) : null;
      if (it) continue;
      const st = fs.statSync(p);
      found.unshift({ id: Scanner.identifier(p, st.size), kind: 'game', title: path.basename(p).replace(/\.(appimage|x86_64|sh)$/i, ''),
        sortTitle: S.normalize(path.basename(p)), systemID: /\.exe$/i.test(p) ? 'windows' : 'linux', path: p, discs: [], region: null, languages: [], tags: [],
        fileSize: st.size, dateAdded: st.mtimeMs, sourceRoot: null, rawName: path.basename(p), localArtwork: null, steamGameID: null, desktopExec: null });
    }
    report('Recherche des émulateurs…');
    M.emulators = Emu.detect(settings.get('applicationFolders'));
    found.push(...M.emulators.filter((e) => e.kind !== 'proton').map(emulatorItem));
    const seen = new Set();
    M.scanned = found.filter((it) => !seen.has(it.id) && seen.add(it.id)).sort((a, b) => S.collator.compare(a.sortTitle, b.sortTitle));
    applyOverrides();
  } catch (e) {
    M.errorMessage = `L'analyse a échoué : ${e.message}`;
  } finally {
    M.isScanning = false; M.scanProgress = '';
    scanning = false;
    push();
  }
  startWatching();
  refreshBackups();
  checkUpdates(false);
  if (settings.get('autoFetchArtwork')) fetchArtwork(false);
  if (scanAgain) { scanAgain = false; rescan(); }
}

/** Les corrections de l'utilisateur par-dessus l'analyse. */
function applyOverrides() {
  M.items = M.scanned.map((it) => {
    const st = Play.get(it.id);
    const out = { ...it };
    if (st.kindOverride) out.kind = st.kindOverride;
    if (st.systemOverride && S.SYSTEM_BY_ID[st.systemOverride]) out.systemID = st.systemOverride;
    return out;
  });
  push('items');
}

// ── Surveillance des dossiers ──────────────────────────────────────────────

let watchers = [], watchTimer = null;
function startWatching() {
  for (const w of watchers) w.close();
  watchers = [];
  if (!settings.get('watchFolders')) return;
  const roots = settings.get('romFolders').filter((p) => fs.existsSync(p));
  const trigger = () => { clearTimeout(watchTimer); watchTimer = setTimeout(rescan, 3000); };
  for (const r of roots) {
    try {
      const w = fs.watch(r, { recursive: true }, (_ev, name) => {
        const full = name ? path.join(r, name.toString()) : r;
        if (!Scanner.ignoresChange(full, roots, settings.get('excludedFolders'))) trigger();
      });
      w.on('error', () => {});
      watchers.push(w);
    } catch { /* dossier illisible */ }
  }
  // Steam : seulement un manifeste de jeu ajouté ou retiré, pas ses écritures permanentes.
  if (settings.get('scanSteam')) {
    for (const lib of Steam.libraries()) {
      try {
        const w = fs.watch(lib, (_ev, name) => { if (name && /^appmanifest_\d+\.acf$/.test(name.toString())) trigger(); });
        w.on('error', () => {});
        watchers.push(w);
      } catch { /* bibliothèque absente */ }
    }
  }
}

// ── Émulateurs ─────────────────────────────────────────────────────────────

function emulatorFor(item) {
  if (item.kind !== 'rom') return null;
  const st = Play.get(item.id);
  const byId = (id) => M.emulators.find((e) => e.id === id && e.spec.systems.includes(item.systemID)) || (st.emulatorID === id ? M.emulators.find((e) => e.id === id) : null);
  if (st.emulatorID && byId(st.emulatorID)) return byId(st.emulatorID);
  const s = S.SYSTEM_BY_ID[item.systemID];
  if (!s) return null;
  const pref = settings.get('emulatorForSystem')[s.id];
  if (pref && byId(pref)) return byId(pref);
  for (const id of s.emulators) { const e = M.emulators.find((x) => x.id === id); if (e) return e; }
  return M.emulators.find((e) => e.spec.systems.includes(s.id)) || null;
}

/** Ce que « Reprendre » veut dire pour ce jeu : le fichier choisi, l'emplacement choisi, ou la dernière sauvegarde. */
function resumeRequest(item) {
  const e = emulatorFor(item);
  if (!e) return { type: 'fromStart' };
  const st = Play.get(item.id);
  const wanted = [];
  if (st.stateFilePath) wanted.push({ type: 'file', path: st.stateFilePath });
  if (st.resumeSlot) wanted.push({ type: 'slot', slot: st.resumeSlot });
  wanted.push({ type: 'auto' });
  return wanted.find((r) => S.resumeArguments(e.spec, r) && r.type !== 'fromStart' && (r.type !== 'auto' || e.spec.resume.auto)) || { type: 'fromStart' };
}

function planFor(item, opts = {}) {
  const st = Play.get(item.id);
  const resume = opts.resume || (settings.get('resumeOnLaunch') ? resumeRequest(item) : { type: 'fromStart' });
  return Emu.plan(item, {
    emulator: opts.emulator || emulatorFor(item), direct: settings.get('directLaunch'), disc: opts.disc, resume,
    protonName: st.protonVersion || settings.get('protonVersion'), prefixesRoot: settings.get('prefixesFolder'),
  });
}

function play(id, opts = {}) {
  const item = M.items.find((i) => i.id === id);
  if (!item) return;
  if (opts.emulatorID) opts.emulator = M.emulators.find((e) => e.id === opts.emulatorID);
  if (opts.resumeFromStart) opts.resume = { type: 'fromStart' };
  const p = planFor(item, opts);
  if (p.error) { M.errorMessage = p.error; push('status'); return; }
  Emu.run(p, shell, (e) => { M.errorMessage = `${item.title} n'a pas pu démarrer.\n${e.message}`; push('status'); });
  Play.update(id, (s) => { s.lastPlayed = Date.now(); s.playCount = (s.playCount || 0) + 1; });
}

// ── Jaquettes ──────────────────────────────────────────────────────────────

const hasNoCover = (it) => {
  if (!(it.kind === 'rom' || it.steamGameID || it.systemID === 'windows')) return false;
  if (it.localArtwork) return false;
  const st = Play.get(it.id);
  return !st.customArtworkPath && !st.artworkURL;
};

async function fetchArtwork(force) {
  if (M.isFetchingArtwork) { if (force) { M.infoMessage = 'Une recherche de jaquettes est déjà en cours.'; push('status'); } return; }
  const pending = M.items.filter((it) => hasNoCover(it) && (force || !Play.get(it.id).artworkMissing));
  if (!pending.length) { if (force) { M.infoMessage = 'Aucune jaquette manquante : tous les jeux en ont une.'; push('status'); } return; }
  M.isFetchingArtwork = true; M.artworkProgress = 0;
  push('status');
  const region = settings.get('preferredRegion'), key = settings.get('steamGridDBKey');
  let next = 0, done = 0, found = 0;
  // Quatre à la fois : de quoi occuper la connexion, sans brusquer une archive publique.
  const worker = async () => {
    while (next < pending.length) {
      const it = pending[next++];
      let url = null;
      try { url = await Art.lookup(libretro, sgdb, it, Play.get(it.id).searchTitle, region, key); } catch { url = null; }
      Play.update(it.id, (s) => { s.artworkURL = url; s.artworkMissing = !url; });
      if (url) found++;
      done++;
      M.artworkProgress = done / pending.length;
      push('status');
    }
  };
  await Promise.all([worker(), worker(), worker(), worker()]);
  M.isFetchingArtwork = false; M.artworkProgress = 0;
  if (force) {
    const total = pending.length, pl = (n) => (n > 1 ? 's' : '');
    M.infoMessage = !found
      ? `Aucune jaquette trouvée pour ${total} jeu${total > 1 ? 'x' : ''}. Corrigez le titre de recherche dans le panneau d'informations, ou choisissez une image à la main.`
      : found === total ? `${found} jaquette${pl(found)} trouvée${pl(found)}.`
        : `${found} jaquette${pl(found)} trouvée${pl(found)} sur ${total}. Les autres sont introuvables dans l'archive libretro et sur SteamGridDB.`;
  }
  push('status');
}

// ── Mises à jour des émulateurs (Flatpak) ──────────────────────────────────

function runFlatpak(args, onLine) {
  return new Promise((resolve) => {
    const p = spawn('flatpak', args, { env: { ...process.env, LC_ALL: 'C' } });
    let out = '';
    const take = (d) => { out += d; for (const l of d.toString().split(/[\r\n]/)) if (l.trim() && onLine) onLine(l.trim()); };
    p.stdout.on('data', take); p.stderr.on('data', take);
    p.on('error', (e) => resolve({ code: -1, out: e.message }));
    p.on('close', (code) => resolve({ code, out }));
  });
}

/** Une fois par jour civil : les Flatpak d'émulateurs qui ont une mise à jour en attente. */
async function checkUpdates(force) {
  if (M.isCheckingUpdates || !Emu.which('flatpak')) return;
  const last = settings.get('updatesCheckedAt', 0);
  const cached = settings.get('flatpakUpdates', {});
  M.flatpakUpdates = cached; M.updatesCheckedAt = last || null;
  if (!force && last && new Date(last).toDateString() === new Date().toDateString()) { push('status'); return; }
  M.isCheckingUpdates = true; push('status');
  const r = await runFlatpak(['remote-ls', '--updates', '--app', '--columns=application,version']);
  const ids = new Set(M.emulators.filter((e) => e.kind === 'flatpak').map((e) => e.target));
  const updates = {};
  if (r.code === 0) for (const line of r.out.split('\n')) { const [id, v] = line.split('\t'); if (id && ids.has(id.trim())) updates[id.trim()] = (v || '').trim() || 'nouvelle version'; }
  M.flatpakUpdates = updates; M.updatesCheckedAt = Date.now();
  settings.set('flatpakUpdates', updates); settings.set('updatesCheckedAt', M.updatesCheckedAt);
  M.isCheckingUpdates = false;
  push('status');
  if (settings.get('autoInstallUpdates')) {
    // Seulement les installations personnelles : celles du système demanderaient un mot de passe sans prévenir.
    const due = M.emulators.filter((e) => e.kind === 'flatpak' && updates[e.target] && e.installation === 'user');
    for (const e of due) await updateEmulator(e.id);
  }
}

async function updateEmulator(id) {
  const e = M.emulators.find((x) => x.id === id);
  if (!e || e.kind !== 'flatpak') return;
  if (Emu.runningEmulatorIDs([e]).has(id)) { M.emulatorProblems[id] = `${e.name} est ouvert : quittez-le, puis réessayez.`; push('status'); return; }
  delete M.emulatorProblems[id]; delete M.emulatorNotes[id];
  M.emulatorActivity[id] = 'Mise à jour…'; push('status');
  const args = ['update', '-y', '--noninteractive', ...(e.installation === 'user' ? ['--user'] : ['--system']), e.target];
  const r = await runFlatpak(args, (l) => { const m = /(\d+)%/.exec(l); if (m) { M.emulatorActivity[id] = `Mise à jour ${m[1]} %`; push('status'); } });
  delete M.emulatorActivity[id];
  if (r.code === 0) { M.emulatorNotes[id] = 'Mis à jour.'; delete M.flatpakUpdates[e.target]; settings.set('flatpakUpdates', M.flatpakUpdates); }
  else M.emulatorProblems[id] = `La mise à jour a échoué : ${r.out.trim().split('\n').pop()}`;
  push('status');
  rescan();
}

/** Les émulateurs du catalogue absents de ce PC qui existent en Flatpak. */
function missingEmulators() {
  const have = new Set(M.emulators.map((e) => e.id));
  return S.EMULATORS.filter((e) => e.flatpak.length && !have.has(e.id)).map((e) => ({ id: e.id, name: e.name, flatpak: e.flatpak[0], systems: e.systems, homepage: e.homepage, github: e.github }));
}

async function installEmulator(id) {
  const spec = S.EMULATOR_BY_ID[id];
  if (!spec || !spec.flatpak.length) return;
  delete M.emulatorProblems[id]; delete M.emulatorNotes[id];
  M.emulatorActivity[id] = 'Installation…'; push('status');
  // Pour l'utilisateur d'abord (sans mot de passe) ; sinon pour le système, où Flathub est souvent configuré.
  let r = await runFlatpak(['install', '-y', '--noninteractive', '--user', 'flathub', spec.flatpak[0]],
    (l) => { const m = /(\d+)%/.exec(l); if (m) { M.emulatorActivity[id] = `Installation ${m[1]} %`; push('status'); } });
  if (r.code !== 0) {
    r = await runFlatpak(['install', '-y', '--noninteractive', '--system', 'flathub', spec.flatpak[0]],
      (l) => { const m = /(\d+)%/.exec(l); if (m) { M.emulatorActivity[id] = `Installation ${m[1]} %`; push('status'); } });
  }
  delete M.emulatorActivity[id];
  if (r.code === 0) M.emulatorNotes[id] = `${spec.name} installé depuis Flathub.`;
  else M.emulatorProblems[id] = `L'installation a échoué : ${r.out.trim().split('\n').pop()}`;
  push('status');
  rescan();
}

// ── Sauvegardes ────────────────────────────────────────────────────────────

let backupRunning = null, backupTimer = null, backupScan = null;
const backupRoot = () => {
  const d = settings.get('backupDestination');
  return d ? path.join(d, Backup.FOLDER_NAME) : null;
};
const destinationAvailable = () => { const d = settings.get('backupDestination'); return !!d && Backup.isDir(d); };
const emulatorName = (id) => (id === Backup.ROMS_ID ? 'Dossiers de ROM' : id === 'proton' ? 'Jeux Windows (Proton)'
  : (S.EMULATOR_BY_ID[id] && S.EMULATOR_BY_ID[id].name) || id);

/** Relit les dossiers de sauvegarde présents et ce que le disque en contient. */
function refreshBackups() {
  if (backupScan) return backupScan;
  backupScan = (async () => {
    M.backup.isScanning = true; M.backup.available = destinationAvailable(); push('status');
    const installed = new Set(M.emulators.map((e) => e.id));
    const folders = [...Backup.catalogFolders([...installed], settings.get('prefixesFolder')), ...Backup.romFolders(settings.get('romFolders'))];
    const root = backupRoot();
    const manifest = root && M.backup.available ? readJSON(path.join(root, Backup.MANIFEST), null) : null;
    const groups = new Map();
    for (const f of folders) {
      const m = await Backup.measure(f.url, f.filter);
      if (!groups.has(f.emulatorID)) groups.set(f.emulatorID, { emulatorID: f.emulatorID, name: emulatorName(f.emulatorID), isInstalled: f.emulatorID === Backup.ROMS_ID || installed.has(f.emulatorID), folders: [] });
      groups.get(f.emulatorID).folders.push({ folder: f, files: m.files, bytes: m.bytes, backed: manifest && manifest.entries ? manifest.entries[f.backupSubpath] || null : null });
    }
    M.backup.groups = [...groups.values()].sort((a, b) => (a.emulatorID === Backup.ROMS_ID) - (b.emulatorID === Backup.ROMS_ID) || S.collator.compare(a.name, b.name));
    M.backup.isScanning = false;
    M.backup.lastRun = settings.get('backupLastRun', null);
    push('status');
  })().finally(() => { backupScan = null; });
  return backupScan;
}

function selectedFolders(emulatorID) {
  const kinds = settings.get('backupKinds'), excluded = settings.get('backupExcludedEmulators');
  return M.backup.groups.filter((g) => (emulatorID ? g.emulatorID === emulatorID : !excluded.includes(g.emulatorID)))
    .flatMap((g) => g.folders.map((f) => f.folder)).filter((f) => kinds.includes(f.kind));
}

async function performBackup(direction, folders, { reason, pullingNewer, signal } = {}) {
  const root = backupRoot();
  const manifestFile = path.join(root, Backup.MANIFEST);
  const manifest = readJSON(manifestFile, null) || { updated: new Date().toISOString(), machine: os.hostname(), entries: {} };
  const total = { copied: 0, identical: 0, keptNewer: 0, bytes: 0, failures: [], cancelled: false };
  let changed = false, touched = 0;
  for (const f of folders) {
    if (signal && signal.aborted) { total.cancelled = true; break; }
    M.backup.progress = `${direction === 'toBackup' ? 'Sauvegarder' : 'Restaurer'} — ${emulatorName(f.emulatorID)}, ${f.title}…`;
    push('status');
    const backup = path.join(root, f.backupSubpath);
    if (direction === 'toEmulator' && !Backup.isDir(backup)) continue;   // rien à remettre
    const [src, dst] = direction === 'toBackup' ? [f.url, backup] : [backup, f.url];
    const rules = direction === 'toBackup' ? { newestWins: true } : pullingNewer ? { newestWins: true, onlyExisting: true } : {};
    const out = await Backup.copyTree(src, dst, f.filter, rules, signal);
    touched++;
    for (const k of ['copied', 'identical', 'keptNewer', 'bytes']) total[k] += out[k];
    total.failures.push(...out.failures);
    if (out.cancelled) total.cancelled = true;
    // Seule une copie complète, sans échec, est notée comme sauvegarde.
    if (direction === 'toBackup' && !out.failures.length && !out.cancelled) {
      const m = await Backup.measure(f.url, f.filter);
      const entry = { emulator: f.emulatorID, kind: f.kind, source: f.url, files: m.files, bytes: m.bytes, date: new Date().toISOString() };
      const old = manifest.entries[f.backupSubpath];
      if (!old || out.copied > 0 || old.files !== entry.files || old.bytes !== entry.bytes || old.source !== entry.source) { manifest.entries[f.backupSubpath] = entry; changed = true; }
    }
  }
  if (direction === 'toBackup') {
    // Un passage où tout était à jour ne réécrit rien sur le disque.
    if (changed) { manifest.updated = new Date().toISOString(); manifest.machine = os.hostname(); writeJSON(manifestFile, manifest); }
    settings.set('backupLastRun', Date.now());
  }
  const when = new Date().toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
  const why = reason ? ` (${reason})` : '';
  if (pullingNewer) {
    M.backup.lastFailures = [...M.backup.lastFailures, ...total.failures].slice(0, 8);
    if (total.copied) M.backup.lastSummary = `${M.backup.lastSummary || ''} Repris du disque, plus récents : ${total.copied} fichier(s).`.trim();
  } else {
    M.backup.lastFailures = total.failures.slice(0, 8);
    let text;
    if (total.cancelled) text = `${when} — interrompue après ${total.copied} fichier(s).`;
    else if (!total.copied) text = `${when}${why} — rien à copier, les ${total.identical} fichiers étaient déjà à jour.`;
    else text = `${when}${why} — ${direction === 'toBackup' ? 'Sauvegardés' : 'Restaurés'} : ${total.copied} fichier(s), ${S.bytes(total.bytes)}, sur ${touched} dossier(s).`;
    if (total.keptNewer) text += ` ${total.keptNewer} fichier(s) plus récent(s) ${direction === 'toBackup' ? 'sur le disque' : 'sur ce PC'} conservé(s).`;
    if (total.failures.length) text += ` ${total.failures.length} échec(s).`;
    M.backup.lastSummary = text;
  }
  M.backup.progress = '';
  push('status');
}

async function runBackup(direction, emulatorID) {
  if (backupRunning) return;
  if (!settings.get('backupDestination')) { M.backup.message = "Choisissez d'abord un dossier de sauvegarde."; push('status'); return; }
  if (!destinationAvailable()) { M.backup.message = 'Le dossier de sauvegarde est introuvable — le disque est-il branché ?'; push('status'); return; }
  const ctl = new AbortController();
  backupRunning = ctl; M.backup.isRunning = true; push('status');
  try {
    await refreshBackups();
    const folders = selectedFolders(emulatorID);
    if (!folders.length) { M.backup.message = 'Rien à copier : aucun dossier de sauvegarde retenu.'; return; }
    await performBackup(direction, folders, { signal: ctl.signal });
  } finally {
    backupRunning = null; M.backup.isRunning = false; M.backup.progress = '';
    await refreshBackups();
  }
}

/** Automatique : vers le disque, puis retour des fichiers plus récents sur le disque (jamais pour un émulateur ouvert). */
async function runAutomatically(reason, signal) {
  if (!settings.get('autoBackup') || backupRunning || !settings.get('backupDestination')) return;
  if (!destinationAvailable()) { M.backup.lastSummary = `Ignorée (${reason}) : disque absent.`; push('status'); return; }
  const ctl = signal ? { signal, abort() {} } : new AbortController();
  backupRunning = ctl; M.backup.isRunning = true; push('status');
  try {
    // Une analyse en cours s'attend : avant elle, la liste est vide.
    while (scanning) await new Promise((r) => setTimeout(r, 300));
    await refreshBackups();
    const folders = selectedFolders();
    if (!folders.length) return;
    await performBackup('toBackup', folders, { reason, signal: ctl.signal });
    const running = Emu.runningEmulatorIDs(M.emulators);
    const pulls = folders.filter((f) => !running.has(f.emulatorID));
    if (!ctl.signal.aborted && pulls.length) await performBackup('toEmulator', pulls, { reason, pullingNewer: true, signal: ctl.signal });
  } finally {
    backupRunning = null; M.backup.isRunning = false; M.backup.progress = '';
    refreshBackups();
  }
}

function rescheduleBackups() {
  clearInterval(backupTimer);
  if (settings.get('autoBackup') && settings.get('backupOnInterval')) {
    const minutes = Math.min(Math.max(settings.get('backupIntervalMinutes') || 30, 1), 1440);
    backupTimer = setInterval(() => runAutomatically('minuterie'), minutes * 60000);
  }
}

// ── Canaux de l'interface ──────────────────────────────────────────────────

const pickFolders = async (title, multi = true, defaultPath) => {
  const r = await dialog.showOpenDialog(win, { title, defaultPath, properties: ['openDirectory', 'createDirectory', ...(multi ? ['multiSelections'] : [])] });
  return r.canceled ? [] : r.filePaths;
};
const addTo = (key, paths) => { const list = settings.get(key).slice(); for (const p of paths) if (!list.includes(p)) list.push(p); settings.set(key, list); };
const item = (id) => M.items.find((i) => i.id === id);

const calls = {
  ready: () => push(),
  rescan: () => rescan(),
  addRomFolder: async () => { const p = await pickFolders('Choisissez un dossier contenant vos ROM ou vos jeux'); if (p.length) { addTo('romFolders', p); rescan(); } },
  removeRomFolder: (p) => { settings.set('romFolders', settings.get('romFolders').filter((x) => x !== p)); rescan(); },
  addExcludedFolder: async () => { const p = await pickFolders('Choisissez les dossiers que Biblijeu doit ignorer', true, settings.get('romFolders')[0]); if (p.length) { addTo('excludedFolders', p); rescan(); } },
  removeExcludedFolder: (p) => { settings.set('excludedFolders', settings.get('excludedFolders').filter((x) => x !== p)); rescan(); },
  addApplicationFolder: async () => { const p = await pickFolders('Choisissez un dossier contenant des émulateurs ou des AppImage'); if (p.length) { addTo('applicationFolders', p); rescan(); } },
  removeApplicationFolder: (p) => { settings.set('applicationFolders', settings.get('applicationFolders').filter((x) => x !== p)); rescan(); },
  addApplication: async () => {
    const r = await dialog.showOpenDialog(win, { title: 'Choisissez les programmes à ajouter comme jeux (AppImage, script, .exe…)', properties: ['openFile', 'multiSelections'] });
    if (!r.canceled) { addTo('manualApplications', r.filePaths); rescan(); }
  },
  removeManualApplication: (p) => { settings.set('manualApplications', settings.get('manualApplications').filter((x) => x !== p)); rescan(); },
  play: (id, opts) => play(id, opts || {}),
  plan: (id, opts) => { const it = item(id); if (!it) return null; const p = planFor(it, opts || {}); return { preview: p.preview || null, error: p.error || null }; },
  resumeInfo: (id) => { const it = item(id); if (!it) return null; const r = settings.get('resumeOnLaunch') ? resumeRequest(it) : { type: 'fromStart' }; return { request: r, emulator: emulatorFor(it) && emulatorFor(it).id }; },
  reveal: (id) => { const it = item(id); if (it) shell.showItemInFolder(it.path); },
  revealPath: (p) => shell.showItemInFolder(p),
  openPath: (p) => shell.openPath(p),
  copyText: (t) => clipboard.writeText(t),
  update: (id, patch) => {
    Play.update(id, (s) => Object.assign(s, patch));
    if ('kindOverride' in patch || 'systemOverride' in patch) applyOverrides();
  },
  chooseStateFile: async (id) => {
    const r = await dialog.showOpenDialog(win, { title: 'Choisissez le fichier de sauvegarde d\'état', properties: ['openFile'] });
    if (!r.canceled && r.filePaths[0]) Play.update(id, (s) => { s.stateFilePath = r.filePaths[0]; s.resumeSlot = null; });
  },
  chooseArtwork: async (id) => {
    const r = await dialog.showOpenDialog(win, { title: 'Choisissez une image', properties: ['openFile'], filters: [{ name: 'Images', extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'svg'] }] });
    if (!r.canceled && r.filePaths[0]) Play.update(id, (s) => { s.customArtworkPath = r.filePaths[0]; });
  },
  refetchArtwork: async (id, title) => {
    const it = item(id); if (!it) return;
    if (title) Play.update(id, (s) => { s.searchTitle = title; });
    const url = await Art.lookup(libretro, sgdb, it, title || Play.get(id).searchTitle, settings.get('preferredRegion'), settings.get('steamGridDBKey'));
    Play.update(id, (s) => { s.artworkURL = url; s.artworkMissing = !url; s.customArtworkPath = url ? null : s.customArtworkPath; });
    if (!url) { M.infoMessage = `Aucune jaquette trouvée pour « ${title || it.title} ».`; push('status'); }
  },
  artworkCandidates: (id, title) => { const it = item(id); return it ? Art.candidates(libretro, sgdb, it, title && title.trim(), settings.get('preferredRegion'), settings.get('steamGridDBKey')) : []; },
  applyArtwork: (id, url, title) => Play.update(id, (s) => { s.artworkURL = url; s.artworkMissing = false; s.customArtworkPath = null; if (title && title.trim()) s.searchTitle = title.trim(); }),
  fetchArtwork: () => fetchArtwork(true),
  clearArtworkCache: async () => {
    for (const s of Object.values(Play.states)) { delete s.artworkURL; delete s.artworkMissing; }
    Play.schedule(); libretro.clear();
    const { session } = require('electron');
    await session.defaultSession.clearCache();
    push('states'); fetchArtwork(false);
  },
  testSGDBKey: () => sgdb.validate(settings.get('steamGridDBKey')),
  clearHistory: () => { for (const s of Object.values(Play.states)) { delete s.lastPlayed; s.playCount = 0; } Play.schedule(); push('states'); },
  setSetting: (key, value) => {
    settings.set(key, value);
    if (['romFolders', 'excludedFolders', 'applicationFolders', 'scanApplications', 'scanSteam'].includes(key)) rescan();
    if (key === 'watchFolders') startWatching();
    if (key.startsWith('backup') || key === 'autoBackup') { rescheduleBackups(); refreshBackups(); }
    push('status');
  },
  checkUpdates: () => checkUpdates(true),
  updateEmulator: (id) => updateEmulator(id),
  updateAll: async () => { for (const e of M.emulators.filter((x) => x.kind === 'flatpak' && M.flatpakUpdates[x.target])) await updateEmulator(e.id); },
  installEmulator: (id) => installEmulator(id),
  chooseBackupDestination: async () => {
    const p = await pickFolders('Choisissez où copier les sauvegardes (un disque externe, par exemple)', false);
    if (p[0]) { settings.set('backupDestination', p[0]); refreshBackups(); rescheduleBackups(); push('status'); }
  },
  forgetBackupDestination: () => { settings.set('backupDestination', ''); refreshBackups(); push('status'); },
  refreshBackups: () => refreshBackups(),
  runBackup: (direction, emulatorID) => runBackup(direction, emulatorID || null),
  confirmRestore: async (name) => {
    const r = await dialog.showMessageBox(win, {
      type: 'warning', message: `Restaurer ${name} ?`,
      detail: 'Tout ce que contient le disque est remis en place, même plus ancien que ce qui est sur ce PC. Les fichiers de ce PC qui ne sont pas sur le disque ne sont pas touchés.',
      buttons: ['Restaurer', 'Annuler'], defaultId: 1, cancelId: 1,
    });
    return r.response === 0;
  },
  cancelBackup: () => { if (backupRunning) backupRunning.abort(); },
  clearBackupMessage: () => { M.backup.message = null; push('status'); },
  backupFolderPath: (sub) => { const r = backupRoot(); return r ? path.join(r, sub || '') : null; },
  clearMessages: () => { M.errorMessage = null; M.infoMessage = null; push('status'); },
  setAutoUpdate: (on) => { SelfUpdate.setAutomatic(on); buildMenu(); push('status'); },
  checkAppUpdates: () => SelfUpdate.checkNow(),
  openExternal: (url) => { if (/^https:\/\//.test(url)) shell.openExternal(url); },
  prefixPath: (id) => { const it = item(id); return it ? Emu.prefixFor(it, settings.get('prefixesFolder')) : null; },
};

ipcMain.handle('call', async (_e, channel, ...args) => {
  const fn = calls[channel];
  if (!fn) throw new Error(`canal inconnu : ${channel}`);
  return fn(...args);
});

// ── Fenêtre, menus, fermeture ──────────────────────────────────────────────

const send = (ev, ...a) => win && win.webContents.send(ev, ...a);

function buildMenu() {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Fichier', submenu: [
      { label: 'Ajouter un dossier de ROM…', accelerator: 'CmdOrCtrl+O', click: () => calls.addRomFolder() },
      { label: 'Ajouter une application…', click: () => calls.addApplication() },
      { label: 'Analyser à nouveau', accelerator: 'CmdOrCtrl+R', click: () => rescan() },
      { label: 'Rechercher les jaquettes manquantes', click: () => fetchArtwork(true) },
      { type: 'separator' },
      { label: 'Réglages…', accelerator: 'CmdOrCtrl+,', click: () => send('showSettings') },
      { type: 'separator' }, { role: 'quit', label: 'Quitter' },
    ] },
    { label: 'Édition', submenu: [
      { role: 'undo', label: 'Annuler' }, { role: 'redo', label: 'Rétablir' }, { type: 'separator' },
      { role: 'cut', label: 'Couper' }, { role: 'copy', label: 'Copier' }, { role: 'paste', label: 'Coller' }, { role: 'selectAll', label: 'Tout sélectionner' },
      { type: 'separator' }, { label: 'Rechercher', accelerator: 'CmdOrCtrl+F', click: () => send('focusSearch') },
    ] },
    { label: 'Affichage', submenu: [
      { label: 'Afficher/masquer les informations', accelerator: 'CmdOrCtrl+I', click: () => send('toggleInspector') },
      { type: 'separator' }, { role: 'resetZoom', label: 'Taille réelle' }, { role: 'zoomIn', label: 'Agrandir' }, { role: 'zoomOut', label: 'Réduire' },
      { type: 'separator' }, { role: 'togglefullscreen', label: 'Plein écran' }, { role: 'toggleDevTools', label: 'Outils de développement' },
    ] },
    { label: 'Aide', submenu: [
      { label: SelfUpdate.menuTitle, click: () => SelfUpdate.checkNow() },
      { label: SelfUpdate.automaticTitle, type: 'checkbox', checked: SelfUpdate.automatic(), click: (i) => { SelfUpdate.setAutomatic(i.checked); push('status'); } },
      { type: 'separator' },
      { label: 'Page du projet', click: () => shell.openExternal(`https://github.com/${REPO}`) },
      { label: `À propos de Biblijeu ${app.getVersion()}`, click: () => dialog.showMessageBox(win, { message: `Biblijeu ${app.getVersion()}`, detail: 'Bibliothèque de jeux : ROM, jeux Steam, jeux Windows avec Proton, émulateurs et sauvegardes.' }) },
    ] },
  ]));
}

function createWindow() {
  win = new BrowserWindow({
    width: 1300, height: 840, minWidth: 960, minHeight: 600, title: 'Biblijeu', backgroundColor: '#1c1c1e', autoHideMenuBar: true,
    icon: path.join(__dirname, '..', 'resources', 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true, nodeIntegration: false },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https:\/\//.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  // Revenir dans Biblijeu relit les dossiers de sauvegarde (pas de copie).
  win.on('focus', () => { if (!backupRunning) refreshBackups(); });
}

let quitting = false;
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
  app.whenReady().then(async () => {
    SelfUpdate.start(REPO, settings);
    buildMenu();
    createWindow();
    await rescan();
    rescheduleBackups();
    if (settings.get('autoBackup') && settings.get('backupOnLaunch')) runAutomatically('au lancement');
  });
  // La fermeture attend la copie, jamais plus de 20 s : les sauvegardes restent
  // sur ce PC et le lancement suivant les copiera.
  app.on('before-quit', (e) => {
    Play.save();
    if (quitting || !settings.get('autoBackup') || !settings.get('backupOnQuit') || !destinationAvailable()) return;
    e.preventDefault();
    quitting = true;
    if (win && !win.isDestroyed()) win.webContents.send('quitting');
    const ctl = new AbortController();
    const watchdog = setTimeout(() => { ctl.abort(); app.quit(); }, 20000);
    const wait = backupRunning ? new Promise((r) => { const t = setInterval(() => { if (!backupRunning) { clearInterval(t); r(); } }, 200); }) : Promise.resolve();
    wait.then(() => runAutomatically('à la fermeture', ctl.signal)).finally(() => { clearTimeout(watchdog); app.quit(); });
  });
  app.on('window-all-closed', () => app.quit());
}
