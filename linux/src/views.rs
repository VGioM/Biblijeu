//! L'interface de Biblijeu : barre latérale, grille de jaquettes, panneau
//! d'informations, vue des mises à jour, vue des sauvegardes, réglages. Les clics
//! deviennent des actions, appliquées une fois l'image dessinée.

use crate::app::{App, Correction, PickFor, Tab};
use crate::backup;
use crate::catalog::{self, Item, Kind};
use crate::common::images::{Size, Source};
use crate::common::selfupdate::SelfUpdate;
use crate::common::{icons, sys, theme, ui};
use crate::emulators::{How, Plan};
use egui::{Align, Align2, Color32, Layout, Rect, RichText, Sense, Stroke, Ui, Vec2};
use std::collections::HashMap;
use std::path::PathBuf;

pub enum Patch { Emulator(Option<String>), Proton(Option<String>), Slot(Option<u32>), Kind(Option<Kind>), System(Option<String>), Fav, Hide, ForgetState }

pub enum Act {
    Sel(String),
    Select(Option<String>),
    Play { id: String, emu: Option<String>, disc: Option<PathBuf>, from_start: bool },
    Patch(String, Patch),
    Reveal(PathBuf),
    OpenPath(PathBuf),
    OpenUrl(String),
    Copy(String),
    Refetch(String),
    Correct(String),
    Pick(PickFor),
    Rescan,
    FetchArt,
    Settings(Tab),
    CheckUpdates,
    UpdateEmu(String),
    UpdateAll,
    InstallEmu(String),
    RunBackup(bool, Option<String>),
    AskRestore(Option<String>, String),
    CancelBackup,
    RemoveFrom(&'static str, String),
    Setting(&'static str, serde_json::Value),
}

fn pl(n: usize) -> &'static str { if n > 1 { "s" } else { "" } }

/// Les jeux visibles dans la section choisie, triés.
pub fn visible(app: &App) -> Vec<usize> {
    let sel = app.sel();
    let q = app.search.trim().to_lowercase();
    let mut v: Vec<usize> = app.items.iter().enumerate().filter(|(_, it)| {
        let st = app.states.get(&it.id);
        !st.map(|s| s.hidden).unwrap_or(false) && catalog::in_section(it, &sel, &st.cloned().unwrap_or_default(), app.playable(it)) && (q.is_empty() || it.haystack().contains(&q))
    }).map(|(i, _)| i).collect();
    catalog::sort_items(&mut v, &app.items, &app.states, &sel, &app.settings.string("sortOrder"));
    v
}

fn counts(app: &App) -> HashMap<String, usize> {
    let mut c: HashMap<String, usize> = HashMap::new();
    let roots = app.settings.strings("romFolders");
    let default = catalog::GameState::default();
    for it in &app.items {
        let st = app.states.get(&it.id).unwrap_or(&default);
        if st.hidden { continue; }
        let playable = app.playable(it);
        for (id, _, _) in catalog::SECTIONS { if catalog::in_section(it, id, st, playable) { *c.entry(id.to_string()).or_default() += 1; } }
        if matches!(it.kind, Kind::Rom | Kind::Game) && !it.system.is_empty() { *c.entry(format!("system:{}", it.system)).or_default() += 1; }
        for r in &roots { if catalog::in_section(it, &format!("source:{r}"), st, playable) { *c.entry(format!("source:{r}")).or_default() += 1; } }
    }
    c
}

pub fn show(app: &mut App, ctx: &egui::Context) {
    let p = app.p;
    let mut acts = vec![];
    let modal_open = app.settings_tab.is_some() || app.correction.is_some() || app.confirm_restore.is_some() || app.error.is_some() || app.info.is_some();
    ctx.input(|i| {
        if i.modifiers.command && i.key_pressed(egui::Key::F) { app.focus_search = true; }
        if i.modifiers.command && i.key_pressed(egui::Key::R) { acts.push(Act::Rescan); }
        if i.modifiers.command && i.key_pressed(egui::Key::Comma) { acts.push(Act::Settings(Tab::Sources)); }
        if i.modifiers.command && i.key_pressed(egui::Key::I) { acts.push(Act::Setting("showInspector", (!app.settings.bool("showInspector")).into())); }
    });
    let typing = ctx.wants_keyboard_input();
    if !modal_open && !typing {
        ctx.input(|i| {
            if let Some(id) = &app.selected {
                if i.key_pressed(egui::Key::Enter) { acts.push(Act::Play { id: id.clone(), emu: None, disc: None, from_start: i.modifiers.shift }); }
                if i.key_pressed(egui::Key::Escape) { acts.push(Act::Select(None)); }
            }
        });
    }
    let sel = app.sel();
    let page = sel == "updates" || sel == "backups";
    let list = if page { vec![] } else { visible(app) };
    if app.selected.as_ref().map(|id| app.item(id).is_none()).unwrap_or(false) { app.selected = None; }

    egui::SidePanel::left("side").resizable(false).exact_width(228.0)
        .frame(egui::Frame::new().fill(p.sidebar).inner_margin(egui::Margin { left: 10, right: 10, top: 12, bottom: 10 }).stroke(Stroke::new(1.0_f32, p.hairline)))
        .show(ctx, |ui| sidebar(app, ui, &mut acts));
    egui::TopBottomPanel::top("tb").exact_height(54.0)
        .frame(egui::Frame::new().fill(p.toolbar).inner_margin(egui::Margin::symmetric(16, 8)).stroke(Stroke::new(1.0_f32, p.hairline)))
        .show(ctx, |ui| toolbar(app, ui, list.len(), &mut acts));
    let insp = app.selected.clone().filter(|_| app.settings.bool("showInspector") && !page).and_then(|id| app.item(&id).cloned());
    if let Some(it) = insp {
        egui::SidePanel::right("insp").resizable(false).exact_width(318.0)
            .frame(egui::Frame::new().fill(p.panel).inner_margin(egui::Margin::symmetric(16, 16)).stroke(Stroke::new(1.0_f32, p.hairline)))
            .show(ctx, |ui| egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| inspector(app, ui, &it, &mut acts)));
    }
    egui::CentralPanel::default().frame(egui::Frame::new().fill(p.content)).show(ctx, |ui| {
        if sel == "updates" { egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| page_frame(ui, |ui| updates(app, ui, &mut acts))); }
        else if sel == "backups" { egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| page_frame(ui, |ui| backups(app, ui, &mut acts))); }
        else if list.is_empty() { empty(app, ui, &mut acts); }
        else { grid(app, ui, &list, &mut acts); }
    });

    messages(app, ctx);
    settings_sheet(app, ctx, &mut acts);
    correction_sheet(app, ctx);
    if let Some((emu, name)) = app.confirm_restore.clone() {
        let mut go = false;
        let close = ui::sheet(ctx, "restore", 420.0, |ui| {
            ui.label(RichText::new(format!("Restaurer {name} ?")).font(theme::bold(15.0)));
            ui.label(RichText::new("Tout ce que contient le disque est remis en place, même plus ancien que ce qui est sur ce PC. Les fichiers de ce PC qui ne sont pas sur le disque ne sont pas touchés.").color(p.muted));
            ui.add_space(6.0);
            ui.horizontal(|ui| ui.with_layout(Layout::right_to_left(Align::Center), |ui| { if ui::primary(ui, &p, "Restaurer").clicked() { go = true; } ui.button("Annuler").clicked() }).inner).inner || go
        });
        if go { acts.push(Act::RunBackup(false, emu)); }
        if close || go { app.confirm_restore = None; }
    }

    for a in acts { apply(app, ctx, a); }
}

fn apply(app: &mut App, ctx: &egui::Context, a: Act) {
    match a {
        Act::Sel(s) => { app.selected = None; app.settings.set("lastSelection", &s); if s == "backups" { app.refresh_backups(ctx); } }
        Act::Select(id) => { if id.is_some() && !app.settings.bool("showInspector") { app.settings.set("showInspector", true); } app.selected = id; }
        Act::Play { id, emu, disc, from_start } => app.play(ctx, &id, emu.as_deref(), disc, from_start),
        Act::Patch(id, p) => {
            let reapply = matches!(p, Patch::Kind(_) | Patch::System(_));
            app.update_state(&id, |s| match p {
                Patch::Emulator(e) => s.emulator_id = e,
                Patch::Proton(v) => s.proton_version = v,
                Patch::Slot(n) => { s.resume_slot = n; if n.is_some() { s.state_file_path = None; } }
                Patch::Kind(k) => s.kind_override = k,
                Patch::System(v) => s.system_override = v,
                Patch::Fav => s.favorite = !s.favorite,
                Patch::Hide => s.hidden = !s.hidden,
                Patch::ForgetState => s.state_file_path = None,
            });
            if reapply { app.apply_overrides(); }
        }
        Act::Reveal(p) => sys::reveal(&p),
        Act::OpenPath(p) => { let _ = std::fs::create_dir_all(&p); sys::open_path(&p); }
        Act::OpenUrl(u) => if u.starts_with("https://") { sys::open_url(&u) },
        Act::Copy(t) => { sys::copy_text(&t); app.toast.show("Copié."); }
        Act::Refetch(id) => app.refetch(ctx, &id, None),
        Act::Correct(id) => {
            let q = app.st(&id).search_title.or_else(|| app.item(&id).map(|i| i.title.clone())).unwrap_or_default();
            app.correction = Some(Correction { id, query: q, results: None });
            app.search_candidates(ctx);
        }
        Act::Pick(w) => app.pick(w),
        Act::Rescan => app.rescan(ctx),
        Act::FetchArt => app.fetch_artwork(ctx, true),
        Act::Settings(t) => { app.settings_tab = Some(t); app.key_status = None; }
        Act::CheckUpdates => app.check_updates(ctx, true),
        Act::UpdateEmu(id) => app.queue_emulator(ctx, &id, false),
        Act::UpdateAll => {
            let ids: Vec<String> = app.emulators.iter().filter(|e| e.how == How::Flatpak && e.target.as_ref().map(|t| app.flatpak_updates.contains_key(t)).unwrap_or(false)).map(|e| e.id().to_string()).collect();
            for id in ids { app.queue_emulator(ctx, &id, false); }
        }
        Act::InstallEmu(id) => app.queue_emulator(ctx, &id, true),
        Act::RunBackup(to, emu) => app.run_backup(ctx, to, emu),
        Act::AskRestore(emu, name) => app.confirm_restore = Some((emu, name)),
        Act::CancelBackup => app.cancel_backup(),
        Act::RemoveFrom(k, p) => app.remove_from(ctx, k, &p),
        Act::Setting(k, v) => app.set_setting(ctx, k, v),
    }
}

fn page_frame(ui: &mut Ui, body: impl FnOnce(&mut Ui)) {
    let w = ui.available_width().min(900.0);
    let pad = ((ui.available_width() - w) / 2.0).max(0.0);
    ui.horizontal(|ui| {
        ui.add_space(pad + 26.0);
        ui.vertical(|ui| { ui.set_width(w - 52.0); ui.add_space(22.0); ui.spacing_mut().item_spacing.y = 12.0; body(ui); ui.add_space(40.0); });
    });
}

// ── Barre latérale ────────────────────────────────────────────────────────

fn sidebar(app: &mut App, ui: &mut Ui, acts: &mut Vec<Act>) {
    let p = app.p;
    let sel = app.sel();
    ui.horizontal(|ui| {
        ui.add(egui::Image::from_bytes("bytes://biblijeu-icon.png", include_bytes!("../resources/icon.png").as_slice()).fit_to_exact_size(Vec2::splat(26.0)));
        ui.label(RichText::new("Biblijeu").font(theme::bold(16.0)));
    });
    let c = counts(app);
    let outdated = app.emulators.iter().filter(|e| e.how == How::Flatpak && e.target.as_ref().map(|t| app.flatpak_updates.contains_key(t)).unwrap_or(false)).count();
    let roots = app.settings.strings("romFolders");
    egui::ScrollArea::vertical().auto_shrink(false).max_height(ui.available_height() - 64.0).show(ui, |ui| {
        ui::section_title(ui, &p, "Bibliothèque");
        for (id, title, icon) in catalog::SECTIONS {
            let n = c.get(*id).copied().unwrap_or(0);
            let r = match *id {
                "updates" => ui::side_row(ui, &p, icon, title, (outdated > 0).then(|| outdated.to_string()), Some(p.warm), sel == *id),
                "backups" => {
                    let warn = app.settings.bool("autoBackup") && !app.settings.string("backupDestination").is_empty() && !app.destination_available();
                    let r = ui::side_row(ui, &p, icon, title, warn.then(|| "!".to_string()), Some(p.warm), sel == *id);
                    if warn { r.on_hover_text("Disque de sauvegarde absent — rien n'est copié pour l'instant.") } else { r }
                }
                "all" => ui::side_row(ui, &p, icon, title, (n > 0).then(|| n.to_string()), None, sel == *id),
                _ if n == 0 => continue,
                _ => ui::side_row(ui, &p, icon, title, Some(n.to_string()), None, sel == *id),
            };
            if r.clicked() { acts.push(Act::Sel(id.to_string())); }
        }
        let mut systems: Vec<&catalog::System> = catalog::SYSTEMS.iter().filter(|s| c.contains_key(&format!("system:{}", s.id))).collect();
        systems.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        if !systems.is_empty() {
            ui::section_title(ui, &p, "Consoles");
            for s in systems {
                let k = format!("system:{}", s.id);
                if ui::side_row(ui, &p, s.icon, s.name, c.get(&k).map(|n| n.to_string()), None, sel == k).clicked() { acts.push(Act::Sel(k)); }
            }
        }
        if roots.len() > 1 {
            ui::section_title(ui, &p, "Dossiers");
            for r in &roots {
                let k = format!("source:{r}");
                let name = r.rsplit('/').next().unwrap_or(r);
                let resp = ui::side_row(ui, &p, "folder", name, c.get(&k).map(|n| n.to_string()), None, sel == k).on_hover_text(r);
                if resp.clicked() { acts.push(Act::Sel(k.clone())); }
                resp.context_menu(|ui| {
                    if ui.button("Ouvrir le dossier").clicked() { acts.push(Act::OpenPath(r.into())); ui.close_menu(); }
                    if ui.button("Retirer ce dossier").clicked() { acts.push(Act::RemoveFrom("romFolders", r.clone())); ui.close_menu(); }
                });
            }
        }
    });
    ui.with_layout(Layout::bottom_up(Align::LEFT), |ui| {
        if ui.add(egui::Button::image_and_text(icons::image("gear", 14.0, p.muted), RichText::new("Réglages…").color(p.muted)).frame(false)).clicked() { acts.push(Act::Settings(Tab::Sources)); }
        let label = if roots.is_empty() { "Ajouter un dossier de ROM…" } else { "Ajouter un dossier…" };
        if ui.add(egui::Button::image_and_text(icons::image("folderPlus", 14.0, p.muted), RichText::new(label).color(p.muted)).frame(false)).clicked() { acts.push(Act::Pick(PickFor::RomFolder)); }
    });
}

// ── Barre d'outils ────────────────────────────────────────────────────────

fn toolbar(app: &mut App, ui: &mut Ui, count: usize, acts: &mut Vec<Act>) {
    let p = app.p;
    let sel = app.sel();
    let art = *app.art_progress.lock().unwrap();
    let sub = if app.scanning { app.scan_progress.lock().unwrap().clone() }
        else if let Some((d, t)) = art { format!("Recherche des jaquettes… {} %", d * 100 / t.max(1)) }
        else if sel == "updates" { let n = app.emulators.len(); format!("{n} émulateur{} installé{}", pl(n), pl(n)) }
        else if sel == "backups" { let pr = app.backup_progress.lock().unwrap().clone(); if !pr.is_empty() { pr } else { let n = app.backup.groups.len(); if n > 0 { format!("{n} source{} de sauvegardes", pl(n)) } else { String::new() } } }
        else if count > 0 { format!("{count} élément{}", pl(count)) } else { String::new() };
    ui.horizontal_centered(|ui| {
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 0.0;
            ui.label(RichText::new(catalog::section_title(&sel)).font(theme::bold(15.0)));
            ui.add(egui::Label::new(RichText::new(sub).size(11.5).color(p.muted)).truncate());
        });
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            let insp = app.settings.bool("showInspector");
            if ui.add(egui::Button::image(icons::image("sidebar", 17.0, if insp { p.text } else { p.muted })).frame(false).min_size(Vec2::splat(28.0))).on_hover_text("Panneau d'informations (Ctrl+I)").clicked() {
                acts.push(Act::Setting("showInspector", (!insp).into()));
            }
            let sort = app.settings.string("sortOrder");
            ui.menu_image_button(icons::image("more", 17.0, p.text), |ui| {
                for (id, label) in catalog::SORTS {
                    if ui.radio(sort == *id, format!("Trier par {}", label.to_lowercase())).clicked() { acts.push(Act::Setting("sortOrder", id.to_string().into())); ui.close_menu(); }
                }
                ui.separator();
                if ui.button("Analyser à nouveau").clicked() { acts.push(Act::Rescan); ui.close_menu(); }
                if ui.add_enabled(!app.items.is_empty(), egui::Button::new("Rechercher les jaquettes manquantes")).clicked() { acts.push(Act::FetchArt); ui.close_menu(); }
                ui.separator();
                if ui.button("Ajouter un dossier de ROM…").clicked() { acts.push(Act::Pick(PickFor::RomFolder)); ui.close_menu(); }
                if ui.button("Ajouter une application…").clicked() { acts.push(Act::Pick(PickFor::Application)); ui.close_menu(); }
                ui.separator();
                if ui.button("Réglages…").clicked() { acts.push(Act::Settings(Tab::Sources)); ui.close_menu(); }
                if ui.button(crate::common::selfupdate::MENU_TITLE).clicked() { app.update.check_now(ui.ctx()); ui.close_menu(); }
            });
            let sel_item = app.selected.as_ref().and_then(|id| app.item(id)).cloned();
            let can = sel_item.as_ref().map(|it| app.playable(it)).unwrap_or(false);
            if ui.add_enabled(can, egui::Button::image(icons::image("playCircle", 19.0, if can { p.accent } else { p.tertiary })).frame(false).min_size(Vec2::splat(28.0))).on_hover_text("Jouer (Entrée)").clicked() {
                if let Some(it) = sel_item { acts.push(Act::Play { id: it.id, emu: None, disc: None, from_start: false }); }
            }
            let focus = std::mem::take(&mut app.focus_search);
            let before = app.search.clone();
            ui::search_field(ui, &p, &mut app.search, "Titre, console, région…", 230.0, focus);
            if app.search != before && (sel == "updates" || sel == "backups") { acts.push(Act::Sel("all".into())); }
            if app.scanning || art.is_some() { ui::spinner(ui, 16.0); }
        });
    });
}

fn empty(app: &App, ui: &mut Ui, acts: &mut Vec<Act>) {
    let p = app.p;
    ui.vertical_centered(|ui| {
        ui.add_space((ui.available_height() / 2.0 - 110.0).max(30.0));
        if app.scanning && app.items.is_empty() {
            ui::spinner(ui, 28.0);
            ui.label(RichText::new(app.scan_progress.lock().unwrap().clone()).color(p.muted));
            return;
        }
        let (icon, title, msg, action) = if app.settings.strings("romFolders").is_empty() && app.items.is_empty() {
            ("gamepad", "Aucun jeu pour l'instant", "Ajoutez le dossier qui contient vos ROM : Biblijeu reconnaît les consoles, retrouve les jaquettes et lance chaque jeu avec le bon émulateur. Vos jeux Steam apparaissent tout seuls.".to_string(), true)
        } else if !app.search.is_empty() { ("search", "Aucun résultat", format!("Rien ne correspond à « {} ».", app.search), false) }
        else { ("gamepad", "Rien à afficher ici", "Aucun jeu ne correspond à cette catégorie.".into(), false) };
        ui.add(icons::image(icon, 46.0, p.tertiary));
        ui.add_space(6.0);
        ui.label(RichText::new(title).font(theme::bold(17.0)));
        ui.add(egui::Label::new(RichText::new(msg).color(p.muted)).wrap());
        if action { ui.add_space(8.0); if ui::primary_icon(ui, &p, "folderPlus", "Ajouter un dossier de ROM…", true).clicked() { acts.push(Act::Pick(PickFor::RomFolder)); } }
    });
}

// ── Grille ────────────────────────────────────────────────────────────────

fn badge_for(it: &Item) -> String {
    if it.kind == Kind::Rom { if let Some(s) = it.sys() { return s.short.into(); } }
    if it.steam_id.is_some() { "Steam".into() } else if it.system == "windows" { "Windows".into() } else if it.system == "linux" && it.kind == Kind::Game { "Linux".into() } else { it.kind.label().into() }
}

fn item_menu(app: &App, ui: &mut Ui, it: &Item, acts: &mut Vec<Act>) {
    let st = app.st(&it.id);
    let playable = app.playable(it);
    let id = it.id.clone();
    let mut b = |ui: &mut Ui, enabled: bool, label: &str, a: Act| { if ui.add_enabled(enabled, egui::Button::new(label)).clicked() { acts.push(a); ui.close_menu(); } };
    b(ui, playable, "Jouer", Act::Play { id: id.clone(), emu: None, disc: None, from_start: false });
    if it.kind == Kind::Rom {
        b(ui, playable, "Jouer depuis le début", Act::Play { id: id.clone(), emu: None, disc: None, from_start: true });
        let current = app.emulator_for(it).map(|e| e.id());
        for e in app.alternatives(it) { if Some(e.id()) != current { b(ui, true, &format!("Jouer avec {}", e.name()), Act::Play { id: id.clone(), emu: Some(e.id().into()), disc: None, from_start: false }); } }
    }
    if it.discs.len() > 1 { for (i, d) in it.discs.iter().enumerate() { b(ui, true, &format!("Démarrer le disque {}", i + 1), Act::Play { id: id.clone(), emu: None, disc: Some(d.clone()), from_start: false }); } }
    ui.separator();
    b(ui, true, if st.favorite { "Retirer des favoris" } else { "Ajouter aux favoris" }, Act::Patch(id.clone(), Patch::Fav));
    b(ui, true, "Afficher dans le dossier", Act::Reveal(it.path.clone()));
    b(ui, true, "Copier le chemin", Act::Copy(it.path.to_string_lossy().into()));
    ui.separator();
    b(ui, true, "Rechercher la jaquette", Act::Refetch(id.clone()));
    b(ui, true, "Corriger la jaquette…", Act::Correct(id.clone()));
    b(ui, true, "Choisir une image…", Act::Pick(PickFor::Artwork(id.clone())));
    ui.separator();
    b(ui, true, if st.hidden { "Afficher dans la bibliothèque" } else { "Masquer de la bibliothèque" }, Act::Patch(id, Patch::Hide));
}

fn draw_cover(app: &mut App, ui: &Ui, rect: Rect, it: &Item, radius: u8, size: Size) {
    let (src, icon) = app.cover_source(it);
    if icon {
        // Une icône d'application n'a pas de fond flou : elle est centrée sur le dégradé.
        ui::placeholder(ui, rect, radius, &it.sort_title, "");
        let pad = rect.width() * 0.22;
        let inner = rect.shrink(pad);
        let inner = Rect::from_center_size(rect.center(), Vec2::splat(inner.width().min(inner.height())));
        if let Some((t, sz)) = src.as_ref().and_then(|s| app.images.get(s, Size::Thumb)) { ui::paint_texture(ui, inner, &t, sz, 0, ui::Fit::Contain); }
        else { icons::image(it.icon(), 26.0, Color32::from_white_alpha(115)).paint_at(ui, Rect::from_center_size(rect.center(), Vec2::splat(26.0))); }
        ui.painter().rect_stroke(rect, radius, Stroke::new(0.5_f32, Color32::from_white_alpha(23)), egui::StrokeKind::Inside);
    } else {
        ui::cover(ui, &mut app.images, rect, src.as_ref(), &it.sort_title, it.icon(), radius, size, true);
    }
}

fn grid(app: &mut App, ui: &mut Ui, list: &[usize], acts: &mut Vec<Act>) {
    let p = app.p;
    let (pad, gap) = (22.0, 18.0);
    let min = (app.settings.f64("cardSize") as f32).clamp(120.0, 260.0);
    let width = ui.available_width() - 2.0 * pad;
    let cols = ((width + gap) / (min + gap)).floor().max(1.0) as usize;
    let cw = (width - gap * (cols as f32 - 1.0)) / cols as f32;
    let ch = cw * 4.0 / 3.0;
    let row_h = ch + 50.0;
    let mut hit = false;
    let scroll = egui::ScrollArea::vertical().auto_shrink(false).show_rows(ui, row_h, list.len().div_ceil(cols), |ui, range| {
        ui.add_space(20.0);
        for r in range {
            let (row, _) = ui.allocate_exact_size(Vec2::new(ui.available_width(), row_h), Sense::hover());
            for c in 0..cols {
                let Some(&i) = list.get(r * cols + c) else { break };
                let it = app.items[i].clone();
                let x = row.left() + pad + c as f32 * (cw + gap);
                let cover = Rect::from_min_size(egui::pos2(x, row.top()), Vec2::new(cw, ch));
                let card = Rect::from_min_size(cover.min, Vec2::new(cw, ch + 44.0));
                let resp = ui.interact(card, ui.id().with(("card", &it.id)), Sense::click());
                let selected = app.selected.as_deref() == Some(it.id.as_str());
                let hovered = resp.hovered();
                ui::shadow(ui, cover, 9, selected);
                draw_cover(app, ui, cover, &it, 9, Size::Thumb);
                let playable = app.playable(&it);
                let b = ui::badge(ui, cover.left_bottom() + Vec2::new(6.0, -6.0), Align2::LEFT_BOTTOM, &badge_for(&it));
                if it.discs.len() > 1 { ui::badge(ui, cover.right_bottom() + Vec2::new(-6.0, -6.0), Align2::RIGHT_BOTTOM, &format!("{} disques", it.discs.len())); }
                let _ = b;
                if !playable { icons::image("warning", 15.0, p.warm).paint_at(ui, Rect::from_min_size(cover.right_top() + Vec2::new(-22.0, 7.0), Vec2::splat(15.0))); }
                if hovered {
                    ui.painter().rect_filled(cover, 9, Color32::from_black_alpha(70));
                    let cy = cover.center().y;
                    if playable && ui::circle_button(ui, egui::pos2(cover.center().x - 26.0, cy), "play", ui.id().with(("play", &it.id))).clicked() {
                        acts.push(Act::Play { id: it.id.clone(), emu: None, disc: None, from_start: false }); hit = true;
                    }
                    let ix = if playable { cover.center().x + 26.0 } else { cover.center().x };
                    if ui::circle_button(ui, egui::pos2(ix, cy), "info", ui.id().with(("info", &it.id))).clicked() { acts.push(Act::Select(Some(it.id.clone()))); hit = true; }
                }
                ui.painter().rect_stroke(cover, 9, if selected { Stroke::new(2.5_f32, p.accent) } else { Stroke::NONE }, egui::StrokeKind::Outside);
                let tw = cw;
                ui::text_in(ui, Rect::from_min_size(egui::pos2(x, cover.bottom() + 7.0), Vec2::new(tw, 17.0)), &it.title, theme::bold(12.5), p.text);
                let mut subtitle = it.subtitle();
                if app.st(&it.id).favorite { subtitle = format!("♥ {subtitle}"); }
                ui::text_in(ui, Rect::from_min_size(egui::pos2(x, cover.bottom() + 25.0), Vec2::new(tw, 15.0)), &subtitle, theme::regular(11.0), p.muted);
                if !hit {
                    if resp.double_clicked() { if playable { acts.push(Act::Play { id: it.id.clone(), emu: None, disc: None, from_start: false }); } hit = true; }
                    else if resp.clicked() { acts.push(Act::Select(Some(it.id.clone()))); hit = true; }
                }
                resp.context_menu(|ui| item_menu(app, ui, &it, acts));
                if resp.secondary_clicked() { hit = true; }
            }
        }
        ui.add_space(30.0);
    });
    // Cliquer entre les jeux ferme le panneau.
    let bg = ui.interact(scroll.inner_rect, ui.id().with("bg"), Sense::click());
    if bg.clicked() && !hit { acts.push(Act::Select(None)); }
}

// ── Panneau d'informations ────────────────────────────────────────────────

fn section(ui: &mut Ui, p: &theme::Palette, title: &str, body: impl FnOnce(&mut Ui)) {
    ui.add_space(10.0);
    ui.label(RichText::new(title.to_uppercase()).size(10.5).strong().color(p.tertiary));
    ui.spacing_mut().item_spacing.y = 6.0;
    body(ui);
}

fn notice(ui: &mut Ui, p: &theme::Palette, text: &str) {
    egui::Frame::new().fill(Color32::from_white_alpha(10)).corner_radius(8).inner_margin(8).show(ui, |ui| {
        ui.horizontal_top(|ui| { ui.add(icons::image("warning", 15.0, p.warm)); ui.add(egui::Label::new(RichText::new(text).size(12.0)).wrap()); });
    });
}

fn small(ui: &mut Ui, p: &theme::Palette, text: &str) { ui.add(egui::Label::new(RichText::new(text).size(11.5).color(p.muted)).wrap()); }

fn inspector(app: &mut App, ui: &mut Ui, it: &Item, acts: &mut Vec<Act>) {
    let p = app.p;
    let st = app.st(&it.id);
    let w = ui.available_width();
    let cover = Rect::from_min_size(ui.cursor().min, Vec2::new(w, w * 4.0 / 3.0));
    ui.allocate_rect(cover, Sense::hover());
    ui::shadow(ui, cover, 12, true);
    draw_cover(app, ui, cover, it, 12, Size::Large);
    ui.add_space(10.0);
    ui.add(egui::Label::new(RichText::new(&it.title).font(theme::bold(18.0))).wrap().selectable(true));
    small(ui, &p, &it.subtitle());
    if !it.languages.is_empty() { ui.label(RichText::new(it.languages.join(" · ")).size(11.5).color(p.tertiary)); }
    if let Some(t) = st.last_played { ui.label(RichText::new(format!("Joué {} · {} fois", sys::relative(t), st.play_count)).size(11.5).color(p.tertiary)); }
    ui.add_space(6.0);

    let (plan, resume) = app.selected_plan().unwrap_or((Plan::Error(String::new()), catalog::ResumeReq::FromStart));
    let resumes = resume != catalog::ResumeReq::FromStart;
    let emu = app.emulator_for(it).cloned();
    let playable = app.playable(it);
    let primary = if it.kind != Kind::Rom && it.system != "windows" { if it.kind == Kind::Emulator { "Ouvrir" } else { "Jouer" } } else if resumes { "Reprendre" } else { "Jouer" };
    ui.horizontal(|ui| {
        let bw = ui.available_width() - if resumes { 88.0 } else { 44.0 };
        let b = egui::Button::image_and_text(icons::image(if resumes { "playCircle" } else { "play" }, 14.0, p.on_accent), RichText::new(primary).color(p.on_accent).strong())
            .fill(p.accent).min_size(Vec2::new(bw, 34.0));
        if ui.add_enabled(playable, b).clicked() { acts.push(Act::Play { id: it.id.clone(), emu: None, disc: None, from_start: false }); }
        if resumes && ui.add(egui::Button::image(icons::image("restart", 14.0, p.text)).min_size(Vec2::splat(34.0))).on_hover_text("Démarrer depuis le début, sans charger de sauvegarde").clicked() {
            acts.push(Act::Play { id: it.id.clone(), emu: None, disc: None, from_start: true });
        }
        if ui.add(egui::Button::image(icons::image(if st.favorite { "heartFill" } else { "heart" }, 15.0, if st.favorite { p.accent } else { p.text })).min_size(Vec2::splat(34.0))).on_hover_text("Favori").clicked() {
            acts.push(Act::Patch(it.id.clone(), Patch::Fav));
        }
    });

    if it.discs.len() > 1 {
        section(ui, &p, "Disques", |ui| {
            for (i, d) in it.discs.iter().enumerate() {
                ui.horizontal(|ui| {
                    ui.add(egui::Label::new(RichText::new(format!("Disque {} — {}", i + 1, d.file_name().unwrap_or_default().to_string_lossy())).size(12.0)).truncate());
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| { if ui.add(egui::Button::image(icons::image("play", 11.0, p.text))).clicked() { acts.push(Act::Play { id: it.id.clone(), emu: None, disc: Some(d.clone()), from_start: false }); } });
                });
            }
        });
    }

    if it.kind == Kind::Rom && it.system != "windows" {
        let alts: Vec<(String, String)> = app.alternatives(it).iter().map(|e| (e.id().to_string(), format!("{} — {}", e.name(), e.how_label()))).collect();
        section(ui, &p, "Émulateur", |ui| {
            if alts.is_empty() {
                let s = it.sys();
                let names: Vec<&str> = s.map(|s| s.emulators.iter().filter_map(|id| catalog::emulator(id).map(|e| e.name)).take(3).collect()).unwrap_or_default();
                notice(ui, &p, &format!("Aucun émulateur installé pour {}.{}", s.map(|s| s.name).unwrap_or("cette console"),
                    if names.is_empty() { String::new() } else { format!("\nInstallez {} — section « Mises à jour ».", names.join(", ")) }));
            } else {
                let cur = st.emulator_id.clone();
                let label = cur.as_ref().and_then(|c| alts.iter().find(|a| &a.0 == c)).map(|a| a.1.clone())
                    .unwrap_or_else(|| format!("Automatique{}", emu.as_ref().map(|e| format!(" ({})", e.name())).unwrap_or_default()));
                egui::ComboBox::from_id_salt("emu").width(ui.available_width()).selected_text(label).show_ui(ui, |ui| {
                    if ui.selectable_label(cur.is_none(), "Automatique").clicked() { acts.push(Act::Patch(it.id.clone(), Patch::Emulator(None))); }
                    for (id, l) in &alts { if ui.selectable_label(cur.as_deref() == Some(id), l).clicked() { acts.push(Act::Patch(it.id.clone(), Patch::Emulator(Some(id.clone())))); } }
                });
            }
        });
    }

    if it.system == "windows" && it.steam_id.is_none() {
        section(ui, &p, "Proton", |ui| {
            if app.protons.is_empty() { notice(ui, &p, "Aucun Proton trouvé. Installez « Proton Experimental » depuis Steam (Bibliothèque → Outils), ou GE-Proton avec ProtonPlus."); return; }
            let general = { let g = app.settings.string("protonVersion"); if g.is_empty() { app.protons[0].clone() } else { g } };
            let cur = st.proton_version.clone();
            egui::ComboBox::from_id_salt("proton").width(ui.available_width()).selected_text(cur.clone().unwrap_or(format!("Réglage général ({general})"))).show_ui(ui, |ui| {
                if ui.selectable_label(cur.is_none(), format!("Réglage général ({general})")).clicked() { acts.push(Act::Patch(it.id.clone(), Patch::Proton(None))); }
                for pr in &app.protons { if ui.selectable_label(cur.as_deref() == Some(pr), pr).clicked() { acts.push(Act::Patch(it.id.clone(), Patch::Proton(Some(pr.clone())))); } }
            });
            small(ui, &p, &format!("Lancé {} avec un préfixe propre à ce jeu.", if app.has_umu { "par umu-run, dans le conteneur Steam Linux Runtime," } else { "par Proton" }));
            if ui::button_icon(ui, &p, "folder", "Préfixe du jeu").clicked() { acts.push(Act::OpenPath(crate::emulators::prefix_for(it, &app.prefixes()))); }
        });
    }

    if it.steam_id.is_some() {
        section(ui, &p, "Steam", |ui| small(ui, &p, &format!("Lancé par Steam, avec {}.", if it.system == "windows" { "le Proton choisi pour ce jeu dans Steam" } else { "ses réglages" })));
    }

    if let (Kind::Rom, Some(e)) = (it.kind, emu.as_ref()) {
        if it.system != "windows" {
            section(ui, &p, "Sauvegarde d'état", |ui| {
                let r = &e.spec.resume;
                if !e.spec.resumes() { small(ui, &p, &format!("{} ne sait pas charger une sauvegarde d'état au démarrage. Le jeu démarrera depuis le début.", e.name())); return; }
                if r.slot.is_some() {
                    let none = if r.auto.is_some() { "Dernière sauvegarde" } else { "Emplacement 1" };
                    egui::ComboBox::from_id_salt("slot").width(ui.available_width()).selected_text(st.resume_slot.map(|n| format!("Emplacement {n}")).unwrap_or(none.into())).show_ui(ui, |ui| {
                        if ui.selectable_label(st.resume_slot.is_none(), none).clicked() { acts.push(Act::Patch(it.id.clone(), Patch::Slot(None))); }
                        for n in 1..=10 { if ui.selectable_label(st.resume_slot == Some(n), format!("Emplacement {n}")).clicked() { acts.push(Act::Patch(it.id.clone(), Patch::Slot(Some(n)))); } }
                    });
                } else if r.auto.is_some() { small(ui, &p, "Reprend la sauvegarde la plus récente de ce jeu."); }
                if r.file.is_some() {
                    if let Some(f) = &st.state_file_path { ui.horizontal(|ui| { ui.add(icons::image("doc", 13.0, p.muted)); ui.add(egui::Label::new(RichText::new(f.rsplit('/').next().unwrap_or(f)).size(11.5)).truncate()); }); }
                    ui.horizontal(|ui| {
                        if ui.button(if st.state_file_path.is_some() { "Changer…" } else { "Fichier d'état…" }).clicked() { acts.push(Act::Pick(PickFor::StateFile(it.id.clone()))); }
                        if st.state_file_path.is_some() && ui.button("Oublier").clicked() { acts.push(Act::Patch(it.id.clone(), Patch::ForgetState)); }
                    });
                }
                if !app.settings.bool("resumeOnLaunch") { small(ui, &p, "« Reprendre au lancement » est désactivé dans les réglages : le bouton Jouer démarre depuis le début."); }
            });
        }
    }

    section(ui, &p, "Fichier", |ui| {
        ui::info_row(ui, &p, "Chemin", &it.path.to_string_lossy());
        if it.size > 0 { ui::info_row(ui, &p, "Taille", &sys::bytes(it.size)); }
        if !it.tags.is_empty() { ui::info_row(ui, &p, "Étiquettes", &it.tags.join(", ")); }
        let preview = match &plan { Plan::Error(_) => None, p => Some(p.preview()) };
        if let Some(pv) = &preview {
            egui::Frame::new().fill(Color32::from_white_alpha(15)).corner_radius(6).inner_margin(7).show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.add(egui::Label::new(RichText::new(pv).monospace().size(10.5).color(p.muted)).wrap().selectable(true));
            });
        }
        if let Plan::Error(e) = &plan { if !e.is_empty() { small(ui, &p, e); } }
        ui.horizontal(|ui| {
            if ui::button_icon(ui, &p, "folder", "Dossier").clicked() { acts.push(Act::Reveal(it.path.clone())); }
            if let Some(pv) = preview { if ui::button_icon(ui, &p, "copy", "Commande").clicked() { acts.push(Act::Copy(pv)); } }
        });
    });

    section(ui, &p, "Jaquette", |ui| {
        ui.horizontal(|ui| {
            if ui.button("Rechercher").clicked() { acts.push(Act::Refetch(it.id.clone())); }
            if ui.button("Autre titre…").clicked() { acts.push(Act::Correct(it.id.clone())); }
            if ui.button("Image…").clicked() { acts.push(Act::Pick(PickFor::Artwork(it.id.clone()))); }
        });
        if let Some(t) = &st.search_title { small(ui, &p, &format!("Titre de recherche : {t}")); }
    });

    section(ui, &p, "Classement", |ui| {
        ui.horizontal(|ui| {
            ui.add_sized([64.0, 18.0], egui::Label::new(RichText::new("Type").color(p.muted)));
            egui::ComboBox::from_id_salt("kind").width(ui.available_width()).selected_text(st.kind_override.map(|k| k.label()).unwrap_or("Automatique")).show_ui(ui, |ui| {
                if ui.selectable_label(st.kind_override.is_none(), "Automatique").clicked() { acts.push(Act::Patch(it.id.clone(), Patch::Kind(None))); }
                for k in Kind::all() { if ui.selectable_label(st.kind_override == Some(k), k.label()).clicked() { acts.push(Act::Patch(it.id.clone(), Patch::Kind(Some(k)))); } }
            });
        });
        if matches!(it.kind, Kind::Rom | Kind::Game) {
            ui.horizontal(|ui| {
                ui.add_sized([64.0, 18.0], egui::Label::new(RichText::new("Console").color(p.muted)));
                let cur = st.system_override.clone();
                egui::ComboBox::from_id_salt("system").width(ui.available_width()).height(320.0)
                    .selected_text(cur.as_deref().and_then(catalog::system).map(|s| s.name).unwrap_or("Automatique")).show_ui(ui, |ui| {
                    if ui.selectable_label(cur.is_none(), "Automatique").clicked() { acts.push(Act::Patch(it.id.clone(), Patch::System(None))); }
                    for s in catalog::SYSTEMS { if ui.selectable_label(cur.as_deref() == Some(s.id), s.name).clicked() { acts.push(Act::Patch(it.id.clone(), Patch::System(Some(s.id.into())))); } }
                });
            });
        }
        if ui.link(RichText::new(if st.hidden { "Afficher dans la bibliothèque" } else { "Masquer de la bibliothèque" }).color(p.muted)).clicked() { acts.push(Act::Patch(it.id.clone(), Patch::Hide)); }
    });
}

// ── Mises à jour ──────────────────────────────────────────────────────────

fn list_frame(ui: &mut Ui, p: &theme::Palette, body: impl FnOnce(&mut Ui)) {
    egui::Frame::new().fill(Color32::from_white_alpha(8)).stroke(Stroke::new(1.0_f32, p.hairline)).corner_radius(10).inner_margin(egui::Margin::symmetric(12, 6)).show(ui, |ui| {
        ui.set_width(ui.available_width());
        body(ui);
    });
}

fn emu_icon(app: &mut App, ui: &mut Ui, id: &str) {
    let p = app.p;
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(30.0), Sense::hover());
    ui.painter().rect_filled(rect, 7, Color32::from_white_alpha(14));
    let icon = app.emu_icons.get(id).and_then(|d| d.1.clone());
    if let Some((t, sz)) = icon.and_then(|i| app.images.get(&Source::File(i), Size::Thumb)) { ui::paint_texture(ui, rect.shrink(3.0), &t, sz, 0, ui::Fit::Contain); }
    else { icons::image("cpu", 16.0, p.muted).paint_at(ui, Rect::from_center_size(rect.center(), Vec2::splat(16.0))); }
}

fn updates(app: &mut App, ui: &mut Ui, acts: &mut Vec<Act>) {
    let p = app.p;
    let activity = app.emu_activity.lock().unwrap().clone();
    let flat: Vec<_> = app.emulators.iter().filter(|e| e.how == How::Flatpak).cloned().collect();
    let fu = app.flatpak_updates.clone();
    let upd = move |e: &crate::emulators::Installed| e.target.as_ref().and_then(|t| fu.get(t)).cloned();
    let outdated: Vec<_> = flat.iter().filter(|e| upd(e).is_some()).cloned().collect();
    let up_to_date: Vec<_> = flat.iter().filter(|e| upd(e).is_none()).cloned().collect();
    let others: Vec<_> = app.emulators.iter().filter(|e| e.how != How::Flatpak).cloned().collect();
    ui::group(ui, &p, "", |ui| {
        ui.horizontal(|ui| {
            ui.add(icons::image(if outdated.is_empty() { "checkCircle" } else { "downCircle" }, 22.0, if outdated.is_empty() { p.ok } else { p.accent }));
            ui.vertical(|ui| {
                let n = outdated.len();
                ui.label(RichText::new(if n > 0 { format!("{n} mise{} à jour disponible{}", pl(n), pl(n)) } else if !flat.is_empty() { "Vos émulateurs Flatpak sont à jour".into() } else { "Aucun émulateur Flatpak".into() }).font(theme::bold(14.0)));
                let checked = app.updates_checked_at.map(|t| format!("Vérifié {}.", sys::relative(t))).unwrap_or("Pas encore vérifié.".into());
                ui.set_max_width(ui.available_width() - 260.0);
                small(ui, &p, &format!("{checked} Les émulateurs Flatpak sont vérifiés une fois par jour ; ceux en paquet se mettent à jour avec le système, les AppImage depuis la page du projet."));
            });
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if !outdated.is_empty() && ui::primary(ui, &p, "Tout mettre à jour").clicked() { acts.push(Act::UpdateAll); }
                if app.checking_updates { ui::spinner(ui, 16.0); } else if ui.add_enabled(app.has_flatpak, egui::Button::new("Vérifier maintenant")).clicked() { acts.push(Act::CheckUpdates); }
            });
        });
    });
    let mut auto = app.settings.bool("autoInstallUpdates");
    if ui::check_help(ui, &p, &mut auto, "Installer automatiquement les mises à jour", "Après la vérification du jour, pour les Flatpak installés pour l'utilisateur (ceux du système demandent un mot de passe).").changed() {
        acts.push(Act::Setting("autoInstallUpdates", auto.into()));
    }
    let line = |app: &mut App, ui: &mut Ui, e: &crate::emulators::Installed, acts: &mut Vec<Act>, extra: bool| {
        ui.horizontal(|ui| {
            emu_icon(app, ui, e.id());
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing.y = 1.0;
                ui.label(RichText::new(e.name()).strong());
                let id = e.id();
                let (text, color) = if let Some(a) = activity.get(id) { (a.clone(), p.muted) } else if let Some(pr) = app.emu_problems.get(id) { (pr.clone(), p.warm) }
                    else if let Some(n) = app.emu_notes.get(id) { (n.clone(), p.ok) } else {
                        let kind = match e.how { How::Flatpak => format!("Flatpak {}", if e.installation.as_deref() == Some("user") { "(utilisateur)" } else { "(système)" }), How::Native => "paquet".into(), How::AppImage => "AppImage".into(), How::Proton => "Steam".into() };
                        let mut parts = vec![kind];
                        if let Some(v) = &e.version { parts.push(if e.how == How::Proton { v.clone() } else { format!("version {v}") }); }
                        if let Some(u) = upd(e) { parts.push(format!("→ {u}")); }
                        (parts.join(" · "), p.muted)
                    };
                ui.label(RichText::new(text).size(11.5).color(color));
            });
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let url = e.spec.github.map(|g| format!("https://github.com/{g}/releases/latest")).or(e.spec.homepage.map(String::from));
                if let Some(u) = url { if ui::icon_button(ui, &p, "external", 14.0, "Page du projet").clicked() { acts.push(Act::OpenUrl(u)); } }
                if activity.contains_key(e.id()) { ui::spinner(ui, 14.0); }
                if extra {
                    if ui.add_enabled(!activity.contains_key(e.id()), egui::Button::new(RichText::new("Mettre à jour").color(p.on_accent)).fill(p.accent)).clicked() { acts.push(Act::UpdateEmu(e.id().into())); }
                    if let Some(u) = upd(e) { ui.label(RichText::new(u).size(11.5).color(p.warm)); }
                }
            });
        });
    };
    if !outdated.is_empty() { ui.label(RichText::new("À mettre à jour").font(theme::bold(15.0))); list_frame(ui, &p, |ui| for e in &outdated { line(app, ui, e, acts, true); }); }
    if !up_to_date.is_empty() { ui.label(RichText::new("À jour").font(theme::bold(15.0))); list_frame(ui, &p, |ui| for e in &up_to_date { line(app, ui, e, acts, false); }); }
    if !others.is_empty() { ui.label(RichText::new("Paquets, AppImage et Proton").font(theme::bold(15.0))); list_frame(ui, &p, |ui| for e in &others { line(app, ui, e, acts, false); }); }
    let missing = app.missing_emulators();
    if !missing.is_empty() {
        ui.label(RichText::new("Non installés").font(theme::bold(15.0)));
        list_frame(ui, &p, |ui| for m in &missing {
            ui.horizontal(|ui| {
                let (rect, _) = ui.allocate_exact_size(Vec2::splat(30.0), Sense::hover());
                ui.painter().rect_filled(rect, 7, Color32::from_white_alpha(14));
                icons::image("cpu", 16.0, p.muted).paint_at(ui, Rect::from_center_size(rect.center(), Vec2::splat(16.0)));
                ui.vertical(|ui| {
                    ui.spacing_mut().item_spacing.y = 1.0;
                    ui.label(RichText::new(m.name).strong());
                    let systems: Vec<&str> = m.systems.iter().take(6).filter_map(|s| catalog::system(s).map(|s| s.short)).collect();
                    let (t, c) = if let Some(a) = activity.get(m.id) { (a.clone(), p.muted) } else if let Some(pr) = app.emu_problems.get(m.id) { (pr.clone(), p.warm) }
                        else if let Some(n) = app.emu_notes.get(m.id) { (n.clone(), p.ok) } else { (format!("{} · {}", systems.join(", "), m.flatpak[0]), p.muted) };
                    ui.label(RichText::new(t).size(11.5).color(c));
                });
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if activity.contains_key(m.id) { ui::spinner(ui, 14.0); }
                    else if ui.add_enabled(app.has_flatpak, egui::Button::new("Installer")).on_hover_text(format!("flatpak install flathub {}", m.flatpak[0])).clicked() { acts.push(Act::InstallEmu(m.id.into())); }
                });
            });
        });
    }
}

// ── Sauvegarde ────────────────────────────────────────────────────────────

fn tilde(p: &str) -> String {
    let h = dirs::home_dir().unwrap_or_default().to_string_lossy().to_string();
    let p = p.strip_prefix("/var").filter(|_| !h.starts_with("/var")).unwrap_or(p);
    let h2 = h.strip_prefix("/var").unwrap_or(&h);
    p.strip_prefix(&h).or_else(|| p.strip_prefix(h2)).map(|r| format!("~{r}")).unwrap_or(p.to_string())
}

fn backups(app: &mut App, ui: &mut Ui, acts: &mut Vec<Act>) {
    let p = app.p;
    let dest = app.settings.string("backupDestination");
    let b = &app.backup;
    let ok = !dest.is_empty() && b.available;
    let kinds = app.settings.strings("backupKinds");
    let excluded = app.settings.strings("backupExcludedEmulators");
    let mut totals: HashMap<&str, (usize, u64)> = HashMap::new();
    for g in &b.groups { for f in &g.folders { let t = totals.entry(f.folder.kind).or_default(); t.0 += 1; t.1 += f.bytes; } }
    let last_run = app.settings.get("backupLastRun").as_i64();
    ui::group(ui, &p, "", |ui| {
        ui.horizontal(|ui| {
            ui.add(icons::image("drive", 22.0, p.accent));
            ui.vertical(|ui| {
                ui.set_max_width(ui.available_width() - 160.0);
                ui.add(egui::Label::new(RichText::new(if dest.is_empty() { "Aucun dossier de sauvegarde".to_string() } else { dest.clone() }).font(theme::bold(14.0))).truncate());
                small(ui, &p, &if dest.is_empty() { "Choisissez un dossier — un disque externe, par exemple. Les copies vont dans « Biblijeu Sauvegardes ».".to_string() }
                    else if b.available { last_run.map(|t| format!("Dernière vérification {}.", sys::relative(t))).unwrap_or("Jamais sauvegardé.".into()) }
                    else { "Disque absent : rien n'est copié pour l'instant.".into() });
            });
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if ok && ui::icon_button(ui, &p, "folder", 15.0, "Ouvrir").clicked() { if let Some(r) = app.backup_root() { acts.push(Act::OpenPath(r)); } }
                if ui.button(if dest.is_empty() { "Choisir…" } else { "Changer…" }).clicked() { acts.push(Act::Pick(PickFor::BackupDest)); }
            });
        });
    });
    ui.horizontal(|ui| {
        if b.running {
            ui::spinner(ui, 14.0);
            let pr = app.backup_progress.lock().unwrap().clone();
            ui.label(RichText::new(if pr.is_empty() { "Copie…".into() } else { pr }).color(p.muted));
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| if ui.button("Arrêter").clicked() { acts.push(Act::CancelBackup); });
        } else {
            if ui.add_enabled(ok, egui::Button::image_and_text(icons::image("drive", 14.0, p.on_accent), RichText::new("Sauvegarder maintenant").color(p.on_accent).strong()).fill(p.accent)).clicked() { acts.push(Act::RunBackup(true, None)); }
            if ui.add_enabled(ok, egui::Button::new("Tout restaurer…")).clicked() { acts.push(Act::AskRestore(None, "toutes les sauvegardes".into())); }
            if b.scanning { ui::spinner(ui, 14.0); }
        }
    });
    if let Some(m) = b.message.clone() { if ui.add(egui::Label::new(RichText::new(m).color(p.warm)).sense(Sense::click())).on_hover_text("Cliquer pour effacer").clicked() { app.backup.message = None; } }
    let b = &app.backup;
    if let Some(s) = &b.last_summary { small(ui, &p, s); }
    if !b.last_failures.is_empty() { notice(ui, &p, &b.last_failures.join("\n")); }

    let st = &app.settings;
    let setting_check = |ui: &mut Ui, acts: &mut Vec<Act>, key: &'static str, label: &str, help: &str| {
        let mut v = st.bool(key);
        if ui::check_help(ui, &p, &mut v, label, help).changed() { acts.push(Act::Setting(key, v.into())); }
    };
    ui::group(ui, &p, "Automatique", |ui| {
        setting_check(ui, acts, "autoBackup", "Sauvegarder automatiquement", "La partie la plus récente gagne, qu'elle soit sur ce PC ou sur le disque. Rien n'est jamais supprimé.");
        ui.indent("auto", |ui| {
            ui.horizontal(|ui| {
                setting_check(ui, acts, "backupOnInterval", "Toutes les", "");
                let mut m = st.f64("backupIntervalMinutes").clamp(1.0, 1440.0) as u32;
                if ui.add(egui::DragValue::new(&mut m).range(1..=1440)).changed() { acts.push(Act::Setting("backupIntervalMinutes", m.into())); }
                ui.label("minutes");
            });
            setting_check(ui, acts, "backupOnLaunch", "Au lancement de Biblijeu", "");
            setting_check(ui, acts, "backupOnQuit", "À la fermeture (20 s au plus)", "");
        });
    });
    ui::group(ui, &p, "Ce qui est copié", |ui| {
        for (k, label, help) in backup::KINDS {
            let mut on = kinds.iter().any(|x| x == k);
            let extra = totals.get(k).map(|t| format!(" · {} dossier{}, {}", t.0, pl(t.0), if t.1 > 0 { sys::bytes(t.1) } else { "0 o".into() })).unwrap_or_default();
            if ui::check_help(ui, &p, &mut on, &format!("{label}{extra}"), help).changed() {
                let mut v: Vec<String> = kinds.iter().filter(|x| x != k).cloned().collect();
                if on { v.push(k.to_string()); }
                acts.push(Act::Setting("backupKinds", v.into()));
            }
        }
        small(ui, &p, "Aucune ROM n'est jamais copiée : dans un dossier de ROM, seuls les fichiers de sauvegarde sont lus.");
    });
    let b = &app.backup;
    if b.groups.is_empty() { small(ui, &p, if b.scanning { "Recherche des dossiers de sauvegarde…" } else { "Aucun dossier de sauvegarde trouvé pour les émulateurs de ce PC." }); }
    for g in b.groups.clone() {
        list_frame(ui, &p, |ui| {
            ui.horizontal(|ui| {
                let mut on = !excluded.contains(&g.emulator);
                if ui::check(ui, &p, &mut on, "").on_hover_text("Inclure dans la sauvegarde").changed() {
                    let mut v: Vec<String> = excluded.iter().filter(|x| **x != g.emulator).cloned().collect();
                    if !on { v.push(g.emulator.clone()); }
                    acts.push(Act::Setting("backupExcludedEmulators", v.into()));
                }
                ui.vertical(|ui| {
                    ui.spacing_mut().item_spacing.y = 1.0;
                    ui.label(RichText::new(&g.name).strong());
                    let files: u64 = g.folders.iter().map(|f| f.files).sum();
                    let bytes: u64 = g.folders.iter().map(|f| f.bytes).sum();
                    ui.label(RichText::new(format!("{files} fichier{} · {}{}", pl(files as usize), if bytes > 0 { sys::bytes(bytes) } else { "0 o".into() }, if g.installed { "" } else { " · émulateur absent" })).size(11.5).color(p.muted));
                });
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    let en = ok && !app.backup.running;
                    if ui.add_enabled(en, egui::Button::new("Restaurer…")).clicked() { acts.push(Act::AskRestore(Some(g.emulator.clone()), g.name.clone())); }
                    if ui.add_enabled(en, egui::Button::new("Sauvegarder")).clicked() { acts.push(Act::RunBackup(true, Some(g.emulator.clone()))); }
                });
            });
            for f in &g.folders {
                let on = kinds.iter().any(|k| k == f.folder.kind);
                ui.horizontal(|ui| {
                    if !on { ui.set_opacity(0.45); }
                    ui.add_space(26.0);
                    ui.add_sized([170.0, 16.0], egui::Label::new(RichText::new(&f.folder.title).size(11.5)).truncate());
                    let path = f.folder.url.to_string_lossy().to_string();
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        if ui::icon_button(ui, &p, "folder", 12.0, "Afficher").clicked() { acts.push(Act::Reveal(f.folder.url.clone())); }
                        match &f.backed {
                            Some(e) => { ui.add(icons::image("checkCircle", 13.0, p.ok)).on_hover_text(format!("Sur le disque : {}", chrono::DateTime::parse_from_rfc3339(&e.date).map(|d| d.with_timezone(&chrono::Local).format("%d/%m/%Y %H:%M").to_string()).unwrap_or(e.date.clone()))); }
                            None => { ui.add_space(13.0); }
                        }
                        ui.label(RichText::new(if f.bytes > 0 { sys::bytes(f.bytes) } else { "0 o".into() }).size(11.5).color(p.muted));
                        ui.add(egui::Label::new(RichText::new(tilde(&path)).size(11.0).color(p.tertiary)).truncate()).on_hover_text(&path);
                    });
                });
            }
        });
    }
}

// ── Messages ──────────────────────────────────────────────────────────────

fn messages(app: &mut App, ctx: &egui::Context) {
    let Some((err, text)) = app.error.clone().map(|e| (true, e)).or(app.info.clone().map(|i| (false, i))) else { return };
    let p = app.p;
    let close = ui::sheet(ctx, "msg", 420.0, |ui| {
        ui.label(RichText::new(if err { "Erreur" } else { "Biblijeu" }).font(theme::bold(15.0)));
        ui.add(egui::Label::new(text.as_str()).wrap().selectable(true));
        ui.add_space(6.0);
        ui.horizontal(|ui| ui.with_layout(Layout::right_to_left(Align::Center), |ui| ui::primary(ui, &p, "OK").clicked()).inner).inner
    });
    if close { if err { app.error = None; } else { app.info = None; } }
}

// ── Corriger la jaquette ──────────────────────────────────────────────────

fn correction_sheet(app: &mut App, ctx: &egui::Context) {
    if app.correction.is_none() { return; }
    let p = app.p;
    let has_key = !app.settings.string("steamGridDBKey").is_empty();
    let mut search = false;
    let mut chosen: Option<(String, String, String)> = None;
    let mut c = app.correction.take().unwrap();
    let close = ui::sheet(ctx, "correct", 620.0, |ui| {
        ui.label(RichText::new("Corriger la jaquette").font(theme::bold(15.0)));
        small(ui, &p, "Cherchez sous un autre titre, puis choisissez la bonne image.");
        ui.horizontal(|ui| {
            let r = ui.add(egui::TextEdit::singleline(&mut c.query).desired_width(ui.available_width() - 100.0));
            if r.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) { search = true; }
            if ui::primary(ui, &p, "Rechercher").clicked() { search = true; }
        });
        match &c.results {
            None => { ui.add_space(30.0); ui.vertical_centered(|ui| { ui::spinner(ui, 18.0); ui.label(RichText::new("Recherche…").color(p.muted)); }); ui.add_space(30.0); }
            Some(list) if list.is_empty() => { ui.add_space(30.0); ui.vertical_centered(|ui| small(ui, &p, &format!("Aucune image trouvée.{}", if has_key { "" } else { " Une clé SteamGridDB (Réglages → Jaquettes) élargit la recherche." }))); ui.add_space(30.0); }
            Some(list) => {
                egui::ScrollArea::vertical().max_height(400.0).show(ui, |ui| {
                    let (cols, gap) = (5usize, 10.0);
                    let cw = (ui.available_width() - gap * (cols as f32 - 1.0)) / cols as f32;
                    for row in list.chunks(cols) {
                        ui.horizontal(|ui| {
                            ui.spacing_mut().item_spacing.x = gap;
                            for cand in row {
                                let (rect, resp) = ui.allocate_exact_size(Vec2::new(cw, cw * 4.0 / 3.0 + 18.0), Sense::click());
                                let img = Rect::from_min_size(rect.min, Vec2::new(cw, cw * 4.0 / 3.0));
                                ui.painter().rect_filled(img, 6, Color32::BLACK);
                                let src = Source::Url(cand.url.clone());
                                if let Some((t, sz)) = app.images.get(&src, Size::Thumb) { ui::paint_texture(ui, img, &t, sz, 6, ui::Fit::Contain); } else { ui::spinner(ui, 0.0); }
                                if resp.hovered() { ui.painter().rect_stroke(img, 6, Stroke::new(2.0_f32, p.accent), egui::StrokeKind::Outside); }
                                ui::text_in(ui, Rect::from_min_size(egui::pos2(rect.left(), img.bottom() + 3.0), Vec2::new(cw, 14.0)), &format!("{} · {}", cand.source, cand.title), theme::regular(10.5), p.muted);
                                let resp = resp.on_hover_text(format!("{} — {}", cand.title, cand.source));
                                if resp.clicked() { chosen = Some((c.id.clone(), cand.url.clone(), c.query.clone())); }
                            }
                        });
                    }
                });
            }
        }
        ui.horizontal(|ui| ui.with_layout(Layout::right_to_left(Align::Center), |ui| ui.button("Annuler").clicked()).inner).inner
    });
    if let Some((id, url, q)) = chosen { app.apply_artwork(&id, url, &q); return; }
    if close { return; }
    app.correction = Some(c);
    if search { app.search_candidates(ctx); }
}

// ── Réglages ──────────────────────────────────────────────────────────────

fn paths(ui: &mut Ui, p: &theme::Palette, list: &[String], key: &'static str, acts: &mut Vec<Act>) {
    egui::Frame::new().fill(Color32::from_black_alpha(40)).corner_radius(7).inner_margin(6).show(ui, |ui| {
        ui.set_width(ui.available_width());
        if list.is_empty() { ui.label(RichText::new("Aucun.").color(p.muted)); }
        for x in list {
            ui.horizontal(|ui| {
                ui.add(icons::image("folder", 13.0, p.muted));
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if ui::icon_button(ui, p, "minus", 12.0, "Retirer").clicked() { acts.push(Act::RemoveFrom(key, x.clone())); }
                    ui.with_layout(Layout::left_to_right(Align::Center), |ui| { ui.add(egui::Label::new(RichText::new(x).size(12.0)).truncate()).on_hover_text(x); });
                });
            });
        }
    });
}

fn settings_sheet(app: &mut App, ctx: &egui::Context, acts: &mut Vec<Act>) {
    let Some(mut tab) = app.settings_tab else { return };
    let p = app.p;
    let mut close = false;
    let shut = ui::sheet(ctx, "settings", 640.0, |ui| {
        ui.horizontal(|ui| {
            ui.label(RichText::new("Réglages").font(theme::bold(16.0)));
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| if ui::icon_button(ui, &p, "x", 13.0, "Fermer").clicked() { close = true; });
        });
        ui.horizontal(|ui| {
            for (t, l) in [(Tab::Sources, "Sources"), (Tab::Launch, "Lancement"), (Tab::Artwork, "Jaquettes"), (Tab::App, "Application")] {
                if ui.selectable_label(tab == t, l).clicked() { tab = t; }
            }
        });
        ui.separator();
        egui::ScrollArea::vertical().max_height((ctx.screen_rect().height() - 220.0).max(300.0)).min_scrolled_height((ctx.screen_rect().height() - 220.0).max(300.0)).auto_shrink([false, true]).show(ui, |ui| {
            ui.spacing_mut().item_spacing.y = 10.0;
            let check = |ui: &mut Ui, app: &App, acts: &mut Vec<Act>, key: &'static str, label: &str, help: &str| {
                let mut v = app.settings.bool(key);
                if ui::check_help(ui, &p, &mut v, label, help).changed() { acts.push(Act::Setting(key, v.into())); }
            };
            match tab {
                Tab::Sources => {
                    ui::group(ui, &p, "Dossiers de ROM", |ui| { paths(ui, &p, &app.settings.strings("romFolders"), "romFolders", acts); if ui.button("Ajouter…").clicked() { acts.push(Act::Pick(PickFor::RomFolder)); } });
                    ui::group(ui, &p, "Dossiers exclus", |ui| {
                        small(ui, &p, "Laissés de côté par l'analyse et la surveillance (téléchargements en cours, dossiers de travail…).");
                        paths(ui, &p, &app.settings.strings("excludedFolders"), "excludedFolders", acts);
                        if ui.button("Ajouter…").clicked() { acts.push(Act::Pick(PickFor::Excluded)); }
                    });
                    ui::group(ui, &p, "Dossiers d'émulateurs et d'AppImage", |ui| {
                        small(ui, &p, "Cherchés sur trois niveaux, en plus des Flatpak et des paquets installés : « Emulateurs/Playstation 3/rpcs3.AppImage » est trouvé.");
                        paths(ui, &p, &app.settings.strings("applicationFolders"), "applicationFolders", acts);
                        if ui.button("Ajouter…").clicked() { acts.push(Act::Pick(PickFor::AppFolder)); }
                    });
                    ui::group(ui, &p, "", |ui| {
                        check(ui, app, acts, "scanSteam", "Inclure les jeux Steam", "Les jeux installés et ceux ajoutés à Steam à la main ; ils se lancent par Steam.");
                        check(ui, app, acts, "scanApplications", "Inclure les jeux et lanceurs installés", "Ceux du menu des applications (Flatpak compris) qui se déclarent comme jeux.");
                        check(ui, app, acts, "watchFolders", "Surveiller les dossiers", "Un jeu copié dans un dossier, ou installé par Steam, apparaît tout seul.");
                        let manual = app.settings.strings("manualApplications");
                        ui.label(RichText::new("Ajoutés à la main").font(theme::bold(12.5)));
                        paths(ui, &p, &manual, "manualApplications", acts);
                        if ui.button("Ajouter une application…").clicked() { acts.push(Act::Pick(PickFor::Application)); }
                    });
                }
                Tab::Launch => {
                    ui::group(ui, &p, "", |ui| {
                        check(ui, app, acts, "directLaunch", "Lancement direct", "Plein écran et sans l'interface de l'émulateur, quand il l'accepte (Dolphin, DuckStation, PCSX2…).");
                        check(ui, app, acts, "resumeOnLaunch", "Reprendre la sauvegarde d'état au lancement", "Quand l'émulateur sait le faire en ligne de commande (DuckStation, PCSX2).");
                    });
                    ui::group(ui, &p, "Jeux Windows : Proton", |ui| {
                        if app.protons.is_empty() { small(ui, &p, "Aucun Proton trouvé : installez « Proton Experimental » depuis Steam."); }
                        else {
                            let cur = app.settings.string("protonVersion");
                            let auto = format!("Automatique ({})", app.protons[0]);
                            egui::ComboBox::from_id_salt("proton-all").width(300.0).selected_text(if cur.is_empty() { auto.clone() } else { cur.clone() }).show_ui(ui, |ui| {
                                if ui.selectable_label(cur.is_empty(), auto).clicked() { acts.push(Act::Setting("protonVersion", "".into())); }
                                for pr in &app.protons { if ui.selectable_label(&cur == pr, pr).clicked() { acts.push(Act::Setting("protonVersion", pr.clone().into())); } }
                            });
                        }
                        small(ui, &p, &format!("Les Proton que Steam a installés (bibliothèques Steam et compatibilitytools.d). {} Les jeux Steam, eux, utilisent le Proton choisi dans Steam.",
                            if app.has_umu { "Lancés par umu-run, dans le conteneur Steam Linux Runtime, comme le fait Steam." } else { "umu-run est introuvable : Proton est lancé directement." }));
                        ui.horizontal(|ui| ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if ui.button("Ouvrir").clicked() { acts.push(Act::OpenPath(app.prefixes())); }
                            ui.with_layout(Layout::left_to_right(Align::Center), |ui| ui.add(egui::Label::new(RichText::new(format!("Préfixes : {}", app.settings.string("prefixesFolder"))).size(11.5).color(p.muted)).truncate()));
                        }));
                    });
                    ui::group(ui, &p, "Émulateur par console", |ui| {
                        let prefs: HashMap<String, String> = app.settings.get_as("emulatorForSystem").unwrap_or_default();
                        let mut any = false;
                        egui::Grid::new("emusys").num_columns(2).spacing([20.0, 6.0]).show(ui, |ui| {
                            for s in catalog::SYSTEMS.iter().filter(|s| s.id != "windows") {
                                let alts: Vec<_> = app.emulators.iter().filter(|e| e.how != How::Proton && crate::emulators::runs(e, s.id)).collect();
                                if alts.is_empty() { continue; }
                                any = true;
                                ui.label(s.name);
                                let cur = prefs.get(s.id).cloned();
                                egui::ComboBox::from_id_salt(("es", s.id)).width(200.0).selected_text(cur.as_deref().and_then(catalog::emulator).map(|e| e.name).unwrap_or("Automatique")).show_ui(ui, |ui| {
                                    let mut set = |v: Option<&str>| { let mut m = prefs.clone(); match v { Some(v) => { m.insert(s.id.into(), v.into()); } None => { m.remove(s.id); } } acts.push(Act::Setting("emulatorForSystem", serde_json::to_value(m).unwrap())); };
                                    if ui.selectable_label(cur.is_none(), "Automatique").clicked() { set(None); }
                                    for e in &alts { if ui.selectable_label(cur.as_deref() == Some(e.id()), e.name()).clicked() { set(Some(e.id())); } }
                                });
                                ui.end_row();
                            }
                        });
                        if !any { small(ui, &p, "Aucun émulateur installé."); }
                    });
                    if ui.button("Effacer l'historique de jeu").clicked() {
                        for s in app.states.values_mut() { s.last_played = None; s.play_count = 0; }
                        app.save_states();
                    }
                }
                Tab::Artwork => {
                    ui::group(ui, &p, "", |ui| {
                        check(ui, app, acts, "autoFetchArtwork", "Rechercher les jaquettes après l'analyse", "");
                        ui.horizontal(|ui| {
                            ui.label("Région préférée");
                            let cur = app.settings.string("preferredRegion");
                            egui::ComboBox::from_id_salt("region").selected_text(&cur).show_ui(ui, |ui| {
                                for r in ["Europe", "France", "États-Unis", "Japon", "Monde"] { if ui.selectable_label(cur == r, r).clicked() { acts.push(Act::Setting("preferredRegion", r.into())); } }
                            });
                        });
                        ui.horizontal(|ui| {
                            ui.label("Taille des vignettes");
                            let mut v = app.settings.f64("cardSize") as f32;
                            if ui.add(egui::Slider::new(&mut v, 120.0..=260.0).step_by(4.0).show_value(false)).changed() { acts.push(Act::Setting("cardSize", (v as u32).into())); }
                        });
                    });
                    ui::group(ui, &p, "Clé SteamGridDB", |ui| {
                        let mut key = app.settings.string("steamGridDBKey");
                        if ui.add(egui::TextEdit::singleline(&mut key).password(true).hint_text("Collez votre clé ici").desired_width(f32::INFINITY)).changed() { acts.push(Act::Setting("steamGridDBKey", key.trim().to_string().into())); app.key_status = None; }
                        small(ui, &p, "Gratuite : créez un compte sur steamgriddb.com, puis Preferences → API → Generate API key. Elle couvre ce que l'archive libretro n'a pas : Switch, jeux PC.");
                        ui.horizontal(|ui| {
                            if ui.button("Tester la clé").clicked() { app.test_key(ctx); }
                            if ui.link("Obtenir une clé").clicked() { acts.push(Act::OpenUrl("https://www.steamgriddb.com/profile/preferences/api".into())); }
                            match app.key_status { Some(None) => ui::spinner(ui, 14.0), Some(Some(true)) => { ui.label(RichText::new("Clé valide").color(p.ok)); } Some(Some(false)) => { ui.label(RichText::new("Clé refusée").color(p.warm)); } None => {} }
                        });
                    });
                    ui.horizontal(|ui| {
                        if ui.button("Rechercher les jaquettes manquantes").clicked() { acts.push(Act::FetchArt); }
                        if ui.button("Tout rechercher à nouveau").clicked() { app.clear_artwork(ctx); }
                    });
                }
                Tab::App => {
                    ui::group(ui, &p, "Mises à jour de Biblijeu", |ui| {
                        let mut auto = SelfUpdate::automatic(&app.settings);
                        if ui::check(ui, &p, &mut auto, crate::common::selfupdate::AUTO_TITLE).changed() { SelfUpdate::set_automatic(&mut app.settings, auto); }
                        ui.horizontal(|ui| {
                            if ui.button("Rechercher maintenant").clicked() { app.update.check_now(ctx); }
                            ui.label(RichText::new(format!("Version {}", app.update.version())).color(p.muted));
                        });
                    });
                    ui::group(ui, &p, "Dossiers de Biblijeu", |ui| {
                        ui.horizontal(|ui| ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if ui.button("Ouvrir").clicked() { acts.push(Act::OpenPath(app.dir.clone())); }
                            ui.with_layout(Layout::left_to_right(Align::Center), |ui| ui.add(egui::Label::new(RichText::new(app.dir.to_string_lossy()).size(11.5).color(p.muted)).truncate()));
                        }));
                    });
                }
            }
        });
        close
    });
    app.settings_tab = if shut { None } else { Some(tab) };
}
