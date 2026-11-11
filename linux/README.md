# Biblijeu pour Linux

La version Linux de Biblijeu : vos dossiers de ROM, vos jeux Steam et vos applications
dans une seule bibliothèque, les consoles reconnues, les jaquettes retrouvées, chaque
jeu lancé avec le bon émulateur — et les sauvegardes copiées sur le disque de votre
choix. Écrite en Electron (l'app Mac est en SwiftUI), distribuée en AppImage.

## Installer

Télécharger `Biblijeu-<version>-linux-x86_64.AppImage` dans les
[releases](https://github.com/VGioM/Biblijeu/releases), le rendre exécutable
(`chmod +x`) et le lancer. Les mises à jour se font ensuite depuis l'app (menu Aide).

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

Pas encore porté : la lecture des états DuckStation pour retrouver le disque sur lequel
une partie a été laissée (la reprise utilise `-resume`, le fichier ou l'emplacement
choisis), et les modes en ligne de commande `--scan`, `--updates`, `--saves`.

## Développer

```sh
cd linux
npm install
npm start
npm test             # analyse (mêmes cas que RomScannerTests.swift), lancement, Steam, copie
npm run dist         # dist/Biblijeu-<version>-linux-x86_64.AppImage
```

- `src/shared.js` : consoles, émulateurs, noms de dumps, sections
- `src/scanner.js` : `RomScanner`, `SwitchTitle`, applications `.desktop`
- `src/emulators.js` : détection et commandes, Proton
- `src/steam.js` : bibliothèques, manifestes, `shortcuts.vdf`, jaquettes, Proton installés
- `src/artwork.js` : libretro et SteamGridDB
- `src/backup.js` : catalogue des sauvegardes et moteur de copie

## Publier

```sh
cd linux && ./release-linux.sh 1.4.0   # ajoute l'AppImage à la release v1.4.0 existante
```
