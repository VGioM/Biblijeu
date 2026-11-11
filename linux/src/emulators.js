// emulators.js — trouver les émulateurs installés sur ce PC et construire la
// commande qui démarre un jeu. Version Linux de ApplicationScanner.swift et
// Launcher.swift.
//
// Un émulateur est cherché en Flatpak (`flatpak list`), dans le PATH (paquet de
// la distribution) et parmi les AppImage des dossiers d'applications. Les jeux
// Windows passent par Proton — celui que Steam a installé (Proton Experimental,
// Proton 10, GE-Proton dans compatibilitytools.d) — lancé par umu-run quand il
// est là, sinon par le script `proton` lui-même, avec un préfixe Wine par jeu.
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync, spawn } = require('child_process');
const S = require('./shared');
const Steam = require('./steam');

const home = os.homedir();

function which(cmd) {
  for (const dir of (process.env.PATH || '').split(':')) {
    const p = path.join(dir, cmd);
    try { fs.accessSync(p, fs.constants.X_OK); if (fs.statSync(p).isFile()) return p; } catch { /* suivant */ }
  }
  return null;
}

/** Les applications Flatpak installées : identifiant → { version, installation }. */
function flatpakApps() {
  if (!which('flatpak')) return {};
  try {
    const out = execFileSync('flatpak', ['list', '--app', '--columns=application,version,installation'], { encoding: 'utf8', timeout: 15000 });
    const apps = {};
    for (const line of out.split('\n')) {
      const [id, version, inst] = line.split('\t');
      if (id) apps[id.trim()] = { version: (version || '').trim() || null, installation: (inst || '').trim() || 'system' };
    }
    return apps;
  } catch { return {}; }
}

/** Les AppImage des dossiers d'applications, jusqu'à trois niveaux (« Emulateurs/Playstation 3/rpcs3.AppImage »). */
function appImages(folders) {
  const out = [];
  for (const f of folders) {
    const walk = (dir, depth) => {
      let entries; try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        const p = path.join(dir, e.name);
        if (e.isDirectory() && depth < 3 && !e.name.startsWith('.')) walk(p, depth + 1);
        else if (/\.appimage$/i.test(e.name)) out.push(p);
      }
    };
    walk(f, 0);
  }
  return out;
}

const versionFromName = (n) => { const m = /(\d+(?:\.\d+){1,3})/.exec(n); return m ? m[1] : null; };

/**
 * Les émulateurs présents : [{ id, name, spec, kind: 'flatpak'|'native'|'appimage'|'proton', target, version, installation }].
 * Pour chacun, la première forme trouvée : Flatpak, puis paquet, puis AppImage.
 */
function detect(appFolders) {
  const flat = flatpakApps();
  const images = appImages(appFolders);
  const found = [];
  for (const spec of S.EMULATORS) {
    if (spec.id === 'proton') {
      const builds = Steam.protonBuilds();
      if (builds.length) found.push({ id: 'proton', name: 'Proton', spec, kind: 'proton', target: null, version: `${builds.length} version${builds.length > 1 ? 's' : ''}` });
      continue;
    }
    const fid = spec.flatpak.find((id) => flat[id]);
    if (fid) { found.push({ id: spec.id, name: spec.name, spec, kind: 'flatpak', target: fid, version: flat[fid].version, installation: flat[fid].installation }); continue; }
    const bin = spec.bins.map(which).find(Boolean);
    if (bin) { found.push({ id: spec.id, name: spec.name, spec, kind: 'native', target: bin, version: null }); continue; }
    const img = spec.appimage && images.find((p) => spec.appimage.test(path.basename(p)));
    if (img) found.push({ id: spec.id, name: spec.name, spec, kind: 'appimage', target: img, version: versionFromName(path.basename(img)) });
  }
  return found;
}

// ── RetroArch : le cœur qui fait tourner chaque console ────────────────────

const RA_CORES = {
  nes: ['mesen', 'nestopia', 'fceumm'], snes: ['snes9x', 'bsnes'], n64: ['mupen64plus_next', 'parallel_n64'],
  gb: ['gambatte', 'mgba', 'sameboy'], gbc: ['gambatte', 'mgba', 'sameboy'], gba: ['mgba', 'vba_next'], nds: ['melonds', 'desmume'],
  vb: ['mednafen_vb'], ps1: ['swanstation', 'mednafen_psx_hw', 'pcsx_rearmed'], psp: ['ppsspp'],
  genesis: ['genesis_plus_gx', 'picodrive'], mastersystem: ['genesis_plus_gx', 'smsplus'], gamegear: ['genesis_plus_gx'],
  sega32x: ['picodrive'], saturn: ['mednafen_saturn', 'yabasanshiro'], dreamcast: ['flycast'], pcengine: ['mednafen_pce_fast', 'mednafen_pce'],
  neogeo: ['fbneo'], ngp: ['mednafen_ngp'], wonderswan: ['mednafen_wswan'], lynx: ['handy', 'mednafen_lynx'], atari2600: ['stella'],
  '3do': ['opera'], arcade: ['fbneo', 'mame'], amiga: ['puae'], c64: ['vice_x64sc'], doom: ['prboom'], dos: ['dosbox_pure'],
};

function raCoreDirs(installed) {
  const dirs = [path.join(home, '.config/retroarch/cores'), '/usr/lib/libretro', '/usr/lib64/libretro', '/usr/lib/x86_64-linux-gnu/libretro'];
  if (installed && installed.kind === 'flatpak') dirs.unshift(path.join(home, '.var/app/org.libretro.RetroArch/config/retroarch/cores'));
  return dirs;
}

function retroarchCore(systemID, installed) {
  for (const name of RA_CORES[systemID] || []) {
    for (const d of raCoreDirs(installed)) {
      const f = path.join(d, `${name}_libretro.so`);
      if (fs.existsSync(f)) return f;
    }
  }
  return null;
}

// ── Commande ───────────────────────────────────────────────────────────────

const playableFile = (item, disc) => disc || (item.discs && item.discs[0]) || item.path;

/** Le dossier commun aux fichiers donnés, ouvert au bac à sable Flatpak. */
function commonDir(files) {
  let parts = path.dirname(files[0]).split('/');
  for (const f of files.slice(1)) {
    const q = path.dirname(f).split('/');
    let i = 0;
    while (i < parts.length && i < q.length && parts[i] === q[i]) i++;
    parts = parts.slice(0, i);
  }
  return parts.join('/') || '/';
}

function emulatorArgs(emulator, item, rom, direct, leading) {
  const spec = emulator.spec;
  let template = (direct && spec.direct) || spec.launch;
  if (spec.id === 'retroarch') {
    const core = retroarchCore(item.systemID, emulator);
    template = [...(core ? ['-L', core] : []), ...((direct && spec.direct) || ['{rom}'])];
  }
  // Les options vont devant : plusieurs émulateurs lient un drapeau au chemin (« -e <fichier> »).
  let args = [...leading, ...template.map((a) => a.replace('{rom}', rom))];
  // Un .pk3 est un mod chargé par-dessus un IWAD, pas un IWAD.
  if ((spec.id === 'uzdoom' || spec.id === 'gzdoom') && !/\.i?wad$/i.test(rom)) args = args.map((a) => (a === '-iwad' ? '-file' : a));
  return args;
}

/** argv complet pour un émulateur : [programme, ...arguments]. */
function emulatorCommand(emulator, args, files) {
  switch (emulator.kind) {
    case 'flatpak': return ['flatpak', 'run', `--filesystem=${commonDir(files)}`, emulator.target, ...args];
    default: return [emulator.target, ...args];
  }
}

// ── Proton ─────────────────────────────────────────────────────────────────

const slug = (s) => S.normalize(s).replace(/ /g, '-').slice(0, 60) || 'jeu';

/** Préfixe Wine d'un jeu Windows : un dossier par jeu, nommé d'après lui. */
function prefixFor(item, prefixesRoot) {
  return path.join(prefixesRoot, slug(item.title));
}

/** Le Proton choisi (par jeu, sinon dans les réglages), sinon Proton Experimental, sinon le plus récent. */
function pickProton(wanted) {
  const builds = Steam.protonBuilds();
  return builds.find((b) => b.name === wanted) || builds.find((b) => b.name === 'Proton - Experimental') || builds[0] || null;
}

function protonCommand(exe, proton, prefix) {
  fs.mkdirSync(prefix, { recursive: true });
  const env = { ...process.env };
  const umu = which('umu-run');
  if (umu) {
    // umu lance Proton dans le conteneur Steam Linux Runtime, comme Steam.
    env.WINEPREFIX = path.join(prefix, 'pfx');
    env.PROTONPATH = proton.dir;
    env.GAMEID = '0';
    env.STORE = 'none';
    return { argv: [umu, exe], env, cwd: path.dirname(exe), preview: `WINEPREFIX=${q(env.WINEPREFIX)} PROTONPATH=${q(proton.dir)} umu-run ${q(exe)}` };
  }
  env.STEAM_COMPAT_DATA_PATH = prefix;
  env.STEAM_COMPAT_CLIENT_INSTALL_PATH = Steam.root() || path.join(home, '.local/share/Steam');
  const runtime = Steam.sniperRuntime();
  if (runtime) {
    return { argv: [runtime, '--verb=waitforexitandrun', '--', path.join(proton.dir, 'proton'), 'waitforexitandrun', exe], env, cwd: path.dirname(exe),
      preview: `STEAM_COMPAT_DATA_PATH=${q(prefix)} ${q(runtime)} --verb=waitforexitandrun -- ${q(path.join(proton.dir, 'proton'))} waitforexitandrun ${q(exe)}` };
  }
  return { argv: [path.join(proton.dir, 'proton'), 'run', exe], env, cwd: path.dirname(exe),
    preview: `STEAM_COMPAT_DATA_PATH=${q(prefix)} ${q(path.join(proton.dir, 'proton'))} run ${q(exe)}` };
}

const q = (s) => (/[\s'"$]/.test(s) ? `"${String(s).replace(/(["$`\\])/g, '\\$1')}"` : s);

/** « Exec » d'un .desktop, sans ses codes de champ (%f, %U…). */
function desktopArgv(exec) {
  const argv = [];
  let cur = '', quote = false, had = false;
  for (let i = 0; i < exec.length; i++) {
    const c = exec[i];
    if (c === '"') { quote = !quote; had = true; continue; }
    if (c === '\\' && quote && i + 1 < exec.length) { cur += exec[++i]; continue; }
    if (c === ' ' && !quote) { if (cur || had) argv.push(cur); cur = ''; had = false; continue; }
    cur += c;
  }
  if (cur || had) argv.push(cur);
  return argv.filter((a) => !/^%[fFuUdDnNickvm]$/.test(a)).map((a) => a.replace(/%%/g, '%'));
}

/**
 * La commande qui démarre ce jeu : { argv, env, cwd, preview } ou { url } (Steam)
 * ou { error }. `opts` : { emulator, direct, disc, resume, protonName, prefixesRoot }.
 */
function plan(item, opts) {
  if (item.steamGameID) {
    const url = `steam://rungameid/${item.steamGameID}`;
    return { url, preview: `steam ${url}` };
  }
  if (item.desktopExec) {
    const argv = desktopArgv(item.desktopExec);
    return { argv, env: process.env, cwd: home, preview: argv.map(q).join(' ') };
  }
  if (item.kind === 'game' && item.systemID === 'linux') {
    const exe = item.path;
    if (/\.sh$/i.test(exe)) return { argv: ['/bin/sh', exe], env: process.env, cwd: path.dirname(exe), preview: `sh ${q(exe)}` };
    return { argv: [exe], env: process.env, cwd: path.dirname(exe), preview: q(exe), chmod: true };
  }
  if (item.kind !== 'rom' && item.systemID !== 'windows') {
    return { open: item.path, preview: `xdg-open ${q(item.path)}` };
  }
  const rom = playableFile(item, opts.disc);
  if (!fs.existsSync(rom)) return { error: `Le fichier est introuvable :\n${rom}` };

  // Un jeu Windows : Proton, comme Steam le ferait.
  if (item.systemID === 'windows') {
    const proton = pickProton(opts.protonName);
    if (!proton) return { error: "Aucun Proton trouvé. Installez « Proton Experimental » depuis Steam (Bibliothèque → Outils), ou GE-Proton avec ProtonUp-Qt / ProtonPlus." };
    if (/\.lnk$/i.test(rom)) return { error: 'Un raccourci .lnk ne se lance pas directement : choisissez le .exe du jeu.' };
    return protonCommand(rom, proton, prefixFor(item, opts.prefixesRoot));
  }

  const emulator = opts.emulator;
  if (!emulator) {
    const s = S.SYSTEM_BY_ID[item.systemID];
    const names = s ? s.emulators.map((id) => S.EMULATOR_BY_ID[id] && S.EMULATOR_BY_ID[id].name).filter(Boolean).slice(0, 3) : [];
    return { error: `Aucun émulateur installé pour ${s ? s.name : 'cette console'}.${names.length ? `\nInstallez l'un de ces émulateurs : ${names.join(', ')}.` : ''}` };
  }
  const leading = S.resumeArguments(emulator.spec, opts.resume || { type: 'fromStart' });
  if (!leading) return { error: `${emulator.name} ne sait pas reprendre depuis une sauvegarde d'état en ligne de commande.` };
  const files = [rom, ...(opts.resume && opts.resume.type === 'file' ? [opts.resume.path] : [])];
  const argv = emulatorCommand(emulator, emulatorArgs(emulator, item, rom, opts.direct, leading), files);
  return { argv, env: process.env, cwd: path.dirname(rom), preview: argv.map(q).join(' '), chmod: emulator.kind === 'appimage' };
}

/** Démarre la commande, détachée de Biblijeu : fermer Biblijeu ne ferme pas le jeu. */
function run(p, shell, onError) {
  if (p.url) { shell.openExternal(p.url); return true; }
  if (p.open) { shell.openPath(p.open); return true; }
  if (p.chmod) { try { fs.chmodSync(p.argv[0], fs.statSync(p.argv[0]).mode | 0o755); } catch { /* lecture seule */ } }
  const child = spawn(p.argv[0], p.argv.slice(1), { cwd: p.cwd, env: p.env, detached: true, stdio: 'ignore' });
  child.on('error', (e) => onError && onError(e));
  child.unref();
  return true;
}

/** Les émulateurs ouverts en ce moment : on ne restaure jamais par-dessus. */
function runningEmulatorIDs(installed) {
  let cmdlines = [];
  try {
    cmdlines = fs.readdirSync('/proc').filter((d) => /^\d+$/.test(d)).map((d) => {
      try { return fs.readFileSync(`/proc/${d}/cmdline`, 'utf8').replace(/\0/g, ' '); } catch { return ''; }
    });
  } catch { return new Set(); }
  const ids = new Set();
  for (const e of installed) {
    const needles = [e.target, ...e.spec.flatpak, ...e.spec.bins.map((b) => '/' + b)].filter(Boolean);
    if (cmdlines.some((c) => needles.some((n) => c.includes(n)))) ids.add(e.id);
  }
  return ids;
}

module.exports = { detect, plan, run, which, flatpakApps, retroarchCore, desktopArgv, prefixFor, pickProton, runningEmulatorIDs, slug, commonDir };
