#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"

if [[ ! -f data/neurons.bin || ! -f data/synapses.bin ]]; then
  print -u2 '연결 데이터가 없습니다. 먼저 python3 scripts/fetch-data.py 를 실행하세요.'
  exit 1
fi
swift build -c release
app_dir="$project_root/dist/NeuroFly.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/data"
cp .build/release/NeuroFly "$app_dir/Contents/MacOS/NeuroFly"
cp -R .build/release/NeuroFly_NeuroFlyCore.bundle "$app_dir/Contents/Resources/"
# The signed app loads its own kernel first, without SwiftPM's absolute build-path fallback.
cp Sources/NeuroFlyCore/Resources/LIF.metal "$app_dir/Contents/Resources/LIF.metal"
cp data/connectome.json data/neurons.bin data/synapses.bin data/DATA_LICENSE.md "$app_dir/Contents/Resources/data/"
cp ThirdParty/SiliconFly-LICENSE "$app_dir/Contents/Resources/"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>NeuroFly</string>
  <key>CFBundleIdentifier</key><string>local.neurofly.desktop</string>
  <key>CFBundleName</key><string>NeuroFly</string>
  <key>CFBundleDisplayName</key><string>NeuroFly</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app_dir"
print "앱 생성 완료: $app_dir"
