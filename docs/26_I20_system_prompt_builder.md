# T-I20-3 SystemPromptBuilder V2.0

**票**：I20 T-I20-3
**状态**：已落地（纯组装）。B19 `recentHits` 拉取和 `session.start` 注入未做。

## 1. 要守住的原理

V2.0 system prompt 是三段可拼接文本，不是会话状态：

1. 调用方给的 `basePrompt`（原样保留）
2. 可选：最近命中过的 B7 话术块（最多 8 条）
3. 必有：用户水平 `beginner` / `intermediate` / `advanced`

组装必须是纯函数。SpeechSession 状态机、WSS、UserDefaults、网络都不进这个类型。

## 2. 根因

V1.x 已经有基础 system prompt 和命中检测，但 iOS 没有一个稳定的 V2.0 模板。hits 和 userLevel 若直接拼进 `session.start` 或写进状态机，会和音频、turn 边界缠在一起，也没法单独测「无 hits 不变形」。

B19 `recentHits` API 在本仓还不存在。本票不去发明 HTTP 客户端，也不改 `material_context` 线格式。

## 3. 方案

- `SystemPromptBuilder`：`Shared/FluentWorkCore/Prompt/SystemPromptBuilder.swift`
- `RecordedHit`：`intentZh` + `chunkEn`，可从 `PhraseBlock` 映射
- `UserLevel`：三个 rawValue，与 prompt 正文一致

规则：`recentHits` 从旧到新，builder 取最后 8 条且顺序不变。空数组不写命中标题，避免空段把 base prompt 撑变形。用户水平段始终追加。

## 4. 为何不折进现有路径

- 不放进 `SpeechSessionMachine`：prompt 不是 turn 相位
- 不改 `DefaultSpeechSessionClient.startSession`：当前只发 `scene: standup`
- 不在 builder 内读 UserDefaults 或打 B19：测试必须 hermetic（`docs/19`）

## 5. 影响面

状态 / 音频 / 协议无变化。后续 T-I20-4 做埋点；B19 有 API 后再把 hits 喂给 builder。

## 6. 测试

`swift test --filter SystemPromptBuilder`
