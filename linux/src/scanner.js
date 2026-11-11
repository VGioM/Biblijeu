// scanner.js — parcourt les dossiers de ROM et les applications installées.
//
// Deux choses compliquent « lister chaque fichier » : les images de disque
// viennent avec des pistes qui ne doivent pas apparaître comme des jeux, et une
// extension comme `.iso` appartient à six consoles — c'est le dossier qui
// tranche. Traduction de RomScanner.swift et SwitchTitle.swift ; les
// applications sont lues dans les fichiers .desktop (menu des applications,
// Flatpak compris), l'équivalent Linux de /Applications.
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const S = require('./shared');

// ── Identité d'un jeu ──────────────────────────────────────────────────────

/** Nom du fichier et taille, jamais le dossier : une bibliothèque déplacée reste la même. */
function hash(text) {
  let h = 0xcbf29ce484222325n;
  for (const b of Buffer.from(text, 'utf8')) h = BigInt.asUintN(64, (h ^ BigInt(b)) * 0x100000001b3n);
  return h.toString(36);
}
function identifier(file, size) {
  let s = size;
  if (s == null) { try { s = fs.statSync(file).size; } catch { s = 0; } }
  return hash(`${path.basename(file).toLowerCase()}:${s}`);
}

// ── Règles ─────────────────────────────────────────────────────────────────

const skippedFolders = new Set([
  'firmware', 'keys', 'prod.keys', 'bios', 'system', 'systems', 'saves', 'savestates', 'states', 'cheats', 'screenshots', 'manuals',
  'covers', 'artwork', 'media', 'themes', 'cores', 'logs', 'playlists', 'updates', 'update', 'dlc', 'patches', 'mods', 'config', 'cache',
  '__macosx', 'assets', 'shaders', 'overlays', 'thumbnails', 'temp', 'fabs', 'prefabs', 'addons', 'modules', 'presets', 'engines', 'tools',
  'language', 'ports', 'docs', 'licenses', 'theme', 'scripts', 'save', 'log', 'biblijeu sauvegardes', 'lost+found', '.trash-1000',
  'lib', 'lib64', 'libs',
]);

/** Dossiers de travail : « .noindex », « _build » de nxnative, « .partial » en cours d'écriture. */
const isWorkFolder = (n) => n.endsWith('.noindex') || n.endsWith('_build') || n.endsWith('.partial');

const executableNoise = ['unins', 'setup', 'install', 'vcredist', 'dxsetup', 'dxwebsetup', 'directx', 'crashreport', 'crashhandler',
  'updater', 'update', 'redist', 'config', 'settings', 'readme', 'uninstall', 'activation', 'unitycrashhandler', 'launcherhelper'];

const trackExtensions = new Set(['bin', 'img', 'raw', 'wav', 'mp3', 'ape', 'flac', 'sub', 'ccd', 'mds', 'ecm']);
const sheetExtensions = new Set(['cue', 'gdi', 'm3u', 'toc']);
const everydayExtensions = new Set(['md', 'bin', 'img', 'gz', 'elf', 'raw', 'dat', 'txt', 'sub', 'wav', 'mp3', 'flac', 'ape',
  'zip', '7z', 'bat', 'lnk', 'msi', 'sh', 'x86_64', 'pkg']);

const isExcluded = (p, excluded) => excluded.some((e) => p === e || p.startsWith(e + '/'));

/** Un changement signalé dans un dossier que l'analyse n'explore jamais ne relance rien. */
function ignoresChange(p, roots, excluded) {
  if (isExcluded(p, excluded)) return true;
  const root = roots.find((r) => p.startsWith(r + '/'));
  if (!root) return false;
  const inner = p.slice(root.length + 1).split('/').slice(0, -1).map((x) => x.toLowerCase());
  return inner.some((x) => skippedFolders.has(x) || isWorkFolder(x) || x.startsWith('.'));
}

function headBytes(file, n) {
  try {
    const fd = fs.openSync(file, 'r');
    const b = Buffer.alloc(n);
    const got = fs.readSync(fd, b, 0, n, 0);
    fs.closeSync(fd);
    return b.subarray(0, got);
  } catch { return Buffer.alloc(0); }
}
const isELF = (file) => headBytes(file, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46]));
const isExecutable = (st) => (st.mode & 0o111) !== 0;

// ── Switch : seulement le jeu de base, pas ses mises à jour ni ses DLC ──────

function switchTitleID(file) {
  const head = headBytes(file, 16);
  if (head.length === 16 && head.subarray(0, 4).toString() === 'PFS0') {
    const count = head.readUInt32LE(4), tableSize = head.readUInt32LE(8);
    if (count > 0 && count < 4096 && tableSize < (1 << 20)) {
      const all = headBytes(file, 16 + count * 0x18 + tableSize);
      if (all.length === 16 + count * 0x18 + tableSize) {
        const table = all.subarray(16), names = table.subarray(count * 0x18);
        for (let i = 0; i < count; i++) {
          const off = table.readUInt32LE(i * 0x18 + 0x10);
          if (off >= names.length) continue;
          let end = names.indexOf(0, off); if (end < 0) end = names.length;
          const name = names.subarray(off, end).toString('utf8');
          if (name.length === 36 && name.endsWith('.tik')) return BigInt('0x' + name.slice(0, 16));
        }
      }
    }
  }
  const m = /\[([0-9A-Fa-f]{16})\]/.exec(path.basename(file));
  return m ? BigInt('0x' + m[1]) : null;
}
const isSwitchBaseGame = (file) => { const id = switchTitleID(file); return id == null || (id & 0xfffn) === 0n; };

// ── Fichiers référencés par une feuille de pistes ──────────────────────────

function referencedFiles(sheet) {
  let text;
  try { text = fs.readFileSync(sheet, 'utf8'); } catch { try { text = fs.readFileSync(sheet, 'latin1'); } catch { return []; } }
  const dir = path.dirname(sheet), ext = path.extname(sheet).slice(1).toLowerCase();
  const names = [];
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.toUpperCase().startsWith('FILE ')) {
      const q = /"([^"]+)"/.exec(line);
      if (q) names.push(q[1]);
      else { const parts = line.slice(5).trim().split(' '); if (parts.length > 1) names.push(parts.slice(0, -1).join(' ')); }
    } else if (ext === 'm3u') names.push(line);
    else if (ext === 'gdi') { const q = /"([^"]+)"/.exec(line); if (q) names.push(q[1]); else { const p = line.split(/\s+/); if (p.length >= 5) names.push(p[4]); } }
  }
  const seen = new Set();
  return names.map((n) => path.join(dir, n)).filter((f) => !seen.has(f) && seen.add(f) && fs.existsSync(f));
}

/** Ce que le jeu pèse vraiment : une feuille de pistes pèse cent octets, ses pistes 700 Mo. */
function gameSize(file, declared) {
  if (!sheetExtensions.has(path.extname(file).slice(1).toLowerCase())) return declared;
  let total = declared;
  for (const r of referencedFiles(file)) {
    try { total += fs.statSync(r).size; } catch { total += gameSize(r, 0); }
  }
  return total;
}

function treeSize(dir, depth = 0) {
  if (depth > 12) return 0;
  let total = 0;
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return 0; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) total += treeSize(p, depth + 1);
    else if (e.isFile()) { try { total += fs.statSync(p).size; } catch { /* disparu */ } }
  }
  return total;
}

// ── Consoles d'après le dossier ────────────────────────────────────────────

function consolesNamedBy(name) {
  const found = [];
  const parts = [name, ...name.split(/[:&+,/]/).map((p) => p.trim()).filter((p) => p && p !== name)];
  for (const p of parts) {
    const s = S.systemForFolderName(p);
    if (s && !found.includes(s)) found.push(s);
  }
  return found;
}

function folderHints(file, root) {
  let dir = path.dirname(file);
  while (dir.startsWith(root) && dir.length >= root.length) {
    const found = consolesNamedBy(path.basename(dir));
    if (found.length) return found;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return consolesNamedBy(path.basename(root));
}

/** L'extension restreint, le dossier tranche entre les consoles qui la partagent. */
function resolveSystem(file, ext, root) {
  const candidates = S.systemsForExtension(ext);
  const hints = folderHints(file, root);
  if (hints.length) {
    // Le dossier d'une console contient ses jeux, dans ses formats, et rien d'autre.
    return hints.find((h) => candidates.some((c) => c.id === h.id) || h.fileExtensions.has(ext)) || null;
  }
  // Hors de tout dossier de console, seulement un format qui ne peut être que ça.
  if (candidates.length !== 1 || everydayExtensions.has(ext)) return null;
  return candidates[0];
}

// ── Jeux ───────────────────────────────────────────────────────────────────

function makeItem(file, system, root, extra = {}) {
  const parsed = S.parseName(path.basename(file).replace(/\.[^.]+$/, ''));
  let st; try { st = fs.statSync(file); } catch { st = { size: 0, mtimeMs: 0, birthtimeMs: 0 }; }
  let title = parsed.title;
  // « Launcher.exe » : c'est le dossier qui porte le nom du jeu.
  if (system.id === 'windows' || system.id === 'linux') {
    const folderTitle = S.parseName(path.basename(path.dirname(file))).title;
    const generic = ['launcher', 'start', 'play', 'game', 'run', 'start.sh', 'game.x86_64'].includes(title.toLowerCase());
    if (generic || S.normalize(folderTitle).includes(S.normalize(title))) title = folderTitle;
  }
  const size = extra.size != null ? extra.size : gameSize(file, st.size);
  return {
    id: identifier(file, st.size), kind: system.id === 'linux' ? 'game' : 'rom', title, sortTitle: S.normalize(title),
    systemID: system.id, path: file, discs: [], region: parsed.region, languages: parsed.languages, revision: parsed.revision,
    tags: parsed.tags, fileSize: size, dateAdded: st.birthtimeMs || st.mtimeMs, sourceRoot: root, rawName: parsed.raw,
    localArtwork: null, steamGameID: null, desktopExec: null, appVersion: null, ...extra.fields,
  };
}

const plausibleExe = (file, dir) => {
  const name = path.basename(file).replace(/\.[^.]+$/, '').toLowerCase();
  if (executableNoise.some((n) => name.startsWith(n) || name.includes(n))) return false;
  const parent = path.basename(dir).toLowerCase();
  return ['launcher', 'start', 'play'].includes(name) || name.includes('game') || parent.includes(name) || name.includes(parent) || name.length > 3;
};

function scoreLauncher(file, folder) {
  const name = S.normalize(path.basename(file).replace(/\.(exe|x86_64|sh|appimage)$/i, ''));
  if (name === folder) return 100;
  if (['launcher', 'start', 'play', 'game', 'run'].includes(name)) return 90;
  if (folder.includes(name) || name.includes(folder)) return 80;
  return 10;
}

/** Le programme qui lance le jeu installé dans ce dossier (Windows ou Linux), s'il en est un. */
function installedGameLauncher(dir, files) {
  const folder = S.normalize(path.basename(dir));
  const exes = files.filter((f) => /\.exe$/i.test(f.name)).map((f) => f.path);
  if (exes.length) {
    const cand = exes.filter((e) => plausibleExe(e, dir));
    if (!cand.length) return exes.length > 2 ? { file: exes[0], system: 'windows' } : null;
    return { file: cand.sort((a, b) => scoreLauncher(b, folder) - scoreLauncher(a, folder))[0], system: 'windows' };
  }
  // Un jeu Linux : un programme ELF exécutable (ou un .x86_64, un start.sh) à la racine du dossier.
  // Une AppImage, elle, est un jeu à elle seule : elle ne désigne pas son dossier.
  const natives = files.filter((f) => f.st && f.st.isFile() && isExecutable(f.st) && !/\.(so(\.\d+)*|dll|py|pl)$/i.test(f.name)
    && (/\.x86_64$/i.test(f.name) || (/\.sh$/i.test(f.name) && /^(start|run|launch)/i.test(f.name)) || (!f.name.includes('.') && isELF(f.path)))
    && !executableNoise.some((n) => f.name.toLowerCase().includes(n)));
  if (!natives.length) return null;
  return { file: natives.map((f) => f.path).sort((a, b) => scoreLauncher(b, folder) - scoreLauncher(a, folder))[0], system: 'linux' };
}

function gamesIn(dir, files, root) {
  const exts = new Set(files.map((f) => f.ext));
  const hasPlaylist = exts.has('m3u');
  const hasSheet = [...sheetExtensions].some((e) => exts.has(e));
  const out = [];
  for (const f of files) {
    const ext = f.ext;
    if (!ext || !S.allExtensions.has(ext)) continue;
    if (hasPlaylist && ext !== 'm3u' && (sheetExtensions.has(ext) || trackExtensions.has(ext))) continue;
    if (hasSheet && trackExtensions.has(ext)) continue;
    if (['exe', 'msi', 'bat', 'lnk'].includes(ext) && !plausibleExe(f.path, dir)) continue;
    // Un .zip n'est un jeu d'arcade que là où le dossier le dit.
    if ((ext === 'zip' || ext === '7z') && (!folderHints(f.path, root)[0] || folderHints(f.path, root)[0].id !== 'arcade')) continue;
    if (ext === 'sh' && !(f.st && isExecutable(f.st))) continue;
    if (f.name.startsWith('._')) continue;
    const system = resolveSystem(f.path, ext, root);
    if (!system) continue;
    if (system.id === 'switch' && !isSwitchBaseGame(f.path)) continue;
    out.push(makeItem(f.path, system, root));
  }
  return out;
}

function scanRoot(root, excluded, progress) {
  const items = [];
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { continue; }
    const files = [], subdirs = [];
    for (const e of entries) {
      if (e.name.startsWith('.')) continue;
      const p = path.join(dir, e.name);
      let st = null;
      if (e.isSymbolicLink()) { try { st = fs.statSync(p); } catch { continue; } }
      const isDir = st ? st.isDirectory() : e.isDirectory();
      if (isDir) {
        const n = e.name.toLowerCase();
        if (skippedFolders.has(n) || isWorkFolder(n) || isExcluded(p, excluded)) continue;
        if ([...skippedFolders].some((s) => n.startsWith(s + ' ') || n.endsWith(' ' + s))) continue;
        subdirs.push(p);
      } else {
        if (!st) { try { st = fs.statSync(p); } catch { continue; } }
        files.push({ name: e.name, path: p, ext: path.extname(e.name).slice(1).toLowerCase(), st });
      }
    }
    progress && progress(`Analyse de ${path.basename(dir)}…`);
    // Un jeu installé est tout un arbre de données autour d'un lanceur : on
    // indexe le lanceur et on s'arrête, sinon chaque fichier ressemblant à une
    // ROM rejoindrait la bibliothèque (six cents .wad d'un éditeur de Doom).
    if (dir !== root) {
      const l = installedGameLauncher(dir, files);
      if (l) {
        items.push(makeItem(l.file, S.SYSTEM_BY_ID[l.system], root, { size: treeSize(dir) }));
        continue;
      }
    }
    stack.push(...subdirs);
    items.push(...gamesIn(dir, files, root));
  }
  return items;
}

/** « Final Fantasy VII (France) (Disc 1..3) » est un seul jeu à trois disques. */
function groupMultiDisc(items) {
  const groups = new Map(), singles = [];
  for (const it of items) {
    const disc = S.parseName(path.basename(it.path).replace(/\.[^.]+$/, '')).disc;
    if (it.kind !== 'rom' || disc == null) { singles.push(it); continue; }
    const key = [path.dirname(it.path), it.systemID, S.normalizedCore(it.title)].join('|');
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push({ it, disc });
  }
  const out = singles;
  for (const members of groups.values()) {
    members.sort((a, b) => a.disc - b.disc);
    if (members.length === 1) { out.push(members[0].it); continue; }
    const first = { ...members[0].it };
    first.discs = members.map((m) => m.it.path);
    first.fileSize = members.reduce((s, m) => s + m.it.fileSize, 0);
    out.push(first);
  }
  return out;
}

function scanRoms(roots, excluded, progress) {
  const real = excluded.flatMap((p) => { try { const r = fs.realpathSync(p); return r === p ? [p] : [p, r]; } catch { return [p]; } });
  const items = [];
  for (const root of roots) {
    if (!fs.existsSync(root) || isExcluded(root, real)) continue;
    progress && progress(`Analyse de ${path.basename(root)}…`);
    items.push(...scanRoot(root, real, progress));
  }
  return groupMultiDisc(items);
}

// ── Applications (.desktop) ────────────────────────────────────────────────

const home = os.homedir();
const xdgData = () => [process.env.XDG_DATA_HOME || path.join(home, '.local/share'),
  ...(process.env.XDG_DATA_DIRS || '/usr/local/share:/usr/share').split(':'),
  path.join(home, '.local/share/flatpak/exports/share'), '/var/lib/flatpak/exports/share'];

function parseDesktop(file) {
  let text; try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
  const out = {};
  let inMain = false;
  for (const line of text.split('\n')) {
    if (line.startsWith('[')) { inMain = line.trim() === '[Desktop Entry]'; continue; }
    if (!inMain) continue;
    const i = line.indexOf('=');
    if (i < 0) continue;
    const k = line.slice(0, i).trim(), v = line.slice(i + 1).trim();
    if (!(k in out)) out[k] = v;
  }
  return out;
}

/** Les fichiers .desktop de chaque dossier d'applications ; un nom vu une fois masque les suivants (comme le menu). */
function desktopFiles() {
  const seen = new Set(), out = [];
  for (const base of [...new Set(xdgData())]) {
    const dir = path.join(base, 'applications');
    let names; try { names = fs.readdirSync(dir); } catch { continue; }
    for (const n of names) {
      if (!n.endsWith('.desktop') || seen.has(n)) continue;
      seen.add(n);
      out.push(path.join(dir, n));
    }
  }
  return out;
}

const iconCache = new Map();
/** L'icône d'une application, d'après son nom dans le thème (la plus grande trouvée). */
function findIcon(name) {
  if (!name) return null;
  if (name.startsWith('/')) return fs.existsSync(name) ? name : null;
  if (iconCache.has(name)) return iconCache.get(name);
  let best = null, bestSize = -1;
  for (const base of [...new Set(xdgData()), path.join(home, '.icons')]) {
    for (const theme of ['hicolor', 'breeze', 'Adwaita']) {
      const td = path.join(base, base.endsWith('.icons') ? '' : 'icons', theme);
      let sizes; try { sizes = fs.readdirSync(td); } catch { continue; }
      for (const s of sizes) {
        const size = s === 'scalable' ? 10000 : parseInt(s, 10) || 0;
        for (const ext of ['png', 'svg']) {
          const f = path.join(td, s, 'apps', `${name}.${ext}`);
          if (size > bestSize && fs.existsSync(f)) { best = f; bestSize = size; }
        }
      }
    }
    const pix = path.join(base, 'pixmaps');
    for (const ext of ['png', 'svg', 'xpm']) { const f = path.join(pix, `${name}.${ext}`); if (bestSize < 0 && fs.existsSync(f)) { best = f; bestSize = 0; } }
  }
  iconCache.set(name, best);
  return best;
}

// Lanceurs et boutiques qui ne déclarent pas forcément « Game ».
const knownLaunchers = /^(com\.heroicgameslauncher\.hgl|net\.lutris\.Lutris|com\.usebottles\.bottles|io\.itch\.itch|com\.hypixel\.HytaleLauncher|com\.valvesoftware\.Steam|steam)/;
const notGames = /(big picture|steam-runtime|valve-|steamvr|proton|protontricks|winetricks|gamemode|mangohud|controller|piper|solaar|antimicrox|sunshine|moonlight|protonplus|pupgui|dosbox-?x?-?conf)/i;

/** Les jeux (Categories=Game) et lanceurs installés, et les .desktop des émulateurs. */
function scanApplications() {
  const games = [], desktopByEmu = {};
  for (const file of desktopFiles()) {
    const d = parseDesktop(file);
    if (!d || d.Type !== 'Application' || d.NoDisplay === 'true' || d.Hidden === 'true' || !d.Exec) continue;
    const id = path.basename(file, '.desktop');
    const cats = (d.Categories || '').split(';');
    // Les raccourcis que Steam crée pour ses jeux : Steam les connaît déjà.
    if (/steam:\/\/rungameid\//.test(d.Exec)) continue;
    const emu = S.EMULATORS.find((e) => e.flatpak.includes(id) || e.bins.some((b) => new RegExp(`(^|/|\\s)${b.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(\\s|$)`).test(d.Exec.split(' %')[0])));
    if (emu) { desktopByEmu[emu.id] = { file, name: d.Name, icon: findIcon(d.Icon) }; continue; }
    const isGame = cats.includes('Game') && !cats.includes('Emulator');
    if (!(isGame || knownLaunchers.test(id)) || notGames.test(id) || notGames.test(d.Name || '')) continue;
    if (cats.includes('Settings') || cats.includes('System')) continue;
    let st; try { st = fs.statSync(file); } catch { st = { mtimeMs: 0 }; }
    const name = d.Name || id;
    games.push({
      id: hash('desktop:' + id), kind: 'game', title: name, sortTitle: S.normalize(name), systemID: 'linux', path: file, discs: [],
      region: null, languages: [], revision: null, tags: [], fileSize: 0, dateAdded: st.mtimeMs, sourceRoot: null, rawName: name,
      localArtwork: findIcon(d.Icon), steamGameID: null, desktopExec: d.Exec, desktopID: id, appVersion: null,
    });
  }
  return { games, desktopByEmu };
}

module.exports = { scanRoms, scanApplications, identifier, hash, ignoresChange, isWorkFolder, isSwitchBaseGame, findIcon, parseDesktop, isELF, skippedFolders };
