// steam.js — ce que le client Steam pour Linux sait : ses bibliothèques, les
// jeux installés (lancés par Steam, avec le Proton choisi pour eux), les jeux
// ajoutés à la main (« Ajouter un jeu non-Steam »), les jaquettes déjà
// téléchargées, et les Proton qu'il a installés. Traduction de Steam.swift.
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const home = os.homedir();

/** Le dossier de Steam : natif (~/.local/share/Steam), lien ~/.steam/steam, ou Flatpak. */
function root() {
  for (const p of [path.join(home, '.local/share/Steam'), path.join(home, '.steam/steam'),
    path.join(home, '.var/app/com.valvesoftware.Steam/.local/share/Steam')]) {
    try { if (fs.existsSync(path.join(p, 'steamapps'))) return fs.realpathSync(p); } catch { /* suivant */ }
  }
  return null;
}

/** Toutes les valeurs écrites `"clé"  "valeur"` dans un fichier VDF ou ACF. */
function values(key, text) {
  const re = new RegExp(`"${key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"\\s+"((?:[^"\\\\]|\\\\.)*)"`, 'gi');
  const out = [];
  let m;
  while ((m = re.exec(text))) out.push(m[1].replace(/\\\\/g, '\\'));
  return out;
}

/** Chaque dossier steamapps, celui par défaut d'abord. */
function libraries() {
  const r = root();
  if (!r) return [];
  const main = path.join(r, 'steamapps');
  const out = [main];
  try {
    for (const p of values('path', fs.readFileSync(path.join(main, 'libraryfolders.vdf'), 'utf8'))) {
      const s = path.join(p, 'steamapps');
      let real = s; try { real = fs.realpathSync(s); } catch { /* disque absent */ }
      if (!out.some((x) => { try { return fs.realpathSync(x) === real; } catch { return x === s; } })) out.push(s);
    }
  } catch { /* pas de liste */ }
  return out.filter((p) => fs.existsSync(p));
}

const toolNames = ['redistributable', 'steamworks', 'steam linux runtime', 'proton', 'steamvr', 'steamlinuxruntime'];

/** Les jeux entièrement installés, sans les runtimes que Steam installe avec. */
function installedGames() {
  const games = [];
  for (const lib of libraries()) {
    let names; try { names = fs.readdirSync(lib); } catch { continue; }
    for (const n of names) {
      if (!/^appmanifest_\d+\.acf$/.test(n)) continue;
      let text; try { text = fs.readFileSync(path.join(lib, n), 'utf8'); } catch { continue; }
      const appID = parseInt(values('appid', text)[0], 10), name = values('name', text)[0];
      const dir = values('installdir', text)[0], flags = parseInt(values('StateFlags', text)[0], 10);
      if (!appID || !name || !dir || !(flags & 4)) continue;
      if (toolNames.some((t) => name.toLowerCase().includes(t))) continue;
      const folder = path.join(lib, 'common', dir);
      if (!fs.existsSync(folder)) continue;
      games.push({ appID, name, folder });
    }
  }
  return games;
}

// ── Jeux ajoutés à la main ─────────────────────────────────────────────────

/** Les clés-valeurs binaires de Valve, le format de shortcuts.vdf. */
function parseBinaryVDF(buf) {
  let i = 0;
  const str = () => { const end = buf.indexOf(0, i); if (end < 0) throw new Error('fin'); const s = buf.toString('utf8', i, end); i = end + 1; return s; };
  const table = () => {
    const out = {};
    while (i < buf.length) {
      const type = buf[i++];
      if (type === 0x08) return out;
      const key = str();
      if (type === 0x00) out[key] = table();
      else if (type === 0x01) out[key] = str();
      else if (type === 0x02) { out[key] = buf.readUInt32LE(i); i += 4; } else throw new Error('type inconnu');
    }
    return out;
  };
  try { return table(); } catch { return {}; }
}

function userFolders() {
  const r = root();
  if (!r) return [];
  const dir = path.join(r, 'userdata');
  try { return fs.readdirSync(dir).filter((n) => /^\d+$/.test(n)).map((n) => path.join(dir, n)); } catch { return []; }
}

function shortcuts() {
  const out = [], seen = new Set();
  for (const user of userFolders()) {
    let data; try { data = fs.readFileSync(path.join(user, 'config/shortcuts.vdf')); } catch { continue; }
    const rootTable = parseBinaryVDF(data).shortcuts || {};
    for (const entry of Object.values(rootTable)) {
      const f = (k) => { const key = Object.keys(entry).find((x) => x.toLowerCase() === k.toLowerCase()); return key ? entry[key] : undefined; };
      const id = f('appid'), name = f('AppName'), exe = f('Exe');
      if (typeof id !== 'number' || !name || !exe || (f('IsHidden') || 0) !== 0) continue;
      // Ce que Steam ouvre : l'identifiant du raccourci en haut, la marque « raccourci » en bas.
      const gameID = ((BigInt(id) << 32n) | 0x02000000n).toString();
      if (seen.has(gameID)) continue;
      seen.add(gameID);
      out.push({ gameID, name, executable: exe.replace(/^[" ]+|[" ]+$/g, ''), userFolder: user, shortID: id });
    }
  }
  return out;
}

// ── Jaquettes ──────────────────────────────────────────────────────────────

function findFile(dir, names, depth = 0) {
  if (depth > 2) return null;
  let entries; try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return null; }
  for (const e of entries) if (e.isFile() && names.includes(e.name)) return path.join(dir, e.name);
  for (const e of entries) if (e.isDirectory()) { const f = findFile(path.join(dir, e.name), names, depth + 1); if (f) return f; }
  return null;
}

/** La jaquette que Steam a déjà téléchargée pour sa propre bibliothèque. */
function cover(appID) {
  const r = root();
  if (!r) return null;
  const cache = path.join(r, 'appcache/librarycache');
  const flat = path.join(cache, `${appID}_library_600x900.jpg`);
  if (fs.existsSync(flat)) return flat;
  return findFile(path.join(cache, String(appID)), ['library_600x900.jpg', 'library_capsule.jpg']);
}

function shortcutCover(s) {
  const grid = path.join(s.userFolder, 'config/grid');
  for (const ext of ['png', 'jpg']) { const f = path.join(grid, `${s.shortID}p.${ext}`); if (fs.existsSync(f)) return f; }
  return null;
}

// ── Proton ─────────────────────────────────────────────────────────────────

/**
 * Les Proton installés par Steam : ceux des bibliothèques (Proton - Experimental,
 * Proton 10.0…) et ceux de compatibilitytools.d (GE-Proton…). Experimental d'abord,
 * puis les plus récents.
 */
function protonBuilds() {
  const out = [], seen = new Set();
  const add = (dir, name, source) => {
    if (!fs.existsSync(path.join(dir, 'proton')) || seen.has(name)) return;
    seen.add(name);
    out.push({ name, dir, source });
  };
  for (const lib of libraries()) {
    let names; try { names = fs.readdirSync(path.join(lib, 'common')); } catch { continue; }
    for (const n of names) if (/^Proton/.test(n) && !/Runtime/i.test(n)) add(path.join(lib, 'common', n), n, 'Steam');
  }
  const r = root();
  for (const base of [r && path.join(r, 'compatibilitytools.d'), path.join(home, '.steam/root/compatibilitytools.d')].filter(Boolean)) {
    let names; try { names = fs.readdirSync(base); } catch { continue; }
    for (const n of names) add(path.join(base, n), n, 'compatibilitytools.d');
  }
  const rank = (b) => (b.name === 'Proton - Experimental' ? 2 : /hotfix/i.test(b.name) ? 0 : 1);
  const coll = new Intl.Collator('en', { numeric: true });
  return out.sort((a, b) => (rank(b) - rank(a)) || coll.compare(b.name, a.name));
}

/** Le conteneur Steam Linux Runtime (sniper), dans lequel Steam lance Proton. */
function sniperRuntime() {
  for (const lib of libraries()) {
    const p = path.join(lib, 'common/SteamLinuxRuntime_sniper/_v2-entry-point');
    if (fs.existsSync(p)) return p;
  }
  return null;
}

module.exports = { root, libraries, installedGames, shortcuts, cover, shortcutCover, protonBuilds, sniperRuntime, values, parseBinaryVDF };
