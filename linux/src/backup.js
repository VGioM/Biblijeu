// backup.js — l'onglet « Sauvegarde » : où chaque émulateur range ses
// sauvegardes sur Linux (installation native ou Flatpak, dans ~/.var/app), et
// la copie incrémentale vers le disque choisi. Traduction de SaveCatalog.swift,
// BackupEngine.swift et BackupManager.swift.
//
// Règles, comme sur Mac : rien n'est jamais supprimé ; la partie la plus
// récente gagne ; aucune ROM n'est copiée ; les liens symboliques ne sont ni
// suivis ni copiés ; la copie n'entre jamais dans son propre dossier.
'use strict';

const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const os = require('os');
const S = require('./shared');

const home = os.homedir();

const KINDS = {
  saves: { label: 'Sauvegardes', explanation: 'Le fichier de sauvegarde du jeu : votre partie.' },
  states: { label: "Sauvegardes d'état", explanation: "Un instantané de la machine, repris à l'image près. Volumineux et réécrit sans cesse, mais c'est la partie en cours." },
  memoryCards: { label: 'Cartes mémoire', explanation: 'Les cartes mémoire GameCube, PlayStation et PS2 : toutes vos parties de ces consoles y sont.' },
  systemMemory: { label: 'Mémoire système', explanation: "La mémoire propre de la console — NAND, EEPROM, NVRAM. Les sauvegardes Wii et 3DS y vivent, ainsi que les scores des bornes d'arcade." },
  sdCard: { label: 'Carte SD', explanation: "La carte SD virtuelle d'un émulateur Switch ou 3DS : c'est là que vont les jeux, mods et DLC installés. Des copies de jeux plutôt que des sauvegardes — décoché par défaut." },
};
const DEFAULT_KINDS = ['saves', 'states', 'memoryCards', 'systemMemory'];

// Chemins relatifs au dossier personnel, le plus probable d'abord. Une
// installation Flatpak range ses données dans ~/.var/app/<id>/{config,data}.
// Chaque chemin n'est qu'un candidat : il n'est montré que s'il existe.
const fp = (id, sub) => `.var/app/${id}/${sub}`;
const spec = (kind, candidates, o = {}) => ({ kind, candidates, ...o });
const ini = (file, section, key, relativeTo) => ({ file, section, key, relativeTo });

const CATALOG = {
  dolphin: [
    spec('memoryCards', ['.local/share/dolphin-emu/GC', fp('org.DolphinEmu.dolphin-emu', 'data/dolphin-emu/GC')]),
    spec('systemMemory', ['.local/share/dolphin-emu/Wii', fp('org.DolphinEmu.dolphin-emu', 'data/dolphin-emu/Wii')]),
    spec('states', ['.local/share/dolphin-emu/StateSaves', fp('org.DolphinEmu.dolphin-emu', 'data/dolphin-emu/StateSaves')]),
    spec('saves', ['.local/share/dolphin-emu/GBA', fp('org.DolphinEmu.dolphin-emu', 'data/dolphin-emu/GBA')], { slug: 'gba', label: 'Sauvegardes Game Boy Advance' }),
  ],
  cemu: [spec('saves', ['.local/share/Cemu/mlc01/usr/save', fp('info.cemu.Cemu', 'data/Cemu/mlc01/usr/save')])],
  ryujinx: [
    spec('saves', ['.config/Ryujinx/bis/user/save', fp('io.github.ryubing.Ryujinx', 'config/Ryujinx/bis/user/save'), fp('org.ryujinx.Ryujinx', 'config/Ryujinx/bis/user/save')]),
    // Ce qui dit à quel jeu appartient chaque dossier numéroté : inutile seul, indispensable avec.
    spec('saves', ['.config/Ryujinx/bis/user/saveMeta', fp('io.github.ryubing.Ryujinx', 'config/Ryujinx/bis/user/saveMeta'), fp('org.ryujinx.Ryujinx', 'config/Ryujinx/bis/user/saveMeta')], { slug: 'saveMeta', label: 'Index des sauvegardes' }),
    spec('sdCard', ['.config/Ryujinx/sdcard', fp('io.github.ryubing.Ryujinx', 'config/Ryujinx/sdcard')]),
  ],
  eden: [spec('saves', ['.local/share/eden/nand/user/save']), spec('sdCard', ['.local/share/eden/sdmc'])],
  citron: [spec('saves', ['.local/share/citron/nand/user/save']), spec('sdCard', ['.local/share/citron/sdmc'])],
  sudachi: [spec('saves', ['.local/share/sudachi/nand/user/save']), spec('sdCard', ['.local/share/sudachi/sdmc'])],
  yuzu: [spec('saves', ['.local/share/yuzu/nand/user/save', fp('org.yuzu_emu.yuzu', 'data/yuzu/nand/user/save')]), spec('sdCard', ['.local/share/yuzu/sdmc'])],
  duckstation: [
    spec('memoryCards', ['.local/share/duckstation/memcards', fp('org.duckstation.DuckStation', 'config/duckstation/memcards')],
      { settings: [ini('.local/share/duckstation/settings.ini', 'Folders', 'MemoryCards', '.local/share/duckstation'),
        ini(fp('org.duckstation.DuckStation', 'config/duckstation/settings.ini'), 'Folders', 'MemoryCards', fp('org.duckstation.DuckStation', 'config/duckstation'))] }),
    spec('states', ['.local/share/duckstation/savestates', fp('org.duckstation.DuckStation', 'config/duckstation/savestates')],
      { settings: [ini('.local/share/duckstation/settings.ini', 'Folders', 'SaveStates', '.local/share/duckstation'),
        ini(fp('org.duckstation.DuckStation', 'config/duckstation/settings.ini'), 'Folders', 'SaveStates', fp('org.duckstation.DuckStation', 'config/duckstation'))] }),
  ],
  pcsx2: [
    spec('memoryCards', ['.config/PCSX2/memcards', fp('net.pcsx2.PCSX2', 'config/PCSX2/memcards')],
      { settings: [ini('.config/PCSX2/inis/PCSX2.ini', 'Folders', 'MemoryCards', '.config/PCSX2'), ini(fp('net.pcsx2.PCSX2', 'config/PCSX2/inis/PCSX2.ini'), 'Folders', 'MemoryCards', fp('net.pcsx2.PCSX2', 'config/PCSX2'))] }),
    spec('states', ['.config/PCSX2/sstates', fp('net.pcsx2.PCSX2', 'config/PCSX2/sstates')],
      { settings: [ini('.config/PCSX2/inis/PCSX2.ini', 'Folders', 'Savestates', '.config/PCSX2'), ini(fp('net.pcsx2.PCSX2', 'config/PCSX2/inis/PCSX2.ini'), 'Folders', 'Savestates', fp('net.pcsx2.PCSX2', 'config/PCSX2'))] }),
  ],
  rpcs3: [spec('saves', ['.config/rpcs3/dev_hdd0/home', fp('net.rpcs3.RPCS3', 'config/rpcs3/dev_hdd0/home')])],
  shadps4: [spec('saves', ['.local/share/shadPS4/savedata', fp('net.shadps4.shadPS4', 'data/shadPS4/savedata')])],
  ppsspp: [
    spec('saves', ['.config/ppsspp/PSP/SAVEDATA', fp('org.ppsspp.PPSSPP', 'config/ppsspp/PSP/SAVEDATA')]),
    spec('states', ['.config/ppsspp/PSP/PPSSPP_STATE', fp('org.ppsspp.PPSSPP', 'config/ppsspp/PSP/PPSSPP_STATE')]),
  ],
  vita3k: [spec('saves', ['.local/share/Vita3K/Vita3K/ux0/user', fp('org.vita3k.Vita3K', 'data/Vita3K/Vita3K/ux0/user')])],
  azahar: [
    spec('sdCard', ['.local/share/azahar-emu/sdmc', fp('org.azahar_emu.Azahar', 'data/azahar-emu/sdmc')], { slug: 'sdmc', label: 'Carte SD virtuelle' }),
    spec('systemMemory', ['.local/share/azahar-emu/nand', fp('org.azahar_emu.Azahar', 'data/azahar-emu/nand')]),
    spec('states', ['.local/share/azahar-emu/states', fp('org.azahar_emu.Azahar', 'data/azahar-emu/states')]),
  ],
  lime3ds: [
    spec('sdCard', ['.local/share/lime3ds-emu/sdmc', fp('io.github.lime3ds.Lime3DS', 'data/lime3ds-emu/sdmc')], { slug: 'sdmc', label: 'Carte SD virtuelle' }),
    spec('systemMemory', ['.local/share/lime3ds-emu/nand', fp('io.github.lime3ds.Lime3DS', 'data/lime3ds-emu/nand')]),
    spec('states', ['.local/share/lime3ds-emu/states', fp('io.github.lime3ds.Lime3DS', 'data/lime3ds-emu/states')]),
  ],
  citra: [
    spec('sdCard', ['.local/share/citra-emu/sdmc', fp('org.citra_emu.citra', 'data/citra-emu/sdmc')], { slug: 'sdmc', label: 'Carte SD virtuelle' }),
    spec('systemMemory', ['.local/share/citra-emu/nand', fp('org.citra_emu.citra', 'data/citra-emu/nand')]),
    spec('states', ['.local/share/citra-emu/states', fp('org.citra_emu.citra', 'data/citra-emu/states')]),
  ],
  mesen: [
    spec('saves', ['.config/Mesen2/Saves', 'Documents/Mesen2/Saves']),
    spec('states', ['.config/Mesen2/SaveStates', 'Documents/Mesen2/SaveStates']),
  ],
  simple64: [spec('saves', ['.local/share/simple64/save', '.local/share/mupen64plus/save', fp('io.github.simple64.simple64', 'data/simple64/save')])],
  flycast: [spec('saves', ['.local/share/flycast', fp('org.flycast.Flycast', 'data/flycast')], { onlyExtensions: ['bin', 'sav', 'state', 'vmu'] })],
  redream: [spec('saves', ['.redream/saves'])],
  // L'EEPROM et le disque dur sont dans le même dossier, et le disque est une image de 8 Go.
  xemu: [spec('systemMemory', ['.local/share/xemu/xemu', fp('app.xemu.xemu', 'data/xemu/xemu')], { label: 'Mémoire système (EEPROM)', excluding: ['xbox_hdd.qcow2', 'xbox_hdd.img'] })],
  xenia: [spec('saves', ['.local/share/Xenia/content', 'Documents/Xenia/content'])],
  mame: [
    spec('systemMemory', ['.mame/nvram', fp('org.mamedev.MAME', '.mame/nvram')], { slug: 'nvram', label: 'Mémoire des bornes (NVRAM)' }),
    spec('states', ['.mame/sta', fp('org.mamedev.MAME', '.mame/sta')]),
  ],
  retroarch: [
    spec('saves', ['.config/retroarch/saves', fp('org.libretro.RetroArch', 'config/retroarch/saves')]),
    spec('states', ['.config/retroarch/states', fp('org.libretro.RetroArch', 'config/retroarch/states')]),
  ],
  uzdoom: [spec('saves', ['.local/share/games/uzdoom', '.config/uzdoom/savegames'], { onlyExtensions: ['zds'] })],
  gzdoom: [spec('saves', ['.local/share/games/gzdoom', '.config/gzdoom/savegames', fp('org.zdoom.GZDoom', '.config/gzdoom/savegames'), fp('org.zdoom.GZDoom', 'data/games/gzdoom')], { onlyExtensions: ['zds'] })],
  // Un jeu Windows sauvegarde là où Windows sauvegarde : dans le préfixe Proton
  // du jeu (un par jeu, nommé d'après lui). Dans un préfixe Proton, « Documents »
  // est un vrai dossier, pas un lien vers celui de l'utilisateur.
  proton: [
    spec('saves', ['{prefixes}/*/pfx/drive_c/users/steamuser/Saved Games'], { slug: 'saved-games', label: 'Jeux sauvegardés (Saved Games)' }),
    spec('saves', ['{prefixes}/*/pfx/drive_c/users/steamuser/AppData/Roaming'], { slug: 'appdata', label: "Données d'application (AppData)" }),
    spec('saves', ['{prefixes}/*/pfx/drive_c/users/steamuser/AppData/LocalLow'], { slug: 'locallow', label: 'Données locales (LocalLow)' }),
    spec('saves', ['{prefixes}/*/pfx/drive_c/users/steamuser/Documents'], { slug: 'documents', label: 'Documents' }),
  ],
};

// ── Sauvegardes posées à côté du jeu ───────────────────────────────────────

const ROMS_ID = 'roms';
const adjacentSaves = new Set(['srm', 'sav', 'dsv', 'rtc', 'eep', 'fla', 'mpk', 'sra', 'gme', 'mcr', 'mcd']);
const adjacentStates = new Set(['mln', 'sgm', 'state', ...Array.from({ length: 10 }, (_, i) => `ss${i}`), ...Array.from({ length: 10 }, (_, i) => `st${i}`), ...Array.from({ length: 9 }, (_, i) => `state${i + 1}`)]);

function fingerprint(p) { let h = 5381; for (const c of Buffer.from(p)) h = (h * 33 + c) & 0xfffffff; return (h & 0xffff).toString(16).padStart(4, '0'); }

function romFolders(roots) {
  const counts = {};
  for (const r of roots) { const n = path.basename(r); counts[n] = (counts[n] || 0) + 1; }
  const out = [];
  for (const r of roots) {
    if (!isDir(r)) continue;
    const n = (path.basename(r) || 'dossier').replace(/\//g, '-');
    const name = counts[path.basename(r)] === 1 ? n : `${n}-${fingerprint(r)}`;
    out.push(folder(ROMS_ID, 'saves', `${name}/saves`, `Sauvegardes — ${path.basename(r)}`, r, '', { onlyExtensions: adjacentSaves, skipsWorkFolders: true }));
    out.push(folder(ROMS_ID, 'states', `${name}/states`, `Sauvegardes d'état — ${path.basename(r)}`, r, '', { onlyExtensions: adjacentStates, skipsWorkFolders: true }));
  }
  return out;
}

// ── Dossiers trouvés ───────────────────────────────────────────────────────

function isDir(p) { try { return fs.statSync(p).isDirectory(); } catch { return false; } }

function folder(emulatorID, kind, slug, label, url, variant, filter) {
  const backupSubpath = variant ? `${emulatorID}/${slug}/${variant}` : `${emulatorID}/${slug}`;
  return { id: `${emulatorID}/${slug}/${variant}`, emulatorID, kind, slug, label, url, variant, backupSubpath,
    title: variant ? `${label || KINDS[kind].label} — ${variant}` : (label || KINDS[kind].label),
    filter: { excluding: filter.excluding || [], onlyExtensions: filter.onlyExtensions ? [...filter.onlyExtensions] : [], skipsWorkFolders: !!filter.skipsWorkFolders } };
}

/** Une valeur dans un .ini : ce que l'émulateur dit lui-même de son dossier gagne. */
function readIni(file, section, key) {
  let text; try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
  let cur = '';
  for (const line of text.split(/\r?\n/)) {
    const t = line.trim();
    const sec = /^\[(.+)\]$/.exec(t);
    if (sec) { cur = sec[1].trim(); continue; }
    if (cur.toLowerCase() !== section.toLowerCase()) continue;
    const i = t.indexOf('=');
    if (i > 0 && t.slice(0, i).trim().toLowerCase() === key.toLowerCase()) return t.slice(i + 1).trim().replace(/^"|"$/g, '') || null;
  }
  return null;
}

/** Développe un chemin du catalogue ; `*` nomme le dossier dans la sauvegarde. */
function expand(candidate, prefixesRoot) {
  const full = candidate.startsWith('{prefixes}') ? candidate.replace('{prefixes}', prefixesRoot) : path.join(home, candidate);
  const parts = full.split('/');
  let found = [{ p: '/', variant: '' }];
  for (const part of parts.slice(1)) {
    if (part === '*') {
      const next = [];
      for (const f of found) {
        let names; try { names = fs.readdirSync(f.p, { withFileTypes: true }); } catch { continue; }
        for (const e of names) if (e.isDirectory() && !e.name.startsWith('.')) next.push({ p: path.join(f.p, e.name), variant: e.name });
      }
      found = next;
    } else found = found.map((f) => ({ p: path.join(f.p, part), variant: f.variant }));
  }
  return found.filter((f) => isDir(f.p));
}

function catalogFolders(installedIDs, prefixesRoot) {
  const out = [];
  for (const [emulatorID, specs] of Object.entries(CATALOG)) {
    for (const sp of specs) {
      const slug = sp.slug || sp.kind;
      const filter = { excluding: sp.excluding, onlyExtensions: sp.onlyExtensions };
      // Ce que l'émulateur écrit dans sa configuration passe avant tout.
      let configured = null;
      for (const s of sp.settings || []) {
        const v = readIni(path.join(home, s.file), s.section, s.key);
        if (v) { const p = path.isAbsolute(v) ? v : path.join(home, s.relativeTo, v); if (isDir(p)) { configured = p; break; } }
      }
      if (configured) { out.push(folder(emulatorID, sp.kind, slug, sp.label, configured, '', filter)); continue; }
      const seen = new Set();
      for (const c of sp.candidates) {
        for (const f of expand(c, prefixesRoot)) {
          if (seen.has(f.variant)) continue;   // natif et Flatpak : le premier trouvé
          seen.add(f.variant);
          out.push(folder(emulatorID, sp.kind, slug, sp.label, f.p, f.variant, filter));
        }
      }
    }
  }
  return out;
}

// ── Moteur de copie ────────────────────────────────────────────────────────

const ignoredNames = new Set(['.DS_Store', '.directory', 'Thumbs.db']);

function wants(filter, name) {
  if (filter.excluding.includes(name)) return false;
  if (!filter.onlyExtensions.length) return true;
  return filter.onlyExtensions.includes(path.extname(name).slice(1).toLowerCase());
}
function skipsFolder(filter, name) {
  if (filter.excluding.includes(name)) return true;
  if (!filter.skipsWorkFolders) return false;
  const n = name.toLowerCase();
  return n.endsWith('.noindex') || n.endsWith('_build') || n.endsWith('.partial') || n === 'biblijeu sauvegardes';
}

async function measure(dir, filter) {
  let files = 0, bytes = 0;
  async function walk(d) {
    let entries; try { entries = await fsp.readdir(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (ignoredNames.has(e.name) || e.isSymbolicLink()) continue;
      const p = path.join(d, e.name);
      if (e.isDirectory()) { if (!skipsFolder(filter, e.name)) await walk(p); continue; }
      if (!e.isFile() || !wants(filter, e.name)) continue;
      try { bytes += (await fsp.stat(p)).size; files++; } catch { /* disparu */ }
    }
  }
  await walk(dir);
  return { files, bytes };
}

/**
 * Copie `source` dans `destination`. rules : { newestWins, onlyExisting }.
 * Un fichier de même taille et même date (à la seconde près) n'est pas recopié ;
 * rien n'est supprimé à l'arrivée.
 */
async function copyTree(source, destination, filter, rules, signal) {
  const out = { copied: 0, identical: 0, keptNewer: 0, bytes: 0, failures: [], cancelled: false };
  if (!isDir(source)) { out.failures.push(`Dossier introuvable : ${source}`); return out; }
  if (rules.onlyExisting && !fs.existsSync(destination)) return out;
  try { await fsp.mkdir(destination, { recursive: true }); } catch (e) { out.failures.push(`Impossible de créer ${destination} : ${e.message}`); return out; }
  const own = path.resolve(destination);
  async function walk(src, dst) {
    let entries; try { entries = await fsp.readdir(src, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      if (signal && signal.aborted) { out.cancelled = true; return; }
      if (ignoredNames.has(e.name) || e.isSymbolicLink()) continue;
      const s = path.join(src, e.name), d = path.join(dst, e.name);
      if (e.isDirectory()) {
        // Une ROM et ses copies sur le même disque : ne jamais copier ses propres copies.
        if (path.resolve(s) === own || skipsFolder(filter, e.name)) continue;
        // Recréé d'avance seulement quand tout est copié : une copie filtrée ne
        // doit pas reconstruire l'arborescence entière d'une ludothèque.
        if (!filter.onlyExtensions.length && !rules.onlyExisting) { try { await fsp.mkdir(d, { recursive: true }); } catch { /* plus loin */ } }
        await walk(s, d);
        if (out.cancelled) return;
        continue;
      }
      if (!e.isFile() || !wants(filter, e.name)) continue;
      let st; try { st = await fsp.stat(s); } catch { continue; }
      let theirs = null; try { theirs = await fsp.stat(d); } catch { /* absent */ }
      if (theirs && theirs.size === st.size && Math.abs(theirs.mtimeMs - st.mtimeMs) < 1000) { out.identical++; continue; }
      if (rules.onlyExisting && !theirs) continue;
      if (rules.newestWins && theirs && theirs.mtimeMs - st.mtimeMs >= 1000) { out.keptNewer++; continue; }
      try {
        await fsp.mkdir(path.dirname(d), { recursive: true });
        // Écrit à côté puis renommé : une sauvegarde à moitié écrite est pire qu'une ancienne.
        const tmp = `${d}.biblijeu-tmp`;
        await fsp.copyFile(s, tmp);
        await fsp.utimes(tmp, st.atime, st.mtime);
        await fsp.rename(tmp, d);
        out.copied++; out.bytes += st.size;
      } catch (err) {
        if (out.failures.length < 8) out.failures.push(`${path.relative(source, s)} : ${err.message}`);
      }
    }
  }
  await walk(source, destination);
  return out;
}

const FOLDER_NAME = 'Biblijeu Sauvegardes';
const MANIFEST = 'Biblijeu.json';

module.exports = { KINDS, DEFAULT_KINDS, CATALOG, ROMS_ID, romFolders, catalogFolders, measure, copyTree, readIni, FOLDER_NAME, MANIFEST, isDir };
