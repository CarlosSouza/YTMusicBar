#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/ytmusicbar-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/ytmusicbar-modules"

build_path="${TMPDIR:-/tmp}/ytmusicbar-build"
cache_path="${TMPDIR:-/tmp}/ytmusicbar-cache"

swift build \
    --product YTMusicBar \
    -c release \
    -debug-info-format none \
    --scratch-path "$build_path" \
    --cache-path "$cache_path" \
    --disable-sandbox

binary_dir="$(swift build \
    --product YTMusicBar \
    -c release \
    -debug-info-format none \
    --scratch-path "$build_path" \
    --cache-path "$cache_path" \
    --disable-sandbox \
    --show-bin-path)"

YTMUSICBAR_VALIDATE_LOCAL=1 "$binary_dir/YTMusicBar"

if [[ -x .ytmusic-venv/bin/python ]]; then
    .ytmusic-venv/bin/python scripts/ytmusic_bridge.py --selftest
fi

app_path="$PWD/dist/YTMusicBar.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if [[ -e "$app_path/Contents/Resources/.ytmusic-venv" ]]; then
    mv "$app_path/Contents/Resources/.ytmusic-venv" "${TMPDIR:-/tmp}/ytmusicbar-stale-venv-$$"
fi
cp "$binary_dir/YTMusicBar" "$app_path/Contents/MacOS/YTMusicBar"
# SwiftPM stamps the deployment target as the SDK version; without the real SDK
# macOS runs the app in compatibility mode (no Liquid Glass). Must run before codesign.
binary="$app_path/Contents/MacOS/YTMusicBar"
minos="$(xcrun vtool -show-build "$binary" | awk '/minos/{print $2}')"
xcrun vtool -set-build-version macos "$minos" "$(xcrun --show-sdk-version)" -replace -output "$binary" "$binary"
cp README.md "$app_path/Contents/Resources/README.md"
cp Assets/YTMusicBar.png "$app_path/Contents/Resources/YTMusicBar.png"
cp scripts/ytmusic_bridge.py "$app_path/Contents/Resources/ytmusic_bridge.py"
cp scripts/ytmusic_auth.py "$app_path/Contents/Resources/ytmusic_auth.py"
site_packages_dir="$(find .ytmusic-venv/lib -type d -name site-packages -print -quit 2>/dev/null || true)"
if [[ -n "$site_packages_dir" ]]; then
    cp -R "$site_packages_dir" "$app_path/Contents/Resources/ytmusic-site-packages"
fi

cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>YTMusicBar</string>
    <key>CFBundleIdentifier</key><string>local.ytmusicbar</string>
    <key>CFBundleName</key><string>YTMusicBar</string>
    <key>CFBundleDisplayName</key><string>YTMusicBar</string>
    <key>CFBundleIconFile</key><string>YTMusicBar.png</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app_path"
printf 'App criado: %s\n' "$app_path"
