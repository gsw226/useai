#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=UseAI.app
mkdir -p $APP/Contents/MacOS
swiftc -O -parse-as-library UseAI.swift -o $APP/Contents/MacOS/UseAI
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UseAI</string>
<key>CFBundleIdentifier</key><string>xyz.gsw226.useai</string>
<key>CFBundleName</key><string>UseAI</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
codesign -fs - $APP
echo "built $APP"
