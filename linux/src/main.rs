//! Biblijeu pour Linux : la bibliothèque de jeux — ROM rangées par console, jeux
//! Steam, jeux Windows lancés avec Proton, émulateurs (Flatpak, paquets,
//! AppImage), jaquettes et sauvegardes.

mod app;
mod artwork;
mod backup;
mod catalog;
mod common;
mod emulators;
mod scanner;
mod steam;
mod views;

fn main() -> eframe::Result {
    let icon = image::load_from_memory(include_bytes!("../resources/icon.png")).ok().map(|i| {
        let i = i.to_rgba8();
        let (w, h) = i.dimensions();
        egui::IconData { rgba: i.into_raw(), width: w, height: h }
    });
    let mut viewport = egui::ViewportBuilder::default()
        .with_title("Biblijeu").with_app_id("biblijeu").with_inner_size([1320.0, 840.0]).with_min_inner_size([980.0, 620.0]);
    if let Some(i) = icon { viewport = viewport.with_icon(i); }
    let options = eframe::NativeOptions { viewport, renderer: eframe::Renderer::Glow, ..Default::default() };
    eframe::run_native("Biblijeu", options, Box::new(|cc| Ok(Box::new(app::App::new(cc)))))
}
