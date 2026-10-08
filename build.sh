#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) HapTick.app in build/.
#   ./build.sh            build only
#   ./build.sh --install  also copy to ~/Applications and launch
#   ./build.sh --zip      also create build/HapTick.zip for a release
#
# Signing: uses the keychain identity named by $SIGN_IDENTITY (default
# "HapTick Local Signing") if present, otherwise ad-hoc. A stable identity keeps
# the Accessibility permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/HapTick.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

for ARCH in arm64 x86_64; do
    swiftc -O -parse-as-library -target $ARCH-apple-macos13 -o build/HapTick-$ARCH HapTick.swift
done
lipo -create -output "$APP/Contents/MacOS/HapTick" build/HapTick-arm64 build/HapTick-x86_64
rm build/HapTick-arm64 build/HapTick-x86_64

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>HapTick</string>
  <key>CFBundleDisplayName</key><string>HapTick</string>
  <key>CFBundleIdentifier</key><string>io.github.db1713.HapTick</string>
  <key>CFBundleExecutable</key><string>HapTick</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

NAME=${SIGN_IDENTITY:-HapTick Local Signing}
IDENTITY=$(security find-identity -p codesigning | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
[[ -n $IDENTITY ]] && echo "Built $APP (signed with $NAME)" || echo "Built $APP (ad-hoc signed)"

for arg in "$@"; do
    case $arg in
    --install)
        pkill -x HapTick 2>/dev/null || true
        rm -rf ~/Applications/HapTick.app
        cp -R "$APP" ~/Applications/
        open ~/Applications/HapTick.app
        echo "Installed ~/Applications/HapTick.app" ;;
    --zip)
        ditto -c -k --keepParent "$APP" build/HapTick.zip
        echo "Created build/HapTick.zip" ;;
    esac
done
