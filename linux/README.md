# Biblijeu pour Linux

La version Linux de Biblijeu : vos dossiers de ROM, vos jeux Steam et vos applications
dans une seule bibliothèque, les consoles reconnues, les jaquettes retrouvées, chaque
jeu lancé avec le bon émulateur — et les sauvegardes copiées sur le disque de votre
choix. Une application native en Rust (l'app Mac est en SwiftUI), distribuée en
AppImage d'environ 6 Mo.

## Installer

Télécharger `Biblijeu-<version>-linux-x86_64.AppImage` dans les
[releases](https://github.com/VGioM/Biblijeu/releases), le rendre exécutable
(`chmod +x`) et le lancer. Les mises à jour se font ensuite depuis l'app (menu ··· →
Rechercher les mises à jour…, ou Réglages → Application).

## Ce qui est pareil

La reconnaissance des consoles (l'extension, puis le dossier qui tranche), ce qui est
ignoré (pistes d'un `.cue`, `Updates`, `DLC`, dossiers de travail, `.zip` hors dossier
d'arcade, un jeu installé = une vignette), les jeux multi-disques, le nettoyage des
noms, les jaquettes libretro puis SteamGridDB, les favoris et l'historique, les
corrections (type, console, émulateur par jeu ou par console), la reprise sur une
sauvegarde d'état (DuckStation, PCSX2, Dolphin, PPSSPP), et l'onglet Sauvegarde avec
les mêmes règles : rien n'est jamais supprimé, la partie la plus récente gagne, aucune
ROM n'est copiée, au lancement, toutes les X minutes et à la fermeture (20 s au plus).

## Ce qui change

**Émulateurs.** Cherchés en Flatpak, dans les paquets installés (PATH) et parmi les
AppImage des dossiers d'émulateurs (Réglages → Sources, trois niveaux de profondeur :
`Emulateurs/Playstation 3/rpcs3.AppImage` est trouvé). Un émulateur Flatpak reçoit
l'accès au dossier du jeu (`flatpak run --filesystem=…`). RetroArch reçoit le cœur
adapté à la console (`-L`), choisi parmi ceux installés.

**Jeux Windows : Proton.** Pas de CrossOver ni de Wine : un `.exe` se lance avec un
Proton que Steam a installé — Proton Experimental par défaut, ou Proton 10/11,
GE-Proton (`compatibilitytools.d`)… au choix dans les réglages ou jeu par jeu. Le
lancement passe par `umu-run` quand il est installé (conteneur Steam Linux Runtime,
comme Steam), sinon par le script `proton` dans le conteneur `SteamLinuxRuntime_sniper`.
Chaque jeu a son propre préfixe Wine (`~/.config/Biblijeu/prefixes/<jeu>`), et ses
sauvegardes (Saved Games, AppData, LocalLow, Documents) sont dans l'onglet Sauvegarde.

**Steam.** Les jeux installés (toutes les bibliothèques, disques externes compris) et
ceux ajoutés à la main (« Ajouter un jeu non-Steam ») apparaissent seuls, avec la
jaquette que Steam a déjà téléchargée, et se lancent par Steam — avec le Proton choisi
pour eux dans Steam.

**Applications.** Au lieu de /Applications : les jeux et lanceurs du menu des
applications (fichiers `.desktop`, Flatpak compris), avec leur icône.

**Mises à jour des émulateurs.** Les Flatpak sont vérifiés une fois par jour
(`flatpak remote-ls --updates`) et mis à jour d'un clic ; les émulateurs absents
s'installent depuis Flathub. Les paquets suivent le système ; les AppImage gardent un
lien vers la page du projet. Pas de signature de code à réparer sous Linux.

**Chemins.** Données dans `~/.config/Biblijeu/` (`settings.json`, `play-state.json` et
sa sauvegarde, `ThumbnailIndex/`, `prefixes/`). Les dossiers de sauvegarde du catalogue
couvrent l'installation native et Flatpak (`~/.var/app/<id>/…`) ; ce que l'émulateur
écrit lui-même dans sa configuration (`[Folders]` de DuckStation et PCSX2) passe avant.

Raccourcis : Ctrl+F chercher, Ctrl+R analyser, Ctrl+, réglages, Ctrl+I panneau
d'informations, Entrée jouer (Maj+Entrée : depuis le début), Échap désélectionner ;
double-clic sur une jaquette pour jouer, clic droit pour le menu du jeu.
`BIBLIJEU_SUPPORT` pointe les données ailleurs.

Pas encore porté : la lecture des états DuckStation pour retrouver le disque sur lequel
une partie a été laissée (la reprise utilise `-resume`, le fichier ou l'emplacement
choisis), et les modes en ligne de commande `--scan`, `--updates`, `--saves`.

## Développer

Une application Rust native ([egui](https://github.com/emilk/egui), rendu OpenGL,
Wayland et X11). Il faut Rust stable, et pour l'AppImage une Fedora — sur un système
immuable (Bazzite, Silverblue, Kinoite), un conteneur toolbox Fedora fait l'affaire :

```sh
toolbox create -c rustbuild --distro fedora --release 44
toolbox enter rustbuild
sudo dnf install -y gcc pkgconf-pkg-config squashfs-tools patchelf \
    wayland-devel libxkbcommon-devel libxkbcommon-x11 libX11-devel libXcursor libXrandr libXi mesa-libEGL-devel
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh    # Rust, si absent
```

Puis, dans `linux/` :

```sh
cargo run --release      # lance l'app
cargo test               # tests unitaires
./build-appimage.sh      # dist/Biblijeu-<version>-linux-x86_64.AppImage
```

`build-appimage.sh` compile, copie dans l'AppImage les bibliothèques dont le programme
a besoin — jamais la glibc, les pilotes graphiques, le son ni les bibliothèques de
base du bureau, qui restent celles du système — et la compresse (squashfs xz). Le
« runtime » AppImage placé en tête est pris dans `APPIMAGE_RUNTIME` (par défaut : celui
qu'electron-builder a mis en cache).

`src/common/` est le même dossier dans Biblifilm, Biblijeu et Recomps : thème, icônes,
cache des jaquettes (disque `~/.cache/Biblijeu/`, mémoire bornée), fenêtres de choix
(portail XDG), réglages, mise à jour intégrée (`selfupdate.rs`, l'équivalent de
`SelfUpdate.swift` : elle ne prend que le fichier `-linux-x86_64.AppImage` de la
release, vérifie son empreinte SHA-256 publiée par GitHub, puis remplace l'AppImage).

## Publier

```sh
cd linux && ./release-linux.sh 1.4.0    # l'AppImage, dans la release v1.4.0 (créée si besoin)
```

Mac et Linux partagent les releases du dépôt, pas leurs numéros : une release peut
contenir le zip Mac, l'AppImage, ou les deux. Chaque version ne prend que son fichier
(`-macOS-arm64.zip` ou `-linux-x86_64.AppImage`) et se met à jour vers la release la
plus récente qui le contient ; une release Mac seule ne cache pas une version Linux,
et inversement. Un numéro (un tag) ne sert qu'une fois.
