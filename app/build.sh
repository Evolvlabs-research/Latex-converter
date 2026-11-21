#!/bin/sh
# Construit app/Nabla.app : ./app/build.sh && open app/Nabla.app
# Signature et notarisation, facultatives (voir README.md) :
#   NABLA_SIGN_IDENTITY="Developer ID Application: Nom (EQUIPE)" NABLA_NOTARY_PROFILE=nabla ./app/build.sh
set -e
cd "$(dirname "$0")"
# Modèle Core ML : exporté depuis checkpoints/best.pt s'il manque (seule étape qui demande le dépôt Python)
[ -f Model/vocab.json ] || (cd .. && uv run export_coreml.py)
swift build -c release
APP=Nabla.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp .build/release/Notes2LaTeX "$APP/Contents/MacOS/"
mkdir "$APP/Contents/Resources/Model"
cp Model/vocab.json "$APP/Contents/Resources/Model/"
for m in Encoder Decoder; do  # compilé ici : l'app n'a rien à compiler au premier lancement
  xcrun coremlcompiler compile "Model/$m.mlpackage" "$APP/Contents/Resources/Model" >/dev/null
done
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>CFBundleLocalizations</key><array><string>fr</string></array>
  <key>CFBundleExecutable</key><string>Notes2LaTeX</string>
  <key>CFBundleIdentifier</key><string>local.notes2latex</string>
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
