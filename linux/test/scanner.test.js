'use strict';
// Les cas de Tests/BiblijeuTests/RomScannerTests.swift, plus ceux propres à Linux.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Scanner = require('../src/scanner');
const S = require('../src/shared');

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'biblijeu-'));
  return {
    root,
    file(rel, content = 'x', mode) {
      const p = path.join(root, rel);
      fs.mkdirSync(path.dirname(p), { recursive: true });
      fs.writeFileSync(p, content);
      if (mode) fs.chmodSync(p, mode);
      return p;
    },
    scan(excluded = []) { return Scanner.scanRoms([root], excluded); },
  };
}
const titles = (items) => new Set(items.map((i) => i.title));

test('le dossier tranche entre les consoles qui partagent une extension', () => {
  const f = fixture();
  f.file('PS2/Shadow of the Colossus (Europe).iso');
  f.file('GameCube/Pikmin (Europe).iso');
  f.file('Wii/Zelda Twilight Princess.iso');
  const by = Object.fromEntries(f.scan().map((i) => [i.title, i.systemID]));
  assert.deepStrictEqual(by, { 'Shadow of the Colossus': 'ps2', Pikmin: 'gc', 'Zelda Twilight Princess': 'wii' });
});

test('un fichier ambigu hors dossier de console est laissé de côté', () => {
  const f = fixture();
  f.file('Something.iso');
  f.file('notes.md');
  assert.strictEqual(f.scan().length, 0);
});

test("un format qu'une seule console utilise n'a pas besoin de dossier", () => {
  const f = fixture();
  f.file('Super Mario 64 (USA).z64');
  const items = f.scan();
  assert.strictEqual(items.length, 1);
  assert.strictEqual(items[0].systemID, 'n64');
});

test('une feuille de pistes masque ses pistes, et pèse ce que pèsent ses pistes', () => {
  const f = fixture();
  f.file('PS1/Tekken 3 (Europe).cue', 'FILE "Tekken 3 (Europe) (Track 1).bin" BINARY');
  f.file('PS1/Tekken 3 (Europe) (Track 1).bin', 'x'.repeat(700));
  const items = f.scan();
  assert.strictEqual(items.length, 1);
  assert.ok(items[0].path.endsWith('.cue'));
  assert.ok(items[0].fileSize >= 700);
});

test("les disques d'un jeu font une seule vignette", () => {
  const f = fixture();
  for (const d of [1, 2, 3]) f.file(`PS1/Final Fantasy VII (France) (Disc ${d}).chd`);
  const items = f.scan();
  assert.strictEqual(items.length, 1);
  assert.strictEqual(items[0].discs.length, 3);
  assert.ok(items[0].discs[0].endsWith('(Disc 1).chd'));
});

test("mises à jour, DLC et dossiers de travail ne sont pas explorés", () => {
  const f = fixture();
  f.file('Switch/Updates/Game Update.nsp');
  f.file('Switch/DLC/Game DLC.nsp');
  f.file('Switch/0100ABCD_build/romfs.iso');
  f.file('Switch/nxnative-build.noindex/game.nsp');
  f.file('N64/saves/Mario.z64');
  assert.strictEqual(f.scan().length, 0);
});

test("un .zip ne compte que dans un dossier d'arcade", () => {
  const f = fixture();
  f.file('Downloads/emulator-source.zip');
  f.file('MAME/pacman.zip');
  const items = f.scan();
  assert.strictEqual(items.length, 1);
  assert.strictEqual(items[0].systemID, 'arcade');
});

test("un jeu Windows installé est une vignette, pas ses fichiers", () => {
  const f = fixture();
  f.file('PC/Obsidian Quest/ObsidianQuest.exe');
  f.file('PC/Obsidian Quest/unins000.exe');
  f.file('PC/Obsidian Quest/data/maps/level01.wad');
  f.file('PC/Obsidian Quest/data/maps/level02.wad');
  const items = f.scan();
  assert.strictEqual(items.length, 1);
  assert.strictEqual(items[0].systemID, 'windows');
  assert.ok(items[0].path.endsWith('ObsidianQuest.exe'));
});

test('un jeu Linux installé est une vignette, lancée par son exécutable', () => {
  const f = fixture();
  const elf = Buffer.concat([Buffer.from([0x7f, 0x45, 0x4c, 0x46]), Buffer.alloc(60)]);
  f.file('Linux/Hollow Quest/HollowQuest', elf, 0o755);
  f.file('Linux/Hollow Quest/libfoo.so', elf, 0o755);
  f.file('Linux/Hollow Quest/data/level.wad');
  f.file('Linux/Celeste.AppImage', 'x', 0o755);
  const items = f.scan();
  const byPath = Object.fromEntries(items.map((i) => [path.basename(i.path), i]));
  assert.deepStrictEqual(Object.keys(byPath).sort(), ['Celeste.AppImage', 'HollowQuest']);
  assert.strictEqual(byPath.HollowQuest.kind, 'game');
  assert.strictEqual(byPath.HollowQuest.systemID, 'linux');
});

test('les fichiers ._ et les dossiers exclus sont ignorés', () => {
  const f = fixture();
  f.file('N64/._Super Mario 64.z64');
  f.file('N64/Mario.z64');
  f.file('Old/Zelda.z64');
  assert.deepStrictEqual(titles(f.scan([path.join(f.root, 'Old')])), new Set(['Mario']));
});

test("un dossier absent n'est pas une erreur", () => {
  assert.deepStrictEqual(Scanner.scanRoms(['/nulle/part'], []), []);
});

test('les changements dans les dossiers ignorés ne relancent rien', () => {
  const root = '/media/roms', roots = [root];
  assert.ok(Scanner.ignoresChange(root + '/Switch/0100_build/a/b.bin', roots, []));
  assert.ok(Scanner.ignoresChange(root + '/N64/saves/mario.eep', roots, []));
  assert.ok(Scanner.ignoresChange(root + '/Old/x.z64', roots, [root + '/Old']));
  assert.ok(!Scanner.ignoresChange(root + '/N64/Zelda.z64', roots, []));
});

test('noms de dumps', () => {
  const p = S.parseName('Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De)');
  assert.strictEqual(p.title, 'The Legend of Zelda - Ocarina of Time');
  assert.strictEqual(p.region, 'Europe');
  assert.deepStrictEqual(p.languages, ['EN', 'FR', 'DE']);
  const h = S.parseName('Super-Mario-Sunshine-Europe-En-Fr-De-Es-It');
  assert.strictEqual(h.title, 'Super Mario Sunshine');
  assert.strictEqual(h.languages.length, 5);
  assert.strictEqual(S.parseName('Final Fantasy VII (France) (Disc 2)').disc, 2);
});

test('« Wii U » passe avant « Wii »', () => {
  assert.strictEqual(S.systemForFolderName('Wii U').id, 'wiiu');
  assert.strictEqual(S.systemForFolderName('Switch Firmware').id, 'switch');
  assert.strictEqual(S.systemForFolderName('Mes trucs'), null);
});
