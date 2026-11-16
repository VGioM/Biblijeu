# Biblijeu pour Windows

La version Windows de Biblijeu : vos dossiers de ROM, vos jeux Steam et vos jeux
Windows dans une seule bibliothèque, les consoles reconnues, les jaquettes retrouvées,
chaque jeu lancé avec le bon émulateur, et les sauvegardes copiées sur le disque de
votre choix. Une application native en Rust ([egui](https://github.com/emilk/egui)),
tirée de la version Linux, distribuée en zip portable.

## Installer

Télécharger `Biblijeu-<version>-windows-x64.zip` dans les
[releases](https://github.com/VGioM/Biblijeu/releases), le décompresser et lancer
`Biblijeu.exe`. Les mises à jour se font ensuite depuis l'app (menu ··· → Rechercher
les mises à jour…, ou Réglages → Application).

## Ce qui est pareil

La reconnaissance des consoles, ce qui est ignoré, les jeux multi-disques, le
nettoyage des noms, les jaquettes libretro puis SteamGridDB, les favoris et
l'historique, les corrections (type, console, émulateur), la reprise sur une
sauvegarde d'état (DuckStation, PCSX2, Dolphin, PPSSPP), et l'onglet Sauvegarde :
rien n'est jamais supprimé, la partie la plus récente gagne, aucune ROM n'est copiée.

## Ce qui change

**Émulateurs.** Ce sont des `.exe`, cherchés sous leurs vrais noms Windows
(`Dolphin.exe`, `duckstation-qt-x64-ReleaseLTCG.exe`, `pcsx2-qt.exe`,
`PPSSPPWindows64.exe`, `retroarch.exe`…) :

1. dans les dossiers d'émulateurs des réglages (Sources, trois niveaux de profondeur :
   `Emulateurs\PS3\rpcs3.exe` est trouvé). Par défaut : `Emulation`, `Emulateurs`,
   `Emulators`, `Games` et `Jeux` dans le dossier de l'utilisateur ;
2. dans Program Files, `AppData\Local\Programs`, Scoop et `C:\RetroArch-Win64` ;
3. dans le PATH.

Un émulateur démarre dans son propre dossier, pour qu'une installation portable y
trouve sa configuration. RetroArch reçoit le cœur adapté à la console (`-L`), pris
dans son dossier `cores\` (`*_libretro.dll`).

**Jeux Windows.** Lancés directement, sans Proton ni CrossOver. Un raccourci `.lnk`,
un `.url`, un `.bat` ou un `.msi` passent par Windows.

**Steam.** Trouvé par le registre (`HKCU\Software\Valve\Steam`), toutes les
bibliothèques comprises ; les jeux installés et les raccourcis non-Steam apparaissent
seuls, avec la jaquette que Steam a déjà téléchargée, et se lancent par Steam.

**Applications.** Au lieu de /Applications ou des `.desktop` : les lanceurs (Epic,
GOG Galaxy, EA, Ubisoft Connect, Battle.net, Riot…) et les raccourcis rangés dans un
dossier de jeux du menu Démarrer.

**Mises à jour des émulateurs.** Pas de gestionnaire de paquets : l'onglet liste les
émulateurs trouvés (où, quelle version) avec la page de leur projet, et propose de
télécharger ceux qui manquent. Chacun se met à jour lui-même ou depuis sa page.

**Sauvegardes.** Les chemins Windows de chaque émulateur : à côté de l'exe pour une
installation portable (`User\` de Dolphin, `memstick\` de PPSSPP, `saves\` de
RetroArch…), sinon `Documents` ou `AppData\Roaming`. Ce que l'émulateur écrit dans sa
configuration (`[Folders]` de DuckStation et PCSX2) passe avant.

**Chemins.** Données dans `%APPDATA%\Biblijeu\`. `BIBLIJEU_SUPPORT` pointe les données
ailleurs.

Raccourcis : Ctrl+F chercher, Ctrl+R analyser, Ctrl+, réglages, Ctrl+I panneau
d'informations, Entrée jouer (Maj+Entrée : depuis le début), Échap désélectionner ;
double-clic sur une jaquette pour jouer, clic droit pour le menu du jeu.

## Développer

Il faut Rust stable (cible `x86_64-pc-windows-msvc`). Dans `windows/` :

```sh
cargo run --release      # lance l'app
cargo test               # tests unitaires
./build-windows.sh       # dist/Biblijeu-<version>-windows-x64.zip
```

`src/common/` est le même dossier dans Biblifilm, Biblijeu et Recomps.
