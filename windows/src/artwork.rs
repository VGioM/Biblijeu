//! Les jaquettes. Rétro : l'archive libretro (thumbnails.libretro.com), sans
//! compte ni clé, rangée sous les noms No-Intro / Redump. Le reste (Switch,
//! jeux PC) : SteamGridDB, avec une clé gratuite.

use crate::catalog::{self, Item, Kind, System};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

const NOISE: &[&str] = &["demo", "beta", "proto", "prototype", "sample", "kiosk", "alt", "unl", "pirate", "hack", "trial", "preview", "debug", "test", "aftermarket", "promo", "bonus"];
const REGION_KEYS: &[&str] = &["europe", "usa", "japan", "world", "france", "germany", "italy", "spain", "korea", "australia", "brazil", "china", "taiwan", "netherlands", "sweden"];

fn region_for_label(l: &str) -> &'static str {
    match l.to_lowercase().as_str() { "france" => "france", "états-unis" | "etats-unis" | "usa" => "usa", "japon" | "japan" => "japan", "monde" | "world" => "world", _ => "europe" }
}
fn region_in(name: &str) -> Option<&'static str> { let l = name.to_lowercase(); REGION_KEYS.iter().copied().find(|r| l.contains(&format!("({r}"))) }

/// Encodage d'URL, en laissant `!'()*` tels quels (comme encodeURIComponent).
pub fn enc(s: &str) -> String {
    let mut o = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~!'()*".contains(&b) { o.push(b as char); } else { o += &format!("%{b:02X}"); }
    }
    o
}
fn dec(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = vec![];
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() { out.push(u8::from_str_radix(std::str::from_utf8(&b[i + 1..i + 3]).ok()?, 16).ok()?); i += 3; } else { out.push(b[i]); i += 1; }
    }
    String::from_utf8(out).ok()
}

struct Entry { filename: String, full: String, core: String, tokens: HashSet<String>, full_tokens: HashSet<String>, region: Option<&'static str> }

pub struct Libretro { dir: PathBuf, indexes: Mutex<HashMap<String, Arc<Vec<Entry>>>>, loading: Mutex<()> }

#[derive(Clone, Debug)]
pub struct Candidate { pub title: String, pub source: &'static str, pub url: String }

impl Libretro {
    pub fn new(dir: PathBuf) -> Self { let _ = std::fs::create_dir_all(&dir); Libretro { dir, indexes: Mutex::new(HashMap::new()), loading: Mutex::new(()) } }
    pub fn url(folder: &str, filename: &str) -> String { format!("https://thumbnails.libretro.com/{}/Named_Boxarts/{}", enc(folder), enc(filename)) }

    fn entries(names: &[String]) -> Vec<Entry> {
        names.iter().filter_map(|n| {
            let base = n.strip_suffix(".png").unwrap_or(n);
            let (core, full) = (catalog::normalized_core(base), catalog::normalize(base));
            if full.is_empty() { return None; }
            Some(Entry { filename: n.clone(), tokens: catalog::tokens(&core), full_tokens: catalog::tokens(&full), core, full, region: region_in(base) })
        }).collect()
    }

    fn index(&self, folder: &str) -> Arc<Vec<Entry>> {
        if let Some(e) = self.indexes.lock().unwrap().get(folder) { return e.clone(); }
        // Un seul téléchargement d'index à la fois : les autres attendent et le relisent.
        let _g = self.loading.lock().unwrap();
        if let Some(e) = self.indexes.lock().unwrap().get(folder) { return e.clone(); }
        let file = self.dir.join(format!("{}.txt", folder.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect::<String>().split('-').filter(|s| !s.is_empty()).collect::<Vec<_>>().join("-")));
        let read = || std::fs::read_to_string(&file).ok().map(|t| t.lines().filter(|l| !l.is_empty()).map(String::from).collect::<Vec<_>>());
        let fresh = std::fs::metadata(&file).ok().and_then(|m| m.modified().ok()).and_then(|t| t.elapsed().ok()).map(|d| d.as_secs() < 30 * 86400).unwrap_or(false);
        let names = if fresh { read().unwrap_or_default() } else {
            let got = (|| -> Option<Vec<String>> {
                let html = crate::common::images::http_agent().get(&format!("https://thumbnails.libretro.com/{}/Named_Boxarts/", enc(folder))).call().ok()?.body_mut().read_to_string().ok()?;
                let mut names = vec![];
                let mut rest = html.as_str();
                while let Some(i) = rest.find("href=\"") {
                    rest = &rest[i + 6..];
                    let Some(j) = rest.find('"') else { break };
                    let h = &rest[..j];
                    if h.ends_with(".png") { if let Some(d) = dec(h) { names.push(d); } }
                    rest = &rest[j..];
                }
                (!names.is_empty()).then_some(names)
            })();
            match got { Some(n) => { let _ = std::fs::write(&file, n.join("\n")); n } None => read().unwrap_or_default() }
        };
        let e = Arc::new(Self::entries(&names));
        if !e.is_empty() { self.indexes.lock().unwrap().insert(folder.into(), e.clone()); }
        e
    }

    fn ranked(&self, raw: &str, sys: &System, preferred: &str, threshold: f64, limit: usize) -> Vec<(String, String)> {
        let Some(folder) = sys.libretro else { return vec![] };
        let entries = self.index(folder);
        if entries.is_empty() { return vec![]; }
        let (full, core) = (catalog::normalize(raw), catalog::normalized_core(raw));
        let (qt, qft) = (catalog::tokens(&core), catalog::tokens(&full));
        if qt.is_empty() { return vec![]; }
        let (wanted, qr) = (region_for_label(preferred), region_in(raw));
        let mut scored: Vec<(&Entry, f64)> = vec![];
        for e in entries.iter() {
            let mut score = if e.full == full { 1000.0 } else if e.core == core { 500.0 } else {
                let inter = qt.iter().filter(|t| e.tokens.contains(*t)).count();
                if inter == 0 { continue; }
                let j = inter as f64 / qt.union(&e.tokens).count() as f64;
                if j < threshold { continue; }
                300.0 * j
            };
            if let Some(r) = e.region { if Some(r) == qr { score += 40.0 } else if r == wanted { score += 25.0 } else if r == "world" { score += 12.0 } }
            let u = qft.union(&e.full_tokens).count();
            if u > 0 { score += 30.0 * qft.iter().filter(|t| e.full_tokens.contains(*t)).count() as f64 / u as f64; }
            // « (Demo) », « (Beta) » : seulement si la ROM le réclame.
            score -= 18.0 * e.full_tokens.iter().filter(|t| NOISE.contains(&t.as_str()) && !qft.contains(*t)).count() as f64;
            score -= e.tokens.iter().filter(|t| !qt.contains(*t)).count() as f64;
            scored.push((e, score));
        }
        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
        scored.into_iter().take(limit).map(|(e, _)| (folder.to_string(), e.filename.clone())).collect()
    }

    pub fn matched(&self, raw: &str, sys: &System, region: &str) -> Option<String> { self.ranked(raw, sys, region, 0.72, 1).first().map(|(f, n)| Self::url(f, n)) }
    pub fn clear(&self) {
        self.indexes.lock().unwrap().clear();
        if let Ok(rd) = std::fs::read_dir(&self.dir) { for e in rd.flatten() { let _ = std::fs::remove_file(e.path()); } }
    }
}

pub struct SteamGridDb { ids: Mutex<HashMap<String, Option<u64>>> }

impl SteamGridDb {
    pub fn new() -> Self { SteamGridDb { ids: Mutex::new(HashMap::new()) } }
    fn get(url: &str, key: &str) -> Option<serde_json::Value> {
        let v: serde_json::Value = crate::common::images::http_agent().get(url).header("Authorization", &format!("Bearer {key}")).call().ok()?.body_mut().read_json().ok()?;
        v["success"].as_bool().unwrap_or(false).then_some(v)
    }
    fn search(title: &str, key: &str) -> Vec<(u64, String)> {
        Self::get(&format!("https://www.steamgriddb.com/api/v2/search/autocomplete/{}", enc(&catalog::normalize(title))), key)
            .and_then(|v| v["data"].as_array().cloned()).unwrap_or_default().iter()
            .filter_map(|g| Some((g["id"].as_u64()?, g["name"].as_str()?.to_string()))).collect()
    }
    fn grids(id: u64, key: &str, limit: u32) -> Vec<String> {
        Self::get(&format!("https://www.steamgriddb.com/api/v2/grids/game/{id}?dimensions=600x900,342x482&types=static&nsfw=false&limit={limit}"), key)
            .and_then(|v| v["data"].as_array().cloned()).unwrap_or_default().iter().filter_map(|g| g["url"].as_str().map(String::from)).collect()
    }
    pub fn cover(&self, title: &str, key: &str) -> Option<String> {
        let key = key.trim();
        if key.is_empty() { return None; }
        let n = catalog::normalize(title);
        let cached = self.ids.lock().unwrap().get(&n).copied();
        let id = match cached { Some(i) => i, None => {
            let games = Self::search(title, key);
            // Le titre exact d'abord : l'autocomplétion rend volontiers les suites avant.
            let id = games.iter().find(|g| catalog::normalize(&g.1) == n).or(games.first()).map(|g| g.0);
            self.ids.lock().unwrap().insert(n, id);
            id
        } };
        Self::grids(id?, key, 1).into_iter().next()
    }
    pub fn candidates(title: &str, key: &str) -> Vec<(String, String)> {
        let mut out = vec![];
        for (i, (id, name)) in Self::search(title, key.trim()).into_iter().take(5).enumerate() {
            for u in Self::grids(id, key.trim(), if i == 0 { 6 } else { 2 }) { out.push((name.clone(), u)); if out.len() >= 12 { return out; } }
        }
        out
    }
    pub fn validate(key: &str) -> bool { Self::get("https://www.steamgriddb.com/api/v2/search/autocomplete/zelda", key.trim()).is_some() }
}

/// Une recherche : libretro d'abord, SteamGridDB en repli.
pub fn lookup(lib: &Libretro, sgdb: &SteamGridDb, item: &Item, search: Option<&str>, region: &str, key: &str) -> Option<String> {
    if let Some(s) = item.sys().filter(|s| s.libretro.is_some() && item.kind == Kind::Rom) {
        if let Some(u) = lib.matched(search.unwrap_or(&item.raw_name), s, region) { return Some(u); }
        // Un dump au nom inhabituel passe encore sur son titre.
        if search.is_none() && item.title != item.raw_name { if let Some(u) = lib.matched(&item.title, s, region) { return Some(u); } }
    }
    sgdb.cover(search.unwrap_or(&item.title), key)
}

pub fn candidates(lib: &Libretro, item: &Item, search: Option<&str>, region: &str, key: &str) -> Vec<Candidate> {
    let mut out = vec![];
    let mut seen = HashSet::new();
    if let Some(s) = item.sys().filter(|s| s.libretro.is_some()) {
        for (f, n) in lib.ranked(search.unwrap_or(&item.raw_name), s, region, 0.24, 14) {
            let u = Libretro::url(&f, &n);
            if seen.insert(u.clone()) { out.push(Candidate { title: n.trim_end_matches(".png").into(), source: "libretro", url: u }); }
        }
    }
    if !key.trim().is_empty() {
        for (name, u) in SteamGridDb::candidates(search.unwrap_or(&item.title), key) {
            if seen.insert(u.clone()) { out.push(Candidate { title: name, source: "SteamGridDB", url: u }); }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn encoding() {
        assert_eq!(enc("Nintendo - Super Nintendo Entertainment System"), "Nintendo%20-%20Super%20Nintendo%20Entertainment%20System");
        assert_eq!(dec("Zelda%20(Europe).png").as_deref(), Some("Zelda (Europe).png"));
        assert_eq!(enc("A&B"), "A%26B");
    }
    #[test]
    fn ranking() {
        let dir = std::env::temp_dir().join(format!("bj-art-{}", std::process::id()));
        let lib = Libretro::new(dir.clone());
        let names: Vec<String> = ["Super Mario World (USA).png", "Super Mario World (Europe) (Rev 1).png", "Super Mario World (Europe) (Beta).png", "Super Mario Kart (Europe).png"].iter().map(|s| s.to_string()).collect();
        lib.indexes.lock().unwrap().insert("Nintendo - Super Nintendo Entertainment System".into(), Arc::new(Libretro::entries(&names)));
        let snes = catalog::system("snes").unwrap();
        if snes.libretro == Some("Nintendo - Super Nintendo Entertainment System") {
            let u = lib.matched("Super Mario World (Europe)", snes, "Europe").unwrap();
            assert!(u.ends_with("Super%20Mario%20World%20(Europe)%20(Rev%201).png"), "{u}");
        }
        let _ = std::fs::remove_dir_all(dir);
    }
}
