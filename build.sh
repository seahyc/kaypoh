#!/bin/sh
# Build Agent Notify.app into ~/.local/libexec/agent-notify (ad-hoc signed, no Dock icon).
# Rerun after editing main.swift. The first notification asks macOS for permission once.
set -eu
src="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/.local/libexec/agent-notify/Agent Notify.app"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Agent Notify.app/Contents/MacOS"
swiftc -O "$src/main.swift" -o "$tmp/Agent Notify.app/Contents/MacOS/agent-notify" -framework Cocoa -framework UserNotifications
# Icon: draw at 1024 px, then every size macOS asks for.
mkdir -p "$tmp/Agent Notify.app/Contents/Resources" "$tmp/AppIcon.iconset"
swift "$src/icon.swift" "$tmp/icon.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o "$tmp/Agent Notify.app/Contents/Resources/AppIcon.icns"
cat > "$tmp/Agent Notify.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.agents.notify</string>
  <key>CFBundleName</key><string>Agent Notify</string>
  <key>CFBundleDisplayName</key><string>Agent Notify</string>
  <key>CFBundleExecutable</key><string>agent-notify</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$tmp/Agent Notify.app"
mkdir -p "$(dirname "$app")"
rm -rf "$app"
mv "$tmp/Agent Notify.app" "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"
