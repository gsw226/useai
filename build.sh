#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=UseAI.app
# Antigravity uses Google's installed-app client secret; take it from env or an installed AI Limits Tracker.
SECRET=${ANTIGRAVITY_CLIENT_SECRET:-$(/usr/libexec/PlistBuddy -c 'Print :AntigravityClientSecret' "/Applications/AI Limits Tracker.app/Contents/Info.plist" 2>/dev/null || true)}
printf 'let antigravitySecret = "%s"\n' "$SECRET" > Secrets.swift
mkdir -p $APP/Contents/MacOS
swiftc -O -parse-as-library UseAI.swift Providers.swift Report.swift Secrets.swift -o $APP/Contents/MacOS/UseAI
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>UseAI</string>
<key>CFBundleIdentifier</key><string>xyz.gsw226.useai</string>
<key>CFBundleName</key><string>UseAI</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign -fs - $APP
echo "built $APP"
