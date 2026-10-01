#!/usr/bin/env bash
# 把指定的几屏摆到模拟器上各截一张图（人眼走查用）。
#
# 用法：
#   ./Scripts/shoot-screens.sh createPractice corpus corpusEmpty
#
# 它做四件事：解析模拟器 → 装构建好的 Host → 用 `FW_SCREEN=<name>` 逐个重启并截图 → 存档。
# 截图落在 `.design-shots/`（**在 .gitignore 里**）：它们是每次都会变的产物，不进版本库。
#
# 为什么要有这个脚本：`docs/design/ui-walkthrough/` 里那些「闪光真的在闪吗」「间距对不对」
# 的问题，判据答不了，只能靠一张图。把「怎么弄出这张图」写成一个命令，走查才不会因为麻烦而跳过。
#
# 前置：先为这台模拟器构建一次（脚本会在缺产物时报错并给出命令）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVICE_NAME="${SIMULATOR_NAME:-iPhone 18 Pro}"
BUNDLE_ID="${BUNDLE_ID:-com.fluentwork.host}"
SCHEME="${SCHEME:-FluentWorkHost}"
PROJECT="${PROJECT:-FluentWorkHost.xcodeproj}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.derivedData/shots}"
OUT_DIR="${OUT_DIR:-$ROOT/.design-shots}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"

if [[ $# -eq 0 ]]; then
  echo "用法: $0 <FW_SCREEN> [<FW_SCREEN> ...]" >&2
  echo "可用的屏见 Shared/FluentWorkCore/Debug/DebugScreenPreview.swift" >&2
  exit 1
fi

DEVICE_ID="$(
  xcrun simctl list devices available |
    awk -v name="$DEVICE_NAME" '
      $0 ~ name && $0 ~ /\(/ {
        if (match($0, /\(([A-F0-9-]{36})\)/)) {
          print substr($0, RSTART + 1, RLENGTH - 2); exit
        }
      }
    '
)"
if [[ -z "$DEVICE_ID" ]]; then
  echo "找不到模拟器：$DEVICE_NAME" >&2
  exit 1
fi

APP_PATH="$(find "$DERIVED_DATA/Build/Products" -type d -name 'FluentWorkHost.app' 2>/dev/null | head -n 1)"
if [[ -z "$APP_PATH" ]]; then
  cat >&2 <<EOF
没找到构建产物。先为这台模拟器构建一次：

  xcodebuild -project $PROJECT -scheme $SCHEME -configuration Debug \\
    -destination 'platform=iOS Simulator,id=$DEVICE_ID' \\
    -derivedDataPath "$DERIVED_DATA" \\
    -disableAutomaticPackageResolution \\
    -IDEPackageSupportDisableManifestSandbox=1 \\
    -IDEPackageSupportDisablePluginExecutionSandbox=1 \\
    OTHER_SWIFT_FLAGS='\$(inherited) -disable-sandbox' build
EOF
  exit 1
fi

xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null

mkdir -p "$OUT_DIR"
xcrun simctl uninstall "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE_ID" "$APP_PATH"
echo "模拟器: $DEVICE_NAME ($DEVICE_ID)"
echo "产物:   $APP_PATH"
echo "截图:   $OUT_DIR"
echo

for screen in "$@"; do
  xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  SIMCTL_CHILD_FW_SCREEN="$screen" xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID" >/dev/null
  # 等它起来并取一次数据。启动 → bootstrap → 首屏数据在真机上是几秒的事；
  # 这里宁可多等一会儿，也不要在半张页面上截图。
  sleep "$SETTLE_SECONDS"
  target="$OUT_DIR/$screen.png"
  xcrun simctl io "$DEVICE_ID" screenshot "$target" >/dev/null 2>&1
  echo "  ✓ $screen → $target"
done

xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
echo
echo "完成。截图目录已 gitignore（$(git check-ignore -v "$OUT_DIR" 2>/dev/null | head -1 || echo '（未确认）')）"
