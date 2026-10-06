#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"

./scripts/build-app.sh
app_dir="$project_root/dist/NeuroFly.app"
codesign --verify --deep --strict "$app_dir"

release_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_dir/Contents/Info.plist")
release_arch=$(lipo -archs "$app_dir/Contents/MacOS/NeuroFly")
if [[ ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' || "$release_arch" != arm64 ]]; then
  print -u2 '이 배포 스크립트는 숫자 버전의 Apple Silicon(arm64) 앱을 요구합니다.'
  exit 1
fi

release_name="NeuroFly-${release_version}-macos-${release_arch}"
release_archive="$project_root/dist/${release_name}.zip"
staging_root=$(mktemp -d "$project_root/dist/release-stage.XXXXXX")
trap 'rm -rf "$staging_root"' EXIT
package_dir="$staging_root/$release_name"
mkdir -p "$package_dir/Licenses"
ditto "$app_dir" "$package_dir/NeuroFly.app"
cp docs/install.md "$package_dir/INSTALL.md"
cp data/DATA_LICENSE.md "$package_dir/Licenses/FlyWire-DATA_LICENSE.md"
cp data/malecns/DATA_LICENSE.md "$package_dir/Licenses/MaleCNS-DATA_LICENSE.md"
cp ThirdParty/SiliconFly-LICENSE "$package_dir/Licenses/SiliconFly-LICENSE"
codesign --verify --deep --strict "$package_dir/NeuroFly.app"

# ditto preserves executable permissions, bundle structure and macOS metadata.
ditto -c -k --sequesterRsrc --keepParent "$package_dir" "$release_archive"
(cd "$project_root/dist" && shasum -a 256 "${release_name}.zip" > "${release_name}.zip.sha256")
print "배포 ZIP 생성 완료: $release_archive"
