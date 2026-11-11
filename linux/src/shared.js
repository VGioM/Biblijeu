// shared.js — ce que Biblijeu sait sans toucher au disque : les consoles, les
// émulateurs (version Linux : Flatpak, paquets, AppImage), le nettoyage des noms
// de dumps, les sections de la barre latérale, la recherche et le tri. Chargé
// par main.js et par l'interface. Traduction de GameSystem.swift,
// Emulator.swift, NameParser.swift et des parties pures de LibraryModel.swift.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.Shared = factory();
}(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ── Consoles ─────────────────────────────────────────────────────────────

  const sys = (id, name, shortName, manufacturer, symbol, year, libretroFolder, exts, aliases, emulators) =>
    ({ id, name, shortName, manufacturer, symbol, year, libretroFolder, fileExtensions: new Set(exts), folderAliases: aliases, emulators });

  const SYSTEMS = [
    sys('nes', 'Nintendo Entertainment System', 'NES', 'Nintendo', 'gamepad', 1983, 'Nintendo - Nintendo Entertainment System', ['nes', 'fds', 'unf', 'unif'], ['nes', 'famicom', 'nintendo entertainment system'], ['ares', 'mesen', 'retroarch']),
    sys('snes', 'Super Nintendo', 'SNES', 'Nintendo', 'gamepad', 1990, 'Nintendo - Super Nintendo Entertainment System', ['sfc', 'smc', 'swc', 'fig', 'bs'], ['snes', 'super nintendo', 'super famicom', 'sfc'], ['snes9x', 'ares', 'mesen', 'retroarch']),
    sys('n64', 'Nintendo 64', 'N64', 'Nintendo', 'gamepad', 1996, 'Nintendo - Nintendo 64', ['n64', 'z64', 'v64', 'ndd'], ['n64', 'nintendo 64'], ['ares', 'simple64', 'retroarch']),
    sys('gb', 'Game Boy', 'GB', 'Nintendo', 'gamepad', 1989, 'Nintendo - Game Boy', ['gb'], ['gb', 'game boy', 'gameboy'], ['mgba', 'vbam', 'ares', 'retroarch']),
    sys('gbc', 'Game Boy Color', 'GBC', 'Nintendo', 'gamepad', 1998, 'Nintendo - Game Boy Color', ['gbc'], ['gbc', 'game boy color', 'gameboy color'], ['mgba', 'vbam', 'ares', 'retroarch']),
    sys('gba', 'Game Boy Advance', 'GBA', 'Nintendo', 'gamepad', 2001, 'Nintendo - Game Boy Advance', ['gba', 'agb'], ['gba', 'game boy advance', 'gameboy advance'], ['mgba', 'vbam', 'ares', 'retroarch']),
    sys('nds', 'Nintendo DS', 'DS', 'Nintendo', 'stack', 2004, 'Nintendo - Nintendo DS', ['nds', 'dsi', 'ids', 'srl'], ['nds', 'ds', 'nintendo ds'], ['melonds', 'retroarch']),
    sys('n3ds', 'Nintendo 3DS', '3DS', 'Nintendo', 'stack', 2011, 'Nintendo - Nintendo 3DS', ['3ds', 'cci', 'cxi', 'cia', '3dsx'], ['3ds', 'n3ds', 'nintendo 3ds'], ['azahar', 'lime3ds', 'citra']),
    sys('gc', 'Nintendo GameCube', 'GameCube', 'Nintendo', 'disc', 2001, 'Nintendo - GameCube', ['gcm', 'gcz', 'rvz', 'ciso', 'iso', 'wia'], ['gamecube', 'game cube', 'gc', 'ngc'], ['dolphin']),
    // Pas de « .wad » : un dump de chaîne Wii est rare, un wad Doom ne l'est pas.
    sys('wii', 'Wii', 'Wii', 'Nintendo', 'disc', 2006, 'Nintendo - Wii', ['wbfs', 'rvz', 'wia', 'iso'], ['wii'], ['dolphin']),
    sys('wiiu', 'Nintendo Wii U', 'Wii U', 'Nintendo', 'disc', 2012, 'Nintendo - Wii U', ['wud', 'wux', 'wua', 'rpx'], ['wii u', 'wiiu', 'wii : wii u', 'wii-wii u'], ['cemu']),
    sys('switch', 'Nintendo Switch', 'Switch', 'Nintendo', 'gamepad', 2017, null, ['xci', 'nsp', 'nsz', 'xcz'], ['switch', 'nintendo switch', 'nsw'], ['ryujinx', 'eden', 'citron', 'sudachi', 'yuzu']),
    sys('vb', 'Virtual Boy', 'Virtual Boy', 'Nintendo', 'eye', 1995, 'Nintendo - Virtual Boy', ['vb', 'vboy'], ['virtual boy', 'vb'], ['ares', 'retroarch']),
    sys('ps1', 'PlayStation', 'PS1', 'Sony', 'disc', 1994, 'Sony - PlayStation', ['cue', 'chd', 'pbp', 'm3u', 'ccd', 'toc', 'img', 'ecm'], ['ps1', 'psx', 'playstation', 'playstation 1', 'psone'], ['duckstation', 'ares', 'retroarch']),
    sys('ps2', 'PlayStation 2', 'PS2', 'Sony', 'disc', 2000, 'Sony - PlayStation 2', ['iso', 'chd', 'cso', 'gz', 'bin', 'mdf', 'nrg'], ['ps2', 'playstation 2'], ['pcsx2']),
    sys('ps3', 'PlayStation 3', 'PS3', 'Sony', 'disc', 2006, 'Sony - PlayStation 3', ['pkg', 'self', 'elf'], ['ps3', 'playstation 3'], ['rpcs3']),
    sys('ps4', 'PlayStation 4', 'PS4', 'Sony', 'disc', 2013, null, ['pkg', 'bin'], ['ps4', 'playstation 4'], ['shadps4']),
    sys('psp', 'PlayStation Portable', 'PSP', 'Sony', 'stack', 2004, 'Sony - PlayStation Portable', ['cso', 'pbp', 'iso', 'chd', 'prx'], ['psp', 'playstation portable'], ['ppsspp', 'retroarch']),
    sys('vita', 'PlayStation Vita', 'Vita', 'Sony', 'stack', 2011, 'Sony - PlayStation Vita', ['vpk'], ['vita', 'ps vita', 'psvita'], ['vita3k']),
    sys('genesis', 'Mega Drive', 'Mega Drive', 'Sega', 'gamepad', 1988, 'Sega - Mega Drive - Genesis', ['md', 'gen', 'smd', 'bin'], ['megadrive', 'mega drive', 'genesis', 'md'], ['ares', 'retroarch']),
    sys('mastersystem', 'Master System', 'Master System', 'Sega', 'gamepad', 1985, 'Sega - Master System - Mark III', ['sms'], ['master system', 'sms', 'mark iii'], ['ares', 'retroarch']),
    sys('gamegear', 'Game Gear', 'Game Gear', 'Sega', 'gamepad', 1990, 'Sega - Game Gear', ['gg'], ['game gear', 'gamegear', 'gg'], ['ares', 'retroarch']),
    sys('sega32x', 'Sega 32X', '32X', 'Sega', 'gamepad', 1994, 'Sega - 32X', ['32x'], ['32x', 'sega 32x'], ['ares', 'retroarch']),
    sys('saturn', 'Saturn', 'Saturn', 'Sega', 'disc', 1994, 'Sega - Saturn', ['cue', 'chd', 'ccd', 'mds'], ['saturn', 'sega saturn'], ['ares', 'retroarch']),
    sys('dreamcast', 'Dreamcast', 'Dreamcast', 'Sega', 'disc', 1998, 'Sega - Dreamcast', ['gdi', 'cdi', 'chd'], ['dreamcast', 'dc'], ['flycast', 'redream', 'retroarch']),
    sys('pcengine', 'PC Engine', 'PC Engine', 'NEC', 'gamepad', 1987, 'NEC - PC Engine - TurboGrafx 16', ['pce', 'sgx'], ['pc engine', 'pcengine', 'turbografx'], ['ares', 'mesen', 'retroarch']),
    sys('neogeo', 'Neo Geo', 'Neo Geo', 'SNK', 'gamepad', 1990, 'SNK - Neo Geo', ['neo'], ['neogeo', 'neo geo'], ['mame', 'retroarch']),
    sys('ngp', 'Neo Geo Pocket', 'NGP', 'SNK', 'gamepad', 1998, 'SNK - Neo Geo Pocket Color', ['ngp', 'ngpc'], ['neo geo pocket', 'ngp'], ['ares', 'retroarch']),
    sys('wonderswan', 'WonderSwan', 'WonderSwan', 'Bandai', 'gamepad', 1999, 'Bandai - WonderSwan Color', ['ws', 'wsc'], ['wonderswan'], ['ares', 'retroarch']),
    sys('lynx', 'Atari Lynx', 'Lynx', 'Atari', 'gamepad', 1989, 'Atari - Lynx', ['lnx'], ['lynx'], ['ares', 'retroarch']),
    sys('atari2600', 'Atari 2600', '2600', 'Atari', 'gamepad', 1977, 'Atari - 2600', ['a26'], ['atari 2600', '2600', 'vcs'], ['ares', 'retroarch']),
    sys('xbox', 'Xbox', 'Xbox', 'Microsoft', 'disc', 2001, 'Microsoft - Xbox', ['xiso'], ['xbox'], ['xemu']),
    sys('xbox360', 'Xbox 360', 'X360', 'Microsoft', 'disc', 2005, null, ['xex', 'iso'], ['xbox 360', 'xbox360', 'x360'], ['xenia']),
    sys('3do', '3DO', '3DO', 'Panasonic', 'disc', 1993, 'The 3DO Company - 3DO', ['iso', 'cue', 'chd'], ['3do'], ['retroarch']),
    sys('arcade', 'Arcade', 'Arcade', 'Arcade', 'star', 1980, 'MAME', ['zip', '7z'], ['arcade', 'mame', 'fbneo', 'fba'], ['mame', 'retroarch']),
    sys('amiga', 'Amiga', 'Amiga', 'Commodore', 'pc', 1985, 'Commodore - Amiga', ['adf', 'adz', 'ipf', 'lha', 'hdf'], ['amiga'], ['retroarch']),
    sys('c64', 'Commodore 64', 'C64', 'Commodore', 'pc', 1982, 'Commodore - 64', ['d64', 't64', 'tap', 'prg', 'crt'], ['c64', 'commodore 64'], ['retroarch']),
    sys('doom', 'Doom', 'Doom', 'PC', 'flame', 1993, 'DOOM', ['wad', 'iwad', 'pk3', 'ipk3', 'pk7'], ['doom', 'wads'], ['uzdoom', 'gzdoom', 'retroarch']),
    sys('dos', 'MS-DOS', 'DOS', 'PC', 'terminal', 1981, 'DOS', ['dosz', 'conf'], ['dos', 'msdos', 'ms-dos'], ['dosbox', 'dosboxstaging', 'retroarch']),
    // Les jeux Windows passent par Proton, celui que Steam a installé.
    sys('windows', 'Jeu Windows', 'Windows', 'PC', 'windows', 1995, null, ['exe', 'msi', 'bat', 'lnk'], ['pc', 'windows', 'win'], ['proton']),
    sys('linux', 'Jeu Linux', 'Linux', 'PC', 'linux', 2000, null, ['appimage', 'x86_64', 'sh'], ['linux'], []),
  ];
  const SYSTEM_BY_ID = Object.fromEntries(SYSTEMS.map((s) => [s.id, s]));
  const allExtensions = new Set(SYSTEMS.flatMap((s) => [...s.fileExtensions]));

  /** Toutes les consoles qui revendiquent une extension, la plus spécifique d'abord. */
  function systemsForExtension(ext) {
    const e = ext.toLowerCase();
    return SYSTEMS.filter((s) => s.fileExtensions.has(e))
      .sort((a, b) => (a.fileExtensions.size - b.fileExtensions.size) || (a.year - b.year));
  }

  const aliasList = SYSTEMS.flatMap((s) => s.folderAliases.map((a) => [a, s])).sort((a, b) => b[0].length - a[0].length);
  const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  /** La console qu'un nom de dossier désigne (« PS2 », « Wii : Wii U »…). */
  function systemForFolderName(raw) {
    const name = raw.toLowerCase().replace(/_/g, ' ').trim();
    for (const [alias, s] of aliasList) if (name === alias) return s;
    for (const [alias, s] of aliasList) {
      if (name.includes(alias) && new RegExp(`(^|[^a-z0-9])${escapeRe(alias)}([^a-z0-9]|$)`).test(name)) return s;
    }
    return null;
  }

  // ── Émulateurs ───────────────────────────────────────────────────────────
  //
  // Un émulateur est reconnu par son identifiant Flatpak, par son programme
  // dans le PATH, ou par une AppImage dont le nom le désigne. `{rom}` est
  // remplacé par le jeu ; `direct` est le lancement plein écran sans interface.

  const emu = (id, name, systems, o) => ({
    id, name, systems, flatpak: o.flatpak || [], bins: o.bins || [], appimage: o.appimage || null,
    launch: o.launch || ['{rom}'], direct: o.direct || null, homepage: o.homepage || null, resume: o.resume || {},
    github: o.github || null, saves: o.saves || [],
  });

  const EMULATORS = [
    emu('dolphin', 'Dolphin', ['gc', 'wii'], { flatpak: ['org.DolphinEmu.dolphin-emu'], bins: ['dolphin-emu'], appimage: /dolphin/i,
      launch: ['-e', '{rom}'], direct: ['-b', '-e', '{rom}'], homepage: 'https://dolphin-emu.org', resume: { file: ['--save_state={state}'] } }),
    emu('cemu', 'Cemu', ['wiiu'], { flatpak: ['info.cemu.Cemu'], bins: ['cemu', 'Cemu'], appimage: /cemu/i, launch: ['-g', '{rom}'], direct: ['-f', '-g', '{rom}'], homepage: 'https://cemu.info', github: 'cemu-project/Cemu' }),
    emu('ryujinx', 'Ryujinx', ['switch'], { flatpak: ['io.github.ryubing.Ryujinx', 'org.ryujinx.Ryujinx'], bins: ['Ryujinx', 'ryujinx'], appimage: /ryujinx/i, direct: ['--fullscreen', '{rom}'], homepage: 'https://ryujinx.app' }),
    emu('eden', 'Eden', ['switch'], { bins: ['eden'], appimage: /^eden/i, direct: ['-f', '-g', '{rom}'], launch: ['-g', '{rom}'] }),
    emu('citron', 'Citron', ['switch'], { bins: ['citron'], appimage: /citron/i }),
    emu('sudachi', 'Sudachi', ['switch'], { bins: ['sudachi'], appimage: /sudachi/i, direct: ['-f', '{rom}'] }),
    emu('yuzu', 'Yuzu', ['switch'], { flatpak: ['org.yuzu_emu.yuzu'], bins: ['yuzu'], appimage: /yuzu/i }),
    emu('duckstation', 'DuckStation', ['ps1'], { flatpak: ['org.duckstation.DuckStation'], bins: ['duckstation-qt', 'duckstation'], appimage: /duckstation/i,
      launch: ['--', '{rom}'], direct: ['-fullscreen', '-batch', '--', '{rom}'], homepage: 'https://duckstation.org', github: 'stenzek/duckstation',
      resume: { auto: ['-resume'], slot: ['-state', '{slot}'], file: ['-statefile', '{state}'] } }),
    emu('pcsx2', 'PCSX2', ['ps2'], { flatpak: ['net.pcsx2.PCSX2'], bins: ['pcsx2-qt', 'pcsx2'], appimage: /pcsx2/i,
      launch: ['--', '{rom}'], direct: ['-batch', '-fullscreen', '--', '{rom}'], homepage: 'https://pcsx2.net', github: 'PCSX2/pcsx2',
      // L'emplacement -1, c'est l'état que PCSX2 écrit en quittant.
      resume: { auto: ['-state', '-1'], slot: ['-state', '{slot}'], file: ['-statefile', '{state}'] } }),
    emu('rpcs3', 'RPCS3', ['ps3'], { flatpak: ['net.rpcs3.RPCS3'], bins: ['rpcs3'], appimage: /rpcs3/i, direct: ['--no-gui', '{rom}'], github: 'RPCS3/rpcs3' }),
    emu('shadps4', 'shadPS4', ['ps4'], { flatpak: ['net.shadps4.shadPS4'], bins: ['shadps4'], appimage: /shadps4/i, launch: ['-g', '{rom}'], github: 'shadps4-emu/shadPS4' }),
    emu('ppsspp', 'PPSSPP', ['psp'], { flatpak: ['org.ppsspp.PPSSPP'], bins: ['PPSSPPSDL', 'ppsspp', 'PPSSPPQt'], appimage: /ppsspp/i,
      direct: ['--fullscreen', '{rom}'], homepage: 'https://ppsspp.org', github: 'hrydgard/ppsspp', resume: { file: ['--state={state}'] } }),
    emu('vita3k', 'Vita3K', ['vita'], { flatpak: ['org.vita3k.Vita3K'], bins: ['Vita3K', 'vita3k'], appimage: /vita3k/i, launch: ['-r', '{rom}'], github: 'Vita3K/Vita3K' }),
    emu('melonds', 'melonDS', ['nds'], { flatpak: ['net.kuribo64.melonDS'], bins: ['melonDS', 'melonds'], appimage: /melonds/i, direct: ['-f', '{rom}'], github: 'melonDS-emu/melonDS' }),
    emu('azahar', 'Azahar', ['n3ds'], { flatpak: ['org.azahar_emu.Azahar'], bins: ['azahar', 'azahar-qt'], appimage: /azahar/i, direct: ['-f', '{rom}'], github: 'azahar-emu/azahar' }),
    emu('lime3ds', 'Lime3DS', ['n3ds'], { flatpak: ['io.github.lime3ds.Lime3DS'], bins: ['lime3ds', 'lime3ds-gui'], appimage: /lime3ds/i }),
    emu('citra', 'Citra', ['n3ds'], { flatpak: ['org.citra_emu.citra'], bins: ['citra-qt', 'citra'], appimage: /citra/i }),
    emu('snes9x', 'Snes9x', ['snes'], { flatpak: ['com.snes9x.Snes9x'], bins: ['snes9x-gtk', 'snes9x'], github: 'snes9xgit/snes9x' }),
    emu('vbam', 'VisualBoyAdvance-M', ['gba', 'gb', 'gbc'], { flatpak: ['com.vba_m.visualboyadvance-m'], bins: ['visualboyadvance-m'], appimage: /visualboyadvance/i, direct: ['-f', '{rom}'] }),
    emu('mgba', 'mGBA', ['gba', 'gb', 'gbc'], { flatpak: ['io.mgba.mGBA'], bins: ['mgba-qt', 'mgba'], appimage: /mgba/i, direct: ['-f', '{rom}'], github: 'mgba-emu/mgba' }),
    emu('mesen', 'Mesen', ['nes', 'snes', 'gb', 'gbc', 'pcengine'], { bins: ['Mesen', 'mesen'], appimage: /mesen/i, github: 'SourMesen/Mesen2' }),
    emu('ares', 'ares', ['nes', 'snes', 'n64', 'gb', 'gbc', 'gba', 'genesis', 'mastersystem', 'gamegear', 'sega32x', 'saturn', 'pcengine', 'ngp', 'wonderswan', 'lynx', 'atari2600', 'vb', 'ps1'],
      { flatpak: ['dev.ares.ares'], bins: ['ares'], appimage: /^ares/i, direct: ['--fullscreen', '{rom}'], homepage: 'https://ares-emu.net', github: 'ares-emulator/ares' }),
    emu('simple64', 'simple64', ['n64'], { flatpak: ['io.github.simple64.simple64'], bins: ['simple64-gui'], appimage: /simple64/i }),
    emu('flycast', 'Flycast', ['dreamcast'], { flatpak: ['org.flycast.Flycast'], bins: ['flycast'], appimage: /flycast/i, github: 'flyinghead/flycast' }),
    emu('redream', 'redream', ['dreamcast'], { bins: ['redream'] }),
    emu('xemu', 'xemu', ['xbox'], { flatpak: ['app.xemu.xemu'], bins: ['xemu'], appimage: /xemu/i, launch: ['-dvd_path', '{rom}'], github: 'xemu-project/xemu' }),
    emu('xenia', 'Xenia Canary', ['xbox360'], { bins: ['xenia_canary', 'xenia'], appimage: /xenia/i, direct: ['--fullscreen=true', '{rom}'] }),
    emu('mame', 'MAME', ['arcade', 'neogeo'], { flatpak: ['org.mamedev.MAME'], bins: ['mame'], github: 'mamedev/mame' }),
    // RetroArch a besoin d'un cœur (-L) : choisi d'après la console, parmi ceux installés.
    emu('retroarch', 'RetroArch', SYSTEMS.map((s) => s.id).filter((s) => !['windows', 'linux'].includes(s)), { flatpak: ['org.libretro.RetroArch'], bins: ['retroarch'], appimage: /retroarch/i,
      direct: ['-f', '{rom}'], homepage: 'https://retroarch.com', github: 'libretro/RetroArch' }),
    emu('uzdoom', 'UZDoom', ['doom'], { bins: ['uzdoom'], appimage: /uzdoom/i, launch: ['-iwad', '{rom}'], direct: ['-fullscreen', '-iwad', '{rom}'], github: 'UZDoom/UZDoom' }),
    emu('gzdoom', 'GZDoom', ['doom'], { flatpak: ['org.zdoom.GZDoom'], bins: ['gzdoom'], appimage: /gzdoom/i, launch: ['-iwad', '{rom}'], direct: ['-fullscreen', '-iwad', '{rom}'] }),
    emu('dosbox', 'DOSBox-X', ['dos'], { flatpak: ['com.dosbox_x.DOSBox-X'], bins: ['dosbox-x'], launch: ['-conf', '{rom}'] }),
    emu('dosboxstaging', 'DOSBox Staging', ['dos'], { flatpak: ['io.github.dosbox-staging'], bins: ['dosbox'], launch: ['-conf', '{rom}'] }),
    // Pas un programme à trouver : présent dès que Steam a installé un Proton.
    emu('proton', 'Proton', ['windows'], {}),
  ];
  const EMULATOR_BY_ID = Object.fromEntries(EMULATORS.map((e) => [e.id, e]));

  /** Les arguments qui font honorer une demande de reprise, ou null si l'émulateur ne sait pas. */
  function resumeArguments(spec, request) {
    const r = spec.resume || {};
    switch (request.type) {
      case 'fromStart': return [];
      case 'auto':
        if (r.auto) return r.auto;
        if (r.slot) return r.slot.map((x) => x.replace('{slot}', '1'));
        return null;
      case 'slot': return r.slot ? r.slot.map((x) => x.replace('{slot}', String(request.slot))) : null;
      case 'file': return r.file ? r.file.map((x) => x.replace('{state}', request.path)) : null;
      default: return null;
    }
  }
  const resumeSupported = (spec) => !!(spec.resume && (spec.resume.auto || spec.resume.slot || spec.resume.file));

  // ── Noms de dumps ────────────────────────────────────────────────────────
  //
  // « Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De).z64 » →
  // « The Legend of Zelda - Ocarina of Time », en gardant région, langues et
  // numéro de disque, dont la recherche de jaquette a besoin.

  const regions = new Set(['europe', 'usa', 'japan', 'world', 'france', 'germany', 'italy', 'spain', 'korea', 'china', 'taiwan',
    'brazil', 'australia', 'canada', 'netherlands', 'sweden', 'norway', 'denmark', 'finland', 'russia', 'asia', 'uk',
    'usa, europe', 'japan, usa', 'europe, australia', 'japan, europe', 'united kingdom', 'hong kong', 'greece', 'portugal', 'poland', 'unknown']);
  const regionLabels = {
    europe: 'Europe', usa: 'États-Unis', japan: 'Japon', world: 'Monde', france: 'France', germany: 'Allemagne', italy: 'Italie',
    spain: 'Espagne', korea: 'Corée', china: 'Chine', taiwan: 'Taïwan', brazil: 'Brésil', australia: 'Australie', canada: 'Canada',
    netherlands: 'Pays-Bas', sweden: 'Suède', norway: 'Norvège', denmark: 'Danemark', finland: 'Finlande', russia: 'Russie', asia: 'Asie',
    uk: 'Royaume-Uni', 'united kingdom': 'Royaume-Uni', greece: 'Grèce', portugal: 'Portugal', poland: 'Pologne', 'hong kong': 'Hong Kong',
    unknown: 'Région inconnue',
  };
  const languageCodes = new Set(['en', 'fr', 'de', 'es', 'it', 'ja', 'nl', 'pt', 'sv', 'no', 'da', 'fi', 'zh', 'ko', 'ru', 'pl', 'cs',
    'hu', 'tr', 'ar', 'he', 'el', 'ca', 'zh-hant', 'zh-hans', 'pt-br', 'es-419']);

  function parseName(raw) {
    const result = { title: raw, region: null, languages: [], revision: null, disc: null, tags: [], raw };
    const groups = [];
    let working = raw.replace(/[([]([^)\]]*)[)\]]/g, (_m, g) => { groups.push(g); return ' '; });
    for (const g of groups) classify(g, result);
    working = working.replace(/_/g, ' ').replace(/ {2,}/g, ' ').replace(/^[ \-–—.·]+|[ \-–—.·]+$/g, '');
    // « Super-Mario-Sunshine-Europe-En-Fr-De-Es-It »
    if (!working.includes(' ') && working.includes('-')) working = unpackHyphenated(working, result);
    result.title = moveTrailingArticle(working) || raw;
    return result;
  }

  function classify(group, r) {
    const t = group.trim();
    if (!t) return;
    const lower = t.toLowerCase();
    if (regions.has(lower)) { r.region = regionLabels[lower] || t; return; }
    const parts = lower.split(',').map((p) => p.trim());
    if (parts.length && parts.every((p) => languageCodes.has(p))) { r.languages = parts.map((p) => p.toUpperCase()); return; }
    const d = /^(disc|disk|disque|cd)\s*([0-9]+)$/.exec(lower);
    if (d) { r.disc = parseInt(d[2], 10); return; }
    if (lower.startsWith('rev ') || /^v[0-9.]+$/.test(lower)) { r.revision = t; return; }
    if (t.length >= 12 && /^[0-9a-f]+$/i.test(t)) return;   // identifiants de titre : sans intérêt pour un humain
    r.tags.push(t);
  }

  function unpackHyphenated(name, r) {
    const tokens = name.split('-');
    const langs = [];
    let region = null;
    while (tokens.length) {
      const last = tokens[tokens.length - 1], lower = last.toLowerCase();
      if (languageCodes.has(lower)) { langs.unshift(last.toUpperCase()); tokens.pop(); } else if (regions.has(lower)) { region = regionLabels[lower] || last; tokens.pop(); } else break;
    }
    if (!r.region) r.region = region;
    if (!r.languages.length) r.languages = langs;
    return tokens.join(' ');
  }

  function moveTrailingArticle(title) {
    for (const a of ['The', 'A', 'An', 'Le', 'La', 'Les', "L'", 'Der', 'Die', 'Das', 'El', 'Los']) {
      const i = title.indexOf(`, ${a}`);
      if (i >= 0) {
        const after = title.slice(i + a.length + 2);
        if (after && /^[A-Za-z]/.test(after)) continue;   // « , Thebes » n'est pas un article
        return `${a} ${title.slice(0, i)}${after}`.replace(/ {2,}/g, ' ').trim();
      }
    }
    return title;
  }

  /** Minuscules, sans accents ni ponctuation : pour comparer un nom de ROM à un index. */
  function normalize(text) {
    return String(text).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
      .replace(/[^\p{L}\p{N}]/gu, ' ').replace(/ {2,}/g, ' ').trim();
  }
  const normalizedCore = (text) => normalize(String(text).replace(/[([][^)\]]*[)\]]/g, ' '));
  const stopWords = new Set(['the', 'a', 'an', 'of', 'and', 'le', 'la', 'les', 'de', 'du']);
  const tokens = (text) => new Set(normalize(text).split(' ').filter((w) => w && !stopWords.has(w)));

  // ── Vignettes ────────────────────────────────────────────────────────────

  const KIND_LABEL = { rom: 'ROM', game: 'Jeu', emulator: 'Émulateur', other: 'Autre' };

  function bytes(n) {
    if (!n || n < 0) return '';
    const u = ['o', 'Ko', 'Mo', 'Go', 'To'];
    let i = 0; let v = n;
    while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
    return `${v.toFixed(v >= 100 || i === 0 ? 0 : 1).replace('.', ',')} ${u[i]}`;
  }

  /** « SNES · France · 1,0 Mo » */
  function subtitle(item) {
    const parts = [];
    const s = SYSTEM_BY_ID[item.systemID];
    if (item.kind === 'other') parts.push('Autre');
    else if (s) parts.push(s.shortName);
    if (item.region) parts.push(item.region);
    if (item.discs && item.discs.length > 1) parts.push(`${item.discs.length} disques`);
    if (item.fileSize > 0) parts.push(bytes(item.fileSize));
    if (item.kind !== 'rom' && item.appVersion) parts.push(`v${item.appVersion}`);
    return parts.join(' · ');
  }

  function symbolOf(item) {
    if (item.kind === 'emulator') return 'cpu';
    if (item.kind === 'other') return 'doc';
    if (item.kind === 'game') return SYSTEM_BY_ID[item.systemID] ? SYSTEM_BY_ID[item.systemID].symbol : 'app';
    return SYSTEM_BY_ID[item.systemID] ? SYSTEM_BY_ID[item.systemID].symbol : 'gamepad';
  }

  const haystack = (it) => {
    const s = SYSTEM_BY_ID[it.systemID];
    return [it.title, it.rawName, it.region || '', s ? s.name : '', s ? s.shortName : '', (it.tags || []).join(' ')].join(' ').toLowerCase();
  };

  // ── Sections ─────────────────────────────────────────────────────────────

  const SECTIONS = [
    { id: 'all', title: 'Tout', icon: 'grid' },
    { id: 'recent', title: 'Joués récemment', icon: 'history' },
    { id: 'favorites', title: 'Favoris', icon: 'heart' },
    { id: 'roms', title: 'ROM installées', icon: 'disc' },
    { id: 'games', title: 'Jeux installés', icon: 'app' },
    { id: 'emulators', title: 'Émulateurs', icon: 'cpu' },
    { id: 'other', title: 'Autres', icon: 'doc' },
    { id: 'unplayable', title: 'Sans émulateur', icon: 'warning' },
    { id: 'updates', title: 'Mises à jour', icon: 'downCircle' },
    { id: 'backups', title: 'Sauvegarde', icon: 'drive' },
  ];
  const SORTS = [
    { id: 'title', label: 'Titre' }, { id: 'recentlyPlayed', label: 'Joué récemment' }, { id: 'recentlyAdded', label: 'Ajouté récemment' },
    { id: 'system', label: 'Console' }, { id: 'size', label: 'Taille' },
  ];

  function sectionTitle(sel) {
    if (sel.startsWith('system:')) return (SYSTEM_BY_ID[sel.slice(7)] || { name: sel.slice(7) }).name;
    if (sel.startsWith('source:')) return sel.slice(7).split('/').pop();
    return (SECTIONS.find((s) => s.id === sel) || SECTIONS[0]).title;
  }

  const collator = new Intl.Collator('fr', { numeric: true, sensitivity: 'base' });

  /**
   * ctx : { states, playable(item) -> bool, hidden(id) }
   */
  function inSection(it, sel, ctx) {
    const st = ctx.states[it.id] || {};
    switch (sel) {
      case 'all': return it.kind !== 'emulator' && it.kind !== 'other';
      case 'recent': return !!st.lastPlayed;
      case 'favorites': return !!st.favorite;
      case 'roms': return it.kind === 'rom';
      case 'games': return it.kind === 'game';
      case 'emulators': return it.kind === 'emulator';
      case 'other': return it.kind === 'other';
      case 'unplayable': return it.kind === 'rom' && !ctx.playable(it);
      default:
        if (sel.startsWith('system:')) return (it.kind === 'rom' || it.kind === 'game') && it.systemID === sel.slice(7);
        if (sel.startsWith('source:')) return !!it.sourceRoot && (it.sourceRoot === sel.slice(7) || it.sourceRoot.startsWith(sel.slice(7) + '/'));
        return true;
    }
  }

  function counts(items, ctx) {
    const c = {};
    const bump = (k) => { c[k] = (c[k] || 0) + 1; };
    for (const it of items) {
      if (ctx.hidden(it.id)) continue;
      for (const s of ['all', 'recent', 'favorites', 'roms', 'games', 'emulators', 'other', 'unplayable']) if (inSection(it, s, ctx)) bump(s);
      if (it.kind === 'rom' || it.kind === 'game') bump('system:' + it.systemID);
      if (it.sourceRoot) bump('source:' + it.sourceRoot);
    }
    return c;
  }

  function visible(items, sel, search, sort, ctx) {
    const q = search.trim().toLowerCase();
    let list = items.filter((it) => !ctx.hidden(it.id) && inSection(it, sel, ctx) && (!q || haystack(it).includes(q)));
    const st = (it) => ctx.states[it.id] || {};
    if (sel === 'recent') return list.sort((a, b) => (st(b).lastPlayed || 0) - (st(a).lastPlayed || 0));
    switch (sort) {
      case 'recentlyPlayed': return list.sort((a, b) => ((st(b).lastPlayed || 0) - (st(a).lastPlayed || 0)) || collator.compare(a.sortTitle, b.sortTitle));
      case 'recentlyAdded': return list.sort((a, b) => b.dateAdded - a.dateAdded);
      case 'size': return list.sort((a, b) => b.fileSize - a.fileSize);
      case 'system': return list.sort((a, b) => {
        const sa = SYSTEM_BY_ID[a.systemID], sb = SYSTEM_BY_ID[b.systemID];
        return collator.compare(sa ? sa.name : '', sb ? sb.name : '') || collator.compare(a.sortTitle, b.sortTitle);
      });
      default: return list.sort((a, b) => collator.compare(a.sortTitle, b.sortTitle));
    }
  }

  return {
    SYSTEMS, SYSTEM_BY_ID, allExtensions, systemsForExtension, systemForFolderName, EMULATORS, EMULATOR_BY_ID, resumeArguments,
    resumeSupported, parseName, normalize, normalizedCore, tokens, KIND_LABEL, bytes, subtitle, symbolOf, SECTIONS, SORTS, sectionTitle,
    inSection, counts, visible, collator,
  };
}));
