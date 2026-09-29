#!/usr/bin/env bash
# 真机冒烟：构建 → 安装 → 启动 → 采日志（F6 的验收腿；现有 smoke 只跑模拟器）。
#
# ## 这个脚本证明什么、不证明什么
#
# **证明**：
#   1. 新代码能在**真 SDK**（iPhoneOS arm64）上编译 —— 这一条腿 1 做不到：
#      macOS 的 `swift build` 会把 `#if os(iOS)` 整段编译掉，F6 的三个错误
#      （`CategoryOptions` 里混进 `setActive` 的选项、`Category(rawValue:)` 不是
#      failable）就是这样从腿 1 漏过去的，只有腿 2 抓到；
#   2. 应用能在真机上安装并启动，且 `[Tracker]` 遥测能被采到（stdout 经 `--console`）。
#
# **不证明**：
#   - barge-in 与断线重连（`iOS-S0-3`，需要一次 >5 秒的回复）。
#
# ## `SCENARIO` 与替身的**边界**（别再让这两件事互相打脸）
#
# 替身模式（`FW_MOCK_MIC=1`，本脚本默认开）下，房间认领的是 **`.playback`**
# （`MockAudioEngine.startCapture` 刻意不走 record 路径 —— 否则系统会全程显示麦克风在用）。
# 所以驱动里「采集开始后类别必须是 `playAndRecord`」那条判据**在替身模式下不可能成立**，
# 它现在按 `MockDeviceMode` 推导期望的路线（`AudioRoute`），两种模式都自洽。
# 要验生产那条 `.playAndRecord`，把 `FW_MOCK_MIC` 关掉跑（那就需要有人对着手机说话）。
#
# 驱动的第 ③ 步派的是 `.sessionStartTap`（=「开始 / 重新开始」按钮），**能自己起会话** ——
# 它以前派的是 `.manualSpeechBegin`，于是永远停在 `.idle`，而判据还把这件事报成
# 「30 秒内没有进入采集」。那次 FAIL 的根因是派 action 的人，不是被测对象。
#
# 用法：
#   Scripts/smoke-device.sh                 # 默认 60 秒观察窗（只验「能起来」）
#   SCENARIO=room+daily Scripts/smoke-device.sh
#                                           # 驱动一个完整场景并验 F6 的两条判据
#   WINDOW_SECONDS=120 Scripts/smoke-device.sh
#
# 可覆盖：DEVICE_UDID / BUNDLE_ID / SCHEME / PROJECT / DERIVED_DATA / LOG_DIR / WINDOW_SECONDS / SCENARIO
#
# ## SCENARIO 为什么能替掉「模拟点击」
#
# 这个界面是 Redux 的：**store 是唯一真源**，会话/音频链路是**动作驱动**的，不是像素驱动的。
# 所以「起一个会话、再同时播每日一读」可以照视图派同样的 action 完成
# （`DeviceScenarioDriver` 逐条标了抄自 HostRootView 哪一行），然后读 state 与真实
# `AVAudioSession` —— 不需要点屏幕。没设 SCENARIO 时那段代码一个字节都不执行。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEVICE_UDID="${DEVICE_UDID:-00008140-000A288836FB001C}"
BUNDLE_ID="${BUNDLE_ID:-com.fluentwork.host}"
SCHEME="${SCHEME:-FluentWorkHost}"
PROJECT="${PROJECT:-FluentWorkHost.xcodeproj}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/.derivedData/device}"
LOG_DIR="${LOG_DIR:-$ROOT/.tmp/smoke-device}"
WINDOW_SECONDS="${WINDOW_SECONDS:-60}"
SCENARIO="${SCENARIO:-}"

mkdir -p "$LOG_DIR"
BUILD_LOG="$LOG_DIR/xcodebuild-build.log"
CONSOLE_LOG="$LOG_DIR/console.log"

fail() {
  echo "SMOKE DEVICE FAILED: $1" >&2
  exit 1
}

echo "== 0/4 确认设备在线"
DEVICES="$(xcrun devicectl list devices 2>&1)"
if ! printf '%s\n' "$DEVICES" | grep -q "$DEVICE_UDID"; then
  fail "设备不在列表里（UDID=${DEVICE_UDID}）：请插上并解锁"
fi
if ! printf '%s\n' "$DEVICES" | grep -E "$DEVICE_UDID.*connected" >/dev/null; then
  printf '%s\n' "$DEVICES" | grep "$DEVICE_UDID" >&2
  fail "设备存在但不是 connected 状态"
fi
echo "  device=$DEVICE_UDID"

echo "== 1/4 构建（真 SDK / arm64）"
# 三个反嵌套沙箱开关与落地门禁腿 2 同一理由（见 Scripts/gate.sh 的注释）。
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "id=$DEVICE_UDID" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  -IDEPackageSupportDisableManifestSandbox=1 \
  -IDEPackageSupportDisablePluginExecutionSandbox=1 \
  OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
  -allowProvisioningUpdates \
  build >"$BUILD_LOG" 2>&1
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$BUILD_LOG"; then
  grep -nE "error:" "$BUILD_LOG" | head -20 >&2
  fail "构建失败（日志 ${BUILD_LOG}）"
fi
ERRORS="$(grep -cE "error:" "$BUILD_LOG")"
echo "  build succeeded, error count=$ERRORS"

APP_PATH="$(find "$DERIVED_DATA/Build/Products" -maxdepth 2 -type d -name "$SCHEME.app" 2>/dev/null | head -1)"
[ -n "$APP_PATH" ] || fail "找不到 $SCHEME.app（${DERIVED_DATA}）"
echo "  app=$APP_PATH"

echo "== 2/4 安装"
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP_PATH" >"$LOG_DIR/install.log" 2>&1 ||
  { tail -20 "$LOG_DIR/install.log" >&2; fail "安装失败"; }
echo "  installed $BUNDLE_ID"

echo "== 3/4 启动并采 $WINDOW_SECONDS 秒日志"
# `FW_MOCK_MIC`：麦克风的 DEBUG 替身（真机联调用它，不必有人对着手机说话）。
# 播放仍走真的 `LiveAudioEngine` —— 也就是 barge-in 那条路径没有被替掉。
# 注意：mock 只在**采集开始之后**才说话，而采集需要一个点击（tap-to-talk 是主路径），
# 所以下面这段日志目前只覆盖启动与 bootstrap。
LAUNCH_ENV="{\"FW_MOCK_MIC\":\"1\",\"FW_MOCK_MIC_AUTO_MS\":\"4000\""
if [ -n "$SCENARIO" ]; then
  LAUNCH_ENV="$LAUNCH_ENV,\"FW_SCENARIO\":\"$SCENARIO\""
fi
LAUNCH_ENV="$LAUNCH_ENV}"
xcrun devicectl device process launch \
  --console --terminate-existing \
  -e "$LAUNCH_ENV" \
  --device "$DEVICE_UDID" "$BUNDLE_ID" >"$CONSOLE_LOG" 2>&1 &
LAUNCH_PID=$!

sleep "$WINDOW_SECONDS"
kill "$LAUNCH_PID" 2>/dev/null
wait "$LAUNCH_PID" 2>/dev/null

echo "== 4/4 结果"
TRACKER_LINES="$(grep -c '\[Tracker\]' "$CONSOLE_LOG" 2>/dev/null || echo 0)"
echo "  console lines: $(wc -l <"$CONSOLE_LOG" | tr -d ' ')"
echo "  tracker lines: $TRACKER_LINES"

if [ "$TRACKER_LINES" -eq 0 ]; then
  tail -20 "$CONSOLE_LOG" >&2
  fail "应用启动了但一条 [Tracker] 都没有 —— 它没跑到自己的启动路径（日志 ${CONSOLE_LOG}）"
fi

echo "  遥测（前若干条）："
grep -oE '\[Tracker\] [a-z_.]+' "$CONSOLE_LOG" | sort | uniq -c | sort -rn | head -12 | sed 's/^/    /'

if [ -n "$SCENARIO" ]; then
  echo
  echo "  == 场景 $SCENARIO 的观测 =="
  grep -E '\[Scenario\]' "$CONSOLE_LOG" | sed 's/^/    /' || true
  VERDICT="$(grep -oE '\[Scenario\] verdict=[A-Z]+' "$CONSOLE_LOG" | tail -1 | sed 's/.*verdict=//')"
  if [ -z "$VERDICT" ]; then
    fail "场景 $SCENARIO 没有给出 verdict（应用可能没跑到驱动，或没设进环境变量）"
  fi
  if [ "$VERDICT" != "PASS" ]; then
    grep -oE 'reasons=.*' "$CONSOLE_LOG" | tail -1 >&2
    fail "场景 $SCENARIO verdict=$VERDICT"
  fi
  echo "    verdict=PASS"
fi

echo
echo "=== 真机冒烟 PASS（这一半）==="
echo "device: $DEVICE_UDID"
echo "logs:   $LOG_DIR"
echo "checklist:"
echo "  [x] 真 SDK（arm64）构建成功，error 计数 $ERRORS"
echo "  [x] 安装成功"
echo "  [x] 启动成功且产出 [Tracker] 遥测"
if [ -n "$SCENARIO" ]; then
  echo "  [x] 会话类别真的落到系统（场景驱动，见上面 session@after-capture-start）"
  echo "  [x] 房间 + 每日一读并存（场景驱动，见 session@after-daily-read-play）"
else
  echo "  [ ] 会话类别真的落到系统 —— 用 SCENARIO=room 跑"
  echo "  [ ] 房间 + 每日一读并存 —— 用 SCENARIO=room+daily 跑"
fi
echo "  [ ] barge-in / 断线重连（iOS-S0-3，需一次 >5 秒的回复）"
