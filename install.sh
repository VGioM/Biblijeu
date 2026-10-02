#!/bin/bash
# Installs Biblijeu.app into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

# Toujours recompiler : c'est /Applications qui sert de référence, et se fier
# à la présence de dist/ y installait silencieusement une version périmée.
# swift build est incrémental, donc sans changement l'appel ne coûte rien.
./build.sh

echo "▸ Installation dans /Applications…"
rm -rf "/Applications/Biblijeu.app"
cp -R dist/Biblijeu.app "/Applications/Biblijeu.app"

echo "✓ Installé. Ouvrez-le depuis le Launchpad ou :"
echo "  open /Applications/Biblijeu.app"
