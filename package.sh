#!/bin/bash
# Packages the project into a single archive you can carry to another machine.
#
#   ./package.sh                  sources seules
#   ./package.sh --with-data      + vos réglages, favoris, historique et jaquettes
#   ./package.sh --with-saves     + vos sauvegardes de jeu (états et cartes mémoire)
#   ./package.sh --with-key       + la clé SteamGridDB
#
# Les options se combinent : ./package.sh --with-data --with-saves --with-key
set -euo pipefail
cd "$(dirname "$0")"

WITH_DATA=0
WITH_SAVES=0
WITH_KEY=0
for arg in "$@"; do
    case "$arg" in
        --with-data)  WITH_DATA=1 ;;
        --with-saves) WITH_SAVES=1 ;;
        --with-key)   WITH_KEY=1 ;;
        -h|--help)    sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "option inconnue : $arg"; exit 1 ;;
    esac
done

STAMP="$(date +%Y%m%d-%H%M)"
NAME="Biblijeu-$STAMP"
OUT="$HOME/Desktop/$NAME.tar.gz"
STAGE="$(mktemp -d)/$NAME"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT
mkdir -p "$STAGE"

echo "▸ Copie des sources…"
cp -R Sources Package.swift README.md "$STAGE/"
[ -d Resources ] && cp -R Resources "$STAGE/"
cp build.sh install.sh package.sh "$STAGE/"
[ -f .gitignore ] && cp .gitignore "$STAGE/"

SUPPORT="$HOME/Library/Application Support/Biblijeu"
if [ "$WITH_DATA" = "1" ]; then
    echo "▸ Ajout des données personnelles…"
    mkdir -p "$STAGE/data"
    [ -d "$SUPPORT" ] && cp -R "$SUPPORT/." "$STAGE/data/" 2>/dev/null || true

    # Le domaine entier plutôt qu'une liste de clés tenue à la main : un réglage
    # ajouté à l'app est repris sans que ce script ait à le savoir. Seuls la
    # position des fenêtres et, sauf demande, la clé d'API sont retirées.
    defaults export com.biblijeu.app "$STAGE/data/settings.plist" 2>/dev/null || \
        echo "{}" > "$STAGE/data/settings.plist"
    WITH_KEY=$WITH_KEY python3 - "$STAGE/data/settings.plist" <<'PY'
import os, plistlib, sys

path = sys.argv[1]
try:
    with open(path, "rb") as f:
        settings = plistlib.load(f)
except Exception:
    settings = {}

noise = ("NSWindow", "NSSplitView", "NSNav", "NSOSP", "com_apple_SwiftUI_")
settings = {k: v for k, v in settings.items() if not k.startswith(noise)}
if os.environ.get("WITH_KEY") != "1":
    settings.pop("steamGridDBKey", None)

with open(path, "wb") as f:
    plistlib.dump(settings, f)
print(f"  {len(settings)} réglages exportés")
PY
    [ "$WITH_KEY" = "1" ] || echo "  (clé SteamGridDB non incluse — utilisez --with-key)"
fi

if [ "$WITH_SAVES" = "1" ]; then
    # Les sauvegardes de jeu n'appartiennent pas à Biblijeu : elles vivent chez
    # les émulateurs. Sans elles, une archive « complète » ramènerait une
    # bibliothèque intacte et zéro progression.
    echo "▸ Ajout des sauvegardes de jeu…"
    mkdir -p "$STAGE/saves"
    python3 - "$HOME/Library/Application Support" "$STAGE/saves" <<'PY'
import os, shutil, sys

support, out = sys.argv[1], sys.argv[2]

# Dossier de données, fichier de réglages, clé du dossier d'états, autres
# dossiers à emporter tels quels.
EMULATORS = [
    ("DuckStation", "settings.ini",   "SaveStates", "savestates", ["memcards"]),
    ("PCSX2",       "inis/PCSX2.ini", "Savestates", "sstates",    ["memcards"]),
    ("Dolphin",     None,             None,         "StateSaves", ["GC", "Wii"]),
    ("PPSSPP",      None,             None,         "PSP/PPSSPP_STATE", ["PSP/SAVEDATA"]),
]


def configured(root, ini, key, default):
    """Le dossier d'états tel que l'émulateur le connaît, déplacement compris."""
    if ini and key:
        path = os.path.join(root, ini)
        try:
            with open(path, encoding="utf-8") as f:
                in_folders = False
                for line in f:
                    line = line.strip()
                    if line.startswith("["):
                        in_folders = line.lower() == "[folders]"
                        continue
                    if in_folders and "=" in line:
                        name, _, value = line.partition("=")
                        if name.strip().lower() == key.lower() and value.strip():
                            value = value.strip()
                            return value if value.startswith("/") else os.path.join(root, value)
        except OSError:
            pass
    return os.path.join(root, default)


total = 0
for name, ini, key, states, extras in EMULATORS:
    root = os.path.join(support, name)
    if not os.path.isdir(root):
        continue
    for source in [configured(root, ini, key, states)] + [os.path.join(root, e) for e in extras]:
        if not os.path.isdir(source):
            continue
        # Rangé sous le nom de l'émulateur, avec le nom du dossier d'origine.
        target = os.path.join(out, name, os.path.basename(source))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copytree(source, target, dirs_exist_ok=True)
        size = sum(os.path.getsize(os.path.join(d, f))
                   for d, _, files in os.walk(target) for f in files)
        total += size
        print(f"  {name}/{os.path.basename(source)} — {size / 1e6:.0f} Mo")

if total == 0:
    print("  (aucune sauvegarde trouvée)")
PY
fi

cat > "$STAGE/RESTORE.md" <<'DOC'
# Reprendre Biblijeu sur une autre machine

## Ce qu'il faut
- macOS 14 ou plus récent
- Les outils en ligne de commande Xcode (`xcode-select --install`)
- Xcode complet pour l'icône claire/sombre/teintée ; sans lui, `build.sh`
  retombe sur `Resources/AppIcon.icns` et l'app se construit quand même
- Vos émulateurs (DuckStation, PCSX2, Dolphin, Ryujinx…) dans /Applications

## Remise en route

```bash
tar -xzf Biblijeu-*.tar.gz
cd Biblijeu-*
./build.sh          # compile, aucune dépendance à télécharger
./install.sh        # installe dans /Applications
open /Applications/Biblijeu.app
```

## Restaurer vos données

Si l'archive contient un dossier `data/` :

```bash
mkdir -p ~/Library/Application\ Support/Biblijeu
cp data/play-state.json ~/Library/Application\ Support/Biblijeu/
cp -R data/Artwork ~/Library/Application\ Support/Biblijeu/ 2>/dev/null

defaults import com.biblijeu.app data/settings.plist
```

`play-state.json` contient vos favoris, votre historique, les jaquettes
retrouvées et les sauvegardes d'état repérées pour chaque jeu — c'est le
fichier à ne pas perdre. Une copie de la version précédente est gardée à côté
sous `play-state.backup.json`.

Les jeux sont identifiés par leur nom de fichier et leur taille, pas par leur
chemin : vos ROM peuvent atterrir dans un autre dossier sur la nouvelle machine
sans que rien ne soit perdu.

## Restaurer vos sauvegardes de jeu

Si l'archive contient un dossier `saves/` :

```bash
cp -R saves/DuckStation/savestates ~/Library/Application\ Support/DuckStation/
cp -R saves/DuckStation/memcards   ~/Library/Application\ Support/DuckStation/
cp -R saves/PCSX2/sstates          ~/Library/Application\ Support/PCSX2/
cp -R saves/PCSX2/memcards         ~/Library/Application\ Support/PCSX2/
```

Adaptez aux émulateurs présents dans `saves/`. Attention : une sauvegarde
d'état DuckStation retient le chemin absolu du disque au moment où elle a été
prise. Si vos ROM changent de place, la première reprise peut échouer — jouez
une fois et quittez, l'état est réécrit avec le nouveau chemin. Les cartes
mémoire, elles, ne dépendent d'aucun chemin.

## Diagnostic

```bash
dist/Biblijeu.app/Contents/MacOS/Biblijeu --scan ~/chemin/vers/ROM
dist/Biblijeu.app/Contents/MacOS/Biblijeu --scan --covers ~/chemin/vers/ROM
```

Affiche les émulateurs détectés, les jeux trouvés, la commande exacte qui sera
lancée pour chacun, la sauvegarde d'état sur laquelle « Reprendre » tombera, et
les jaquettes résolues.
DOC

echo "▸ Compression…"
tar -czf "$OUT" -C "$(dirname "$STAGE")" "$NAME"

echo "✓ $OUT  ($(du -h "$OUT" | cut -f1))"
[ "$WITH_DATA" = "1" ]  && echo "  (contient vos réglages et votre historique)"
[ "$WITH_SAVES" = "1" ] && echo "  (contient vos sauvegardes de jeu)"
exit 0
