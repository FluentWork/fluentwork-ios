# T-I21-4 相位转换 label 埋点

**票**：I21 T-I21-4
**状态**：已落地。

## 1. 要守住的原理

转换埋点继续走 `speech_session_transition`（`container.tracker()`），不引入 `Tracker.shared.log("state.transition")`。

`from` / `to` 仍是 `rawValue`，避免把现有 `connecting` / `aiSpeaking` 看板冲掉。新增 `from_label` / `to_label` 用 `SpeechSessionPhase.label`（snake_case stage 名），新等待态是 `waiting_for_ai_answer` / `waiting_for_evaluation`。

## 2. 根因

T-I21-2 的 hop 若只报 camelCase rawValue，和 backend `stage` 对不齐。

## 3. 方案

`interpretSpeechSessionSideEffect(.trackTransition)` 同时写 rawValue 和 label。机器侧仍只发 `.trackTransition` 副作用。

## 4. 为何不折进现有路径

不改事件名。不把 label 覆盖 `from`/`to`。

## 5. 影响面

tracker 属性多两列。状态 / 音频 / 协议不变。

## 6. 测试

`swift test --filter "recordingTimeoutEmitsTurnTimeoutAndOutcome|transitionTelemetryEmittedOnPhaseChange"`
