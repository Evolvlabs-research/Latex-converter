#!/bin/sh
# Construit app/Nabla.app : ./app/build.sh && open app/Nabla.app
# Signature et notarisation, facultatives (voir README.md à la racine du dépôt) :
#   NABLA_SIGN_IDENTITY="Developer ID Application: Nom (EQUIPE)" NABLA_NOTARY_PROFILE=nabla ./app/build.sh
set -e
cd "$(dirname "$0")"
VERSION=1.0
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)  # numéro de build : nombre de commits, toujours croissant
# Programme universel : Mac à puce Apple et Mac Intel.
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
APP=Nabla.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN/Nabla" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array><string>fr</string></array>
  <key>CFBundleExecutable</key><string>Nabla</string>
  <key>CFBundleIdentifier</key><string>org.evolvlabs.nabla</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Wassim Ghnaya. Licence MIT.</string>
  <key>CFBundleName</key><string>Nabla</string>
  <key>CFBundleDisplayName</key><string>Nabla</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF

if [ -n "$NABLA_SIGN_IDENTITY" ]; then
  codesign --force --options runtime --timestamp --sign "$NABLA_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  if [ -n "$NABLA_NOTARY_PROFILE" ]; then
    rm -f Nabla.zip
    ditto -c -k --keepParent "$APP" Nabla.zip
    xcrun notarytool submit Nabla.zip --keychain-profile "$NABLA_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm Nabla.zip
    ditto -c -k --keepParent "$APP" Nabla.zip  # à partager : ticket de notarisation agrafé à l'app
    echo "À partager : $(pwd)/Nabla.zip"
  fi
else
  echo "Non signée (NABLA_SIGN_IDENTITY absente) : s'ouvre sur ce Mac, pas ailleurs sans clic droit > Ouvrir."
fi
echo "OK : $(pwd)/$APP"
