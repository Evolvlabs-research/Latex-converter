#!/bin/sh
# Construit app/Notes2LaTeX.app : ./app/build.sh && open app/Notes2LaTeX.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Notes2LaTeX.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Notes2LaTeX "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Notes2LaTeX</string>
  <key>CFBundleIdentifier</key><string>local.notes2latex</string>
  <key>CFBundleName</key><string>Notes2LaTeX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF
echo "OK : $(pwd)/$APP"
