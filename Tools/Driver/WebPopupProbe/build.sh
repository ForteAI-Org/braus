#!/bin/sh
# Builds WebPopupProbe.app from source and signs it ad hoc (an unsigned WKWebView host is killed with 137).
# Usage: build.sh [output-dir]   default: <repo>/.build/web-popup-probe
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$(cd "$here/../../.." && pwd)/.build/web-popup-probe}
app=$out/WebPopupProbe.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -O -swift-version 5 -o "$app/Contents/MacOS/WebPopupProbe" "$here"/*.swift
cp "$here/Info.plist" "$app/Contents/Info.plist"
cp "$here/probe.html" "$app/Contents/Resources/probe.html"
codesign --force --sign - "$app"
echo "$app"
