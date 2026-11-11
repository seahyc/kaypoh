#!/bin/sh
# Build Agent Notify.app (ad-hoc signed, no Dock icon) into $APP_DIR, by default
# ~/.local/libexec/agent-notify. Needs the Xcode Command Line Tools (swiftc).
# Rerun after editing main.swift. The first notification asks macOS for permission once.
set -eu
src="$(cd "$(dirname "$0")" && pwd)"
app_dir="${APP_DIR:-$HOME/.local/libexec/agent-notify}"
app="$app_dir/Agent Notify.app"
version="$(cat "$src/VERSION")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
contents="$tmp/Agent Notify.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
swiftc -O "$src/main.swift" -o "$contents/MacOS/agent-notify" -framework Cocoa -framework UserNotifications
# Icon: draw at 1024 px, then every size macOS asks for.
mkdir -p "$tmp/AgentNotifyIcon.iconset"
swift "$src/icon.swift" "$tmp/icon.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$tmp/AgentNotifyIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AgentNotifyIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AgentNotifyIcon.iconset" -o "$contents/Resources/AgentNotifyIcon.icns"
# Newer macOS prefers a compiled asset catalog (Assets.car). actool comes with full Xcode only;
# without it the .icns above is used.
if xcrun --find actool >/dev/null 2>&1; then
  set_dir="$tmp/Assets.xcassets/AgentNotifyIcon.appiconset"
  mkdir -p "$set_dir"
  images=""
  for s in 16 32 128 256 512; do
    for scale in 1 2; do
      px=$((s * scale))
      sips -z $px $px "$tmp/icon.png" --out "$set_dir/icon_${s}@${scale}x.png" >/dev/null
      images="$images{\"idiom\":\"mac\",\"size\":\"${s}x${s}\",\"scale\":\"${scale}x\",\"filename\":\"icon_${s}@${scale}x.png\"},"
    done
  done
  printf '{"images":[%s],"info":{"version":1,"author":"xcode"}}' "${images%,}" > "$set_dir/Contents.json"
  printf '{"info":{"version":1,"author":"xcode"}}' > "$tmp/Assets.xcassets/Contents.json"
  xcrun actool "$tmp/Assets.xcassets" --compile "$contents/Resources" --platform macosx \
    --minimum-deployment-target 13.0 --app-icon AgentNotifyIcon --output-partial-info-plist "$tmp/assets.plist" >/dev/null
fi
# One emoji badge per kind of notice, the system sounds the kinds use, and the persona packs.
swift "$src/badges.swift" "$contents/Resources/badges" >/dev/null
for snd in Pop Hero Glass Submarine Purr Ping Basso Tink; do
  cp "/System/Library/Sounds/$snd.aiff" "$contents/Resources/"
done
mkdir -p "$contents/Resources/personas"
cp "$src"/personas/*.json "$contents/Resources/personas/"
cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.seahyc.agent-notify</string>
  <key>CFBundleName</key><string>Agent Notify</string>
  <key>CFBundleDisplayName</key><string>Agent Notify</string>
  <key>CFBundleExecutable</key><string>agent-notify</string>
  <key>CFBundleIconFile</key><string>AgentNotifyIcon</string>
  <key>CFBundleIconName</key><string>AgentNotifyIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>LSUIElement</key><true/>
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
  <key>NSAppleEventsUsageDescription</key><string>Clicking a notice brings the iTerm2 tab and pane it came from to the front.</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$tmp/Agent Notify.app"
mkdir -p "$app_dir"
rm -rf "$app"
mv "$tmp/Agent Notify.app" "$app"
# Test builds (NO_REGISTER=1) stay unregistered, so a click never relaunches a stray copy.
[ -n "${NO_REGISTER:-}" ] || /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" || true
echo "$app"
