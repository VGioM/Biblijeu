// artwork.js — les jaquettes. Rétro : l'archive libretro (thumbnails.libretro.com),
// sans compte ni clé, rangée sous les noms No-Intro / Redump que portent la
// plupart des dumps. Le reste (Switch, jeux PC) : SteamGridDB, avec une clé
// gratuite. Traduction de LibretroThumbnails.swift, SteamGridDBProvider.swift
// et ArtworkService.swift.
'use strict';

const fs = require('fs');
const path = require('path');
const S = require('./shared');

const noise = new Set(['demo', 'beta', 'proto', 'prototype', 'sample', 'kiosk', 'alt', 'unl', 'pirate', 'hack', 'trial', 'preview',
  'debug', 'test', 'aftermarket', 'promo', 'bonus']);
const regionKeys = ['europe', 'usa', 'japan', 'world', 'france', 'germany', 'italy', 'spain', 'korea', 'australia', 'brazil', 'china', 'taiwan', 'netherlands', 'sweden'];
const labelToKey = { europe: 'europe', france: 'france', 'états-unis': 'usa', 'etats-unis': 'usa', usa: 'usa', japon: 'japan', japan: 'japan', monde: 'world', world: 'world' };
const regionKeyForLabel = (l) => labelToKey[String(l).toLowerCase()] || 'europe';
const regionKeyIn = (name) => { const l = name.toLowerCase(); return regionKeys.find((r) => l.includes(`(${r}`)) || null; };

// Pas d'espace laissé tel quel : il doit devenir %20.
const enc = (s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => c);

class Libretro {
  constructor(dir) { this.dir = dir; this.indexes = new Map(); this.loading = new Map(); fs.mkdirSync(dir, { recursive: true }); }

  url(folder, filename, variant = 'Named_Boxarts') {
    return `https://thumbnails.libretro.com/${enc(folder)}/${variant}/${enc(filename)}`;
  }

  entries(names) {
    return names.map((name) => {
      const base = name.replace(/\.png$/i, '');
      const core = S.normalizedCore(base), full = S.normalize(base);
      return { filename: name, full, core, tokens: S.tokens(core), fullTokens: S.tokens(full), region: regionKeyIn(base) };
    }).filter((e) => e.full);
  }

  async index(folder) {
    if (this.indexes.has(folder)) return this.indexes.get(folder);
    if (this.loading.has(folder)) return this.loading.get(folder);
    const task = (async () => {
      const file = path.join(this.dir, folder.replace(/[^A-Za-z0-9]+/g, '-') + '.txt');
      try {
        const st = fs.statSync(file);
        // Un index change rarement : un mois entre deux téléchargements suffit.
        if (Date.now() - st.mtimeMs < 30 * 86400000) return this.entries(fs.readFileSync(file, 'utf8').split('\n').filter(Boolean));
      } catch { /* pas encore en cache */ }
      try {
        const res = await fetch(`https://thumbnails.libretro.com/${enc(folder)}/Named_Boxarts/`, { signal: AbortSignal.timeout(60000) });
        if (!res.ok) throw new Error(String(res.status));
        const html = await res.text();
        const names = [];
        for (const m of html.matchAll(/href="([^"]+\.png)"/g)) { try { names.push(decodeURIComponent(m[1])); } catch { /* nom illisible */ } }
        if (!names.length) throw new Error('vide');
        fs.writeFileSync(file, names.join('\n'));
        return this.entries(names);
      } catch {
        // Hors ligne : un index périmé vaut mieux que rien.
        try { return this.entries(fs.readFileSync(file, 'utf8').split('\n').filter(Boolean)); } catch { return []; }
      }
    })();
    this.loading.set(folder, task);
    const entries = await task;
    this.loading.delete(folder);
    if (entries.length) this.indexes.set(folder, entries);
    return entries;
  }

  async ranked(rawName, system, preferredRegion, threshold, limit) {
    if (!system.libretroFolder) return [];
    const entries = await this.index(system.libretroFolder);
    if (!entries.length) return [];
    const full = S.normalize(rawName), core = S.normalizedCore(rawName);
    const qt = S.tokens(core), qft = S.tokens(full);
    if (!qt.size) return [];
    const wanted = regionKeyForLabel(preferredRegion), qRegion = regionKeyIn(rawName);
    const scored = [];
    for (const e of entries) {
      let score;
      if (e.full === full) score = 1000;
      else if (e.core === core) score = 500;
      else {
        let inter = 0; for (const t of qt) if (e.tokens.has(t)) inter++;
        if (!inter) continue;
        const union = new Set([...qt, ...e.tokens]).size;
        const j = inter / union;
        if (j < threshold) continue;
        score = 300 * j;
      }
      if (e.region) { if (qRegion && e.region === qRegion) score += 40; else if (e.region === wanted) score += 25; else if (e.region === 'world') score += 12; }
      const u = new Set([...qft, ...e.fullTokens]).size;
      if (u) { let shared = 0; for (const t of qft) if (e.fullTokens.has(t)) shared++; score += 30 * shared / u; }
      // « (Demo) », « (Beta) », « (Alt) » : seulement si la ROM le réclame.
      let unwanted = 0; for (const t of e.fullTokens) if (noise.has(t) && !qft.has(t)) unwanted++;
      score -= 18 * unwanted;
      let extra = 0; for (const t of e.tokens) if (!qt.has(t)) extra++;
      score -= extra;
      scored.push([e, score]);
    }
    return scored.sort((a, b) => b[1] - a[1]).slice(0, limit).map(([e]) => ({ filename: e.filename, folder: system.libretroFolder }));
  }

  match(raw, system, region) { return this.ranked(raw, system, region, 0.72, 1).then((r) => r[0] || null); }
  candidates(raw, system, region) { return this.ranked(raw, system, region, 0.24, 14); }
  clear() { this.indexes.clear(); for (const f of fs.readdirSync(this.dir)) fs.rmSync(path.join(this.dir, f), { force: true }); }
}

class SteamGridDB {
  constructor() { this.cache = new Map(); }
  async get(url, key) {
    const res = await fetch(url, { headers: { Authorization: `Bearer ${key}` }, signal: AbortSignal.timeout(20000) });
    if (!res.ok) throw new Error(String(res.status));
    return res.json();
  }
  async search(title, key) {
    try {
      const r = await this.get(`https://www.steamgriddb.com/api/v2/search/autocomplete/${encodeURIComponent(S.normalize(title))}`, key);
      return r.success ? r.data : [];
    } catch { return []; }
  }
  async grids(gameID, key, limit) {
    try {
      const r = await this.get(`https://www.steamgriddb.com/api/v2/grids/game/${gameID}?dimensions=600x900,342x482&types=static&nsfw=false&limit=${limit}`, key);
      return r.success ? r.data.map((g) => g.url) : [];
    } catch { return []; }
  }
  async cover(title, key) {
    key = key.trim();
    if (!key) return null;
    const n = S.normalize(title);
    let id = this.cache.get(n);
    if (id === undefined) {
      const games = await this.search(title, key);
      // Le titre exact d'abord : l'autocomplétion rend volontiers les suites avant.
      const hit = games.find((g) => S.normalize(g.name) === n) || games[0];
      id = hit ? hit.id : null;
      this.cache.set(n, id);
    }
    if (id == null) return null;
    return (await this.grids(id, key, 1))[0] || null;
  }
  async candidates(title, key) {
    const out = [];
    const games = (await this.search(title, key.trim())).slice(0, 5);
    for (let i = 0; i < games.length && out.length < 12; i++) {
      for (const u of await this.grids(games[i].id, key.trim(), i === 0 ? 6 : 2)) { out.push({ name: games[i].name, url: u }); if (out.length >= 12) break; }
    }
    return out;
  }
  async validate(key) {
    try { const r = await this.get('https://www.steamgriddb.com/api/v2/search/autocomplete/zelda', key.trim()); return !!r.success; } catch { return false; }
  }
}

/** Une recherche : libretro d'abord, SteamGridDB en repli. */
async function lookup(lib, sgdb, item, searchTitle, region, key) {
  const system = S.SYSTEM_BY_ID[item.systemID];
  if (system && system.libretroFolder && item.kind === 'rom') {
    const m = await lib.match(searchTitle || item.rawName, system, region);
    if (m) return lib.url(m.folder, m.filename);
    // Un dump au nom inhabituel passe encore sur son titre.
    if (!searchTitle && item.title !== item.rawName) {
      const m2 = await lib.match(item.title, system, region);
      if (m2) return lib.url(m2.folder, m2.filename);
    }
  }
  if (!key || !key.trim()) return null;
  return sgdb.cover(searchTitle || item.title, key);
}

async function candidates(lib, sgdb, item, searchTitle, region, key) {
  const out = [], seen = new Set();
  const system = S.SYSTEM_BY_ID[item.systemID];
  if (system && system.libretroFolder) {
    for (const m of await lib.candidates(searchTitle || item.rawName, system, region)) {
      const url = lib.url(m.folder, m.filename);
      if (!seen.has(url)) { seen.add(url); out.push({ title: m.filename.replace(/\.png$/i, ''), source: 'libretro', imageURL: url }); }
    }
  }
  if (key && key.trim()) {
    for (const g of await sgdb.candidates(searchTitle || item.title, key)) {
      if (!seen.has(g.url)) { seen.add(g.url); out.push({ title: g.name, source: 'SteamGridDB', imageURL: g.url }); }
    }
  }
  return out;
}

module.exports = { Libretro, SteamGridDB, lookup, candidates };
