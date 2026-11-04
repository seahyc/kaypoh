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
mkdir -p "$tmp/Agent Notify.app/Contents/Resources" "$tmp/AgentNotifyIcon.iconset"
swift "$src/icon.swift" "$tmp/icon.png" >/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon.png" --out "$tmp/AgentNotifyIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$tmp/icon.png" --out "$tmp/AgentNotifyIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AgentNotifyIcon.iconset" -o "$tmp/Agent Notify.app/Contents/Resources/AgentNotifyIcon.icns"
# Newer macOS reads the icon from a compiled asset catalog (Assets.car); the .icns is the fallback.
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
xcrun actool "$tmp/Assets.xcassets" --compile "$tmp/Agent Notify.app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AgentNotifyIcon --output-partial-info-plist "$tmp/assets.plist" >/dev/null
# One emoji badge per kind of notice, and the system sounds the kinds use.
swift "$src/badges.swift" "$tmp/Agent Notify.app/Contents/Resources/badges" >/dev/null
for snd in Pop Hero Glass Submarine Purr Ping Basso Tink; do
  cp "/System/Library/Sounds/$snd.aiff" "$tmp/Agent Notify.app/Contents/Resources/"
done
cat > "$tmp/Agent Notify.app/Contents/Info.plist" <<'PLIST'
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
  <key>CFBundleVersion</key><string>5</string>
  <key>CFBundleShortVersionString</key><string>5.0</string>
  <key>LSUIElement</key><true/>
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
  <key>NSAppleEventsUsageDescription</key><string>Clicking a notice brings the iTerm2 tab and pane it came from to the front.</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$tmp/Agent Notify.app"
mkdir -p "$(dirname "$app")"
rm -rf "$app"
mv "$tmp/Agent Notify.app" "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "$app"
