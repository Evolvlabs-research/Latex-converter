#!/bin/sh
# Construit app/Nabla.app : ./app/build.sh && open app/Nabla.app
# Sans compte Apple : signature ad hoc. Avec un compte, signature et notarisation (voir README.md) :
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
  fi
else
  # Sans compte Apple Developer : signature « ad hoc », sans certificat. Sans elle, macOS déclare l'app téléchargée
  # « endommagée » ; avec, il affiche « développeur non identifié », qu'on lève une fois dans les Réglages.
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
rm -f Nabla.zip
ditto -c -k --keepParent "$APP" Nabla.zip  # à publier ; une app notarisée y porte son ticket agrafé
echo "OK : $(pwd)/$APP"
echo "À publier : $(pwd)/Nabla.zip"
