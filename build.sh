#!/bin/bash
# Builds Biblijeu.app into ./dist and signs it.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="dist/Biblijeu.app"

echo "▸ Compilation ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Biblijeu"

echo "▸ Assemblage du bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Biblijeu"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>Biblijeu</string>
    <key>CFBundleDisplayName</key>           <string>Biblijeu</string>
    <key>CFBundleExecutable</key>            <string>Biblijeu</string>
    <key>CFBundleIdentifier</key>            <string>com.biblijeu.app</string>
    <key>CFBundleVersion</key>               <string>1.2</string>
    <key>CFBundleShortVersionString</key>    <string>1.2</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleIconName</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
    <key>NSHumanReadableCopyright</key>      <string>Biblijeu</string>
</dict>
</plist>
PLIST

# The icon. An Icon Composer bundle carries a light, a dark and a tinted
# rendition -- the only format on which macOS honours the appearance -- and
# actool distils a plain .icns out of it for anything older. actool talks to a
# daemon with its own working directory, hence the absolute paths.
ICON_BUILT=0
if [ -d Resources/AppIcon.icon ] && xcrun --find actool >/dev/null 2>&1; then
    echo "▸ Icône (claire / sombre / teintée)…"
    if xcrun actool "$PWD/Resources/AppIcon.icon" \
            --compile "$PWD/$APP/Contents/Resources" \
            --platform macosx --minimum-deployment-target 26.0 \
            --app-icon AppIcon \
            --output-partial-info-plist "$PWD/$APP/Contents/Resources/.icon.plist" \
            2>/dev/null | grep -q "com.apple.actool.errors"; then
        echo "  (actool a refusé le .icon — repli sur l'icns)"
    else
        ICON_BUILT=1
    fi
    rm -f "$APP/Contents/Resources/.icon.plist"
fi

# The .icns actool distils out of the .icon holds only the 16 and 128 sizes, so
# ours -- complete from 16 to 1024 -- goes in last. macOS 26 and later read the
# catalogue through CFBundleIconName and never look at it; everything older sees
# only this file.
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif [ "$ICON_BUILT" = "0" ]; then
    echo "  (aucune icône)"
fi

# Signed with the local certificate when there is one (./signing-cert.sh makes
# it): macOS then keeps its permissions -- Documents and the rest -- from one
# build to the next. Ad hoc otherwise, which it takes for a new app each time.
IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "Biblijeu Local Signing"; then
    IDENTITY="Biblijeu Local Signing"
    echo "▸ Signature (certificat local)…"
else
    echo "▸ Signature ad hoc (lancez ./signing-cert.sh pour que macOS garde ses autorisations)…"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/Biblijeu"
codesign --force --sign "$IDENTITY" "$APP"

echo "✓ $APP prêt"
