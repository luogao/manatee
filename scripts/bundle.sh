#!/usr/bin/env bash
# 打包成可双击运行的 .app（ad-hoc 签名，不需要开发者账号）
#
# 改名只用改两处：Sources/Manatee/PanelView.swift 的 AppInfo（name / slug）
# 和 Resources/Info.plist 的 CFBundleName/CFBundleExecutable。
# 这里通过 Info.plist 读名字，不再硬编码。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" Resources/Info.plist)
EXEC=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" Resources/Info.plist)
APP="build/$NAME.app"

swift build -c "$CONFIG"
# SPM 的产物名跟 target 名走（Package.swift 里是 Manatee），跟 Info.plist 无关，
# 所以这里按 target 名找，再拷成 EXEC 名。
BIN=".build/$CONFIG/Manatee"
[ -f "$BIN" ] || { echo "构建产物不存在: $BIN"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# 品牌图标（lobehub/icons 预渲染的 PNG）
if [ -d Resources/Icons ]; then
  cp -R Resources/Icons "$APP/Contents/Resources/Icons"
fi

codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "✓ $APP"
echo "  安装: cp -R \"$APP\" /Applications/ && open /Applications/$NAME.app"
