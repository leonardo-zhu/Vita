#!/bin/zsh
# 把当前代码构建并装到连着的 iPhone 上，然后打开 Vita。
# 免费开发者证书签的包 7 天后过期，过期后重跑一次即可（数据不会丢）。
#
# 用法：ios/scripts/install-iphone.sh            自动选第一台已配对的真机
#       DEVICE=<UDID 或名字> ios/scripts/install-iphone.sh
#
# 手机要已和这台 Mac 配对（同一 Wi-Fi 或数据线），并开着开发者模式。
set -euo pipefail

ios_dir=${0:A:h:h}
derived="$ios_dir/build/DerivedData"

device=${DEVICE:-}
if [[ -z $device ]]; then
  device=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c '
import json, sys
devices = json.load(sys.stdin)["result"]["devices"]
phones = [d for d in devices if d["hardwareProperties"].get("reality") == "physical"
          and d["hardwareProperties"].get("platform") == "iOS"
          and d["connectionProperties"].get("pairingState") == "paired"]
print(phones[0]["hardwareProperties"]["udid"] if phones else "")
')
fi
if [[ -z $device ]]; then
  echo "没找到已配对的 iPhone：用数据线连上，或确认手机和 Mac 在同一 Wi-Fi 且已信任这台电脑。" >&2
  exit 1
fi

if [[ -n $(git -C "$ios_dir" status --porcelain -- . ../shared) ]]; then
  echo "提示：有未提交的改动，装上的版本号会带 +。"
fi

echo "==> 生成 Xcode 工程"
(cd "$ios_dir" && xcodegen generate --quiet)

echo "==> 构建（设备 $device）"
xcodebuild -project "$ios_dir/Vita.xcodeproj" -scheme Vita -configuration Debug \
  -destination "id=$device" -derivedDataPath "$derived" -allowProvisioningUpdates \
  -quiet build

app="$derived/Build/Products/Debug-iphoneos/Vita.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Info.plist")
commit=$(/usr/libexec/PlistBuddy -c "Print :VitaGitCommit" "$app/Info.plist")

echo "==> 安装 $version ($build · $commit)"
xcrun devicectl device install app --device "$device" "$app" >/dev/null

echo "==> 打开 Vita"
if ! xcrun devicectl device process launch --device "$device" --terminate-existing com.leonardo.vita >/dev/null 2>&1; then
  echo "已装好，但手机锁着没能自动打开，解锁后手动打开即可。"
  exit 0
fi
echo "完成。"
