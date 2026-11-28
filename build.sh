#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/MacPulse.app"
build="$PWD/.build"
stage="$build/stage/MacPulse.app"
mkdir -p "$build/module-cache" "$stage/Contents/MacOS" "$stage/Contents/Resources"
cat > "$stage/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacPulse</string>
    <key>CFBundleIdentifier</key><string>local.macpulse.desktop</string>
    <key>CFBundleDisplayName</key><string>Mac 脉搏</string>
    <key>CFBundleName</key><string>Mac 脉搏</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.9.2</string>
    <key>CFBundleVersion</key><string>15</string>
    <key>CFBundleIconFile</key><string>MacPulse</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
xcrun clang -mmacosx-version-min=14.0 -O2 -Wall -Wextra -c Sources/Probe.c -o "$build/Probe.o"
xcrun clang -mmacosx-version-min=14.0 -O2 -Wall -Wextra -c Sources/PrivacyProbe.c -o "$build/PrivacyProbe.o"
xcrun clang -mmacosx-version-min=14.0 -O2 -Wall -Wextra -c Sources/TaskProbe.c -o "$build/TaskProbe.o"
xcrun swiftc -target arm64-apple-macos14 -O -module-cache-path "$build/module-cache" -import-objc-header Sources/Probe.h Sources/Monitor.swift Sources/ProcessTasks.swift Sources/Diagnosis.swift Sources/Advice.swift Sources/Orb.swift Sources/SoftwareUpdate.swift Sources/ApplicationActions.swift Sources/ApplicationList.swift Sources/Privacy.swift Sources/PrivacyView.swift Sources/App.swift "$build/Probe.o" "$build/PrivacyProbe.o" "$build/TaskProbe.o" -framework IOKit -framework CoreAudio -framework CoreMediaIO -o "$stage/Contents/MacOS/MacPulse"
xcrun swiftc -target arm64-apple-macos14 -module-cache-path "$build/module-cache" tools/Icon.swift -o "$build/MakeIcon"
"$build/MakeIcon" "$stage/Contents/Resources/MacPulse.icns"
plutil -lint "$stage/Contents/Info.plist"
codesign --force --sign - "$stage"
codesign --verify --strict "$stage"
if [[ -d "$app" ]]; then
    backup="$build/MacPulse.previous.$$"
    mv "$app" "$backup"
    if mv "$stage" "$app"; then
        rm -rf "$backup"
    else
        mv "$backup" "$app"
        exit 1
    fi
else
    mv "$stage" "$app"
fi
printf 'Built %s\n' "$app"
