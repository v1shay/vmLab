#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="${VMLAB_BUILD_APP:-$PWD/build/vmLab.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
crypto=${VMLAB_OPENSSL_PREFIX:-$(brew --prefix openssl@3)}
objects=$(mktemp -d)
trap 'rm -rf "$objects"' EXIT
clang -arch arm64 -mmacosx-version-min=14.0 -I"$crypto/include" -c Support/AppleDH.c -o "$objects/AppleDH.o"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 Sources/*.swift "$objects/AppleDH.o" "$crypto/lib/libcrypto.a" -o "$app/Contents/MacOS/vmLab"
xcrun -sdk macosx metal -c Sources/Wallpaper.metal -o "$objects/Wallpaper.air"
mkdir -p "$app/Contents/Resources"
xcrun -sdk macosx metallib "$objects/Wallpaper.air" -o "$app/Contents/Resources/Wallpaper.metallib"
cp "$app/Contents/MacOS/vmLab" "$app/Contents/Helpers/vmlab"
ditto Resources "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>vmLab</string>
<key>CFBundleIdentifier</key><string>local.vishay.vmlab</string>
<key>CFBundleIconFile</key><string>vmLab.icns</string>
<key>CFBundleName</key><string>vmLab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>48</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Discover Macs on your local network and connect to remote displays.</string>
<key>NSBonjourServices</key><array><string>_rfb._tcp.</string></array>

</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Helpers/vmlab"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
