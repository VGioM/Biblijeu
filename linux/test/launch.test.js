'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const S = require('../src/shared');
const Emu = require('../src/emulators');
const Steam = require('../src/steam');
const Backup = require('../src/backup');

test('arguments de reprise', () => {
  const duck = S.EMULATOR_BY_ID.duckstation, dolphin = S.EMULATOR_BY_ID.dolphin, ares = S.EMULATOR_BY_ID.ares;
  assert.deepStrictEqual(S.resumeArguments(duck, { type: 'auto' }), ['-resume']);
  assert.deepStrictEqual(S.resumeArguments(duck, { type: 'slot', slot: 3 }), ['-state', '3']);
  assert.deepStrictEqual(S.resumeArguments(dolphin, { type: 'file', path: '/s.sav' }), ['--save_state=/s.sav']);
  assert.strictEqual(S.resumeArguments(dolphin, { type: 'auto' }), null);
  assert.deepStrictEqual(S.resumeArguments(ares, { type: 'fromStart' }), []);
});

const rom = (() => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'bj-'));
  const p = path.join(d, 'Game (Europe).iso');
  fs.writeFileSync(p, 'x');
  return p;
})();
const item = { id: 'x', kind: 'rom', systemID: 'gc', path: rom, discs: [], title: 'Game' };

test('Flatpak : le dossier du jeu est ouvert au bac à sable, les options vont devant la ROM', () => {
  const e = { id: 'dolphin', name: 'Dolphin', kind: 'flatpak', target: 'org.DolphinEmu.dolphin-emu', spec: S.EMULATOR_BY_ID.dolphin };
  const p = Emu.plan(item, { emulator: e, direct: true, resume: { type: 'fromStart' } });
  assert.deepStrictEqual(p.argv, ['flatpak', 'run', `--filesystem=${path.dirname(rom)}`, 'org.DolphinEmu.dolphin-emu', '-b', '-e', rom]);
});

test("un émulateur qui ne sait pas reprendre le dit, au lieu d'ignorer la demande", () => {
  const e = { id: 'dolphin', name: 'Dolphin', kind: 'native', target: '/usr/bin/dolphin-emu', spec: S.EMULATOR_BY_ID.dolphin };
  assert.match(Emu.plan(item, { emulator: e, resume: { type: 'auto' } }).error, /ne sait pas reprendre/);
});

test("sans émulateur : le message propose ceux du catalogue", () => {
  assert.match(Emu.plan(item, { emulator: null }).error, /Dolphin/);
});

test('un jeu Steam se lance par Steam', () => {
  assert.strictEqual(Emu.plan({ ...item, steamGameID: '570' }, {}).url, 'steam://rungameid/570');
});

test('Exec des .desktop : codes de champ retirés, guillemets respectés', () => {
  assert.deepStrictEqual(Emu.desktopArgv('/usr/bin/flatpak run --branch=stable "com.example.App" %U'), ['/usr/bin/flatpak', 'run', '--branch=stable', 'com.example.App']);
});

test('shortcuts.vdf binaire', () => {
  const parts = [];
  const str = (s) => Buffer.concat([Buffer.from(s, 'utf8'), Buffer.from([0])]);
  parts.push(Buffer.from([0x00]), str('shortcuts'), Buffer.from([0x00]), str('0'));
  const id = Buffer.alloc(4); id.writeUInt32LE(123456);
  parts.push(Buffer.from([0x02]), str('appid'), id, Buffer.from([0x01]), str('AppName'), str('Mon Jeu'), Buffer.from([0x01]), str('Exe'), str('"/jeux/a.exe"'));
  parts.push(Buffer.from([0x08, 0x08, 0x08]));
  const v = Steam.parseBinaryVDF(Buffer.concat(parts));
  assert.deepStrictEqual(v.shortcuts['0'], { appid: 123456, AppName: 'Mon Jeu', Exe: '"/jeux/a.exe"' });
});

test('copie : la plus récente gagne, rien n\'est supprimé, le retour ne crée rien', async () => {
  const a = fs.mkdtempSync(path.join(os.tmpdir(), 'bj-a-')), b = fs.mkdtempSync(path.join(os.tmpdir(), 'bj-b-'));
  fs.writeFileSync(path.join(a, 'old.sav'), 'ici');
  fs.writeFileSync(path.join(a, 'game.sfc'), 'rom');
  fs.writeFileSync(path.join(b, 'old.sav'), 'disque, plus récent');
  fs.writeFileSync(path.join(b, 'only-on-drive.sav'), 'x');
  const past = new Date(Date.now() - 3600 * 1000);
  fs.utimesSync(path.join(a, 'old.sav'), past, past);
  const filter = { excluding: [], onlyExtensions: ['sav'], skipsWorkFolders: true };
  const out = await Backup.copyTree(a, b, filter, { newestWins: true });
  assert.strictEqual(out.keptNewer, 1);
  assert.strictEqual(fs.readFileSync(path.join(b, 'old.sav'), 'utf8'), 'disque, plus récent');
  assert.ok(!fs.existsSync(path.join(b, 'game.sfc')), 'aucune ROM copiée');
  assert.ok(fs.existsSync(path.join(b, 'only-on-drive.sav')), 'rien supprimé');
  const back = await Backup.copyTree(b, a, filter, { newestWins: true, onlyExisting: true });
  assert.strictEqual(back.copied, 1);
  assert.ok(!fs.existsSync(path.join(a, 'only-on-drive.sav')), "le retour ne remplace que ce qui existe ici");
  const again = await Backup.copyTree(a, b, filter, { newestWins: true });
  assert.strictEqual(again.copied, 0);
});

test('ini : le dossier configuré par l\'émulateur', () => {
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'bj-ini-')), 'settings.ini');
  fs.writeFileSync(f, '[Main]\nX = 1\n[Folders]\nSaveStates = /mnt/etats\n');
  assert.strictEqual(Backup.readIni(f, 'Folders', 'SaveStates'), '/mnt/etats');
  assert.strictEqual(Backup.readIni(f, 'Folders', 'Absent'), null);
});
