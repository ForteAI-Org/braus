#!/bin/bash
#
#  build.sh
#  Braus
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
#
# Builds the standalone fixture without changing the package or an Xcode project.
set -euo pipefail
if [ "$#" -ne 1 ]; then
    echo 'usage: build.sh <outdir>' >&2
    exit 2
fi
source_dir="$(cd "$(dirname "$0")" && pwd)"
app="$1/CanvasFixture.app"
mkdir -p "$app/Contents/MacOS"
/usr/bin/swiftc -parse-as-library -target "$(uname -m)-apple-macosx15.0" \
    "$source_dir/CanvasFixture.swift" -o "$app/Contents/MacOS/CanvasFixture"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.braus.fixture.canvas</string>
<key>CFBundleName</key><string>CanvasFixture</string>
<key>CFBundleExecutable</key><string>CanvasFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app"
echo "$app"
