//! L'icône de l'app sous Wayland : le compositeur (KDE, GNOME) ignore l'icône que
//! la fenêtre fournit et cherche un fichier `<app_id>.desktop` installé. Sans lui,
//! la barre de titre et la barre des tâches montrent l'icône générique « W ».
//! Au démarrage, on installe donc ce fichier et l'icône dans ~/.local/share, et on
//! les remet à jour si l'AppImage a changé de place.

use std::path::PathBuf;

pub struct Entry<'a> { pub app_id: &'a str, pub name: &'a str, pub comment: &'a str, pub categories: &'a str, pub icon_png: &'a [u8] }

/// À appeler une fois au lancement ; ne fait rien si tout est déjà en place.
pub fn ensure(e: &Entry) {
    let Some(data) = dirs::data_dir() else { return };
    // L'AppImage elle-même (pas le dossier temporaire où elle se monte), sinon le programme.
    let exe = std::env::var_os("APPIMAGE").map(PathBuf::from).or_else(|| std::env::current_exe().ok());
    let Some(exe) = exe else { return };
    let mut changed = false;

    let icon = data.join("icons/hicolor/512x512/apps").join(format!("{}.png", e.app_id));
    if std::fs::read(&icon).map(|b| b != e.icon_png).unwrap_or(true) {
        let _ = std::fs::create_dir_all(icon.parent().unwrap());
        changed |= std::fs::write(&icon, e.icon_png).is_ok();
    }

    let exec = exe.to_string_lossy().replace('\\', "\\\\").replace('"', "\\\"");
    let text = format!("[Desktop Entry]\nType=Application\nName={}\nComment={}\nExec=\"{exec}\" %U\nIcon={}\nCategories={}\nStartupWMClass={}\nTerminal=false\n",
        e.name, e.comment, e.app_id, e.categories, e.app_id);
    let file = data.join("applications").join(format!("{}.desktop", e.app_id));
    if std::fs::read_to_string(&file).map(|t| t != text).unwrap_or(true) {
        let _ = std::fs::create_dir_all(file.parent().unwrap());
        changed |= std::fs::write(&file, text).is_ok();
    }

    // Que le bureau le connaisse AVANT que la fenêtre s'ouvre : KWin cherche
    // l'icône une seule fois, à l'apparition de la fenêtre (KDE : kbuildsycoca ;
    // ailleurs : update-desktop-database). Une seconde, et seulement après un changement.
    if changed {
        for (cmd, args) in [("kbuildsycoca6", vec![]), ("kbuildsycoca5", vec![]), ("update-desktop-database", vec![data.join("applications").to_string_lossy().to_string()])] {
            let _ = std::process::Command::new(cmd).args(args).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
        }
    }
}
