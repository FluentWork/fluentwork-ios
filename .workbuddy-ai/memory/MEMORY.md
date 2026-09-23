# MEMORY.md — fluentwork-ios 项目长期约定

> 权威来源是仓库里的 `AGENTS.md`。这里只记「容易踩、且跨会话会重复用到」的。

## 硬性纪律（`AGENTS.md`）

1. **代码默认不写注释**（Local Rule #10，2026-09-23 加）。只有 Tango 明确指出「这里需要注释」
   才写；否则新代码与改动的代码一律不加注释（含文档注释、头部块、行内理由）。**推理写进
   `docs/` 的编号实现说明**，不写在代码旁。已存在的注释不动，规则只向前生效。
2. **一次一张票**（Local Rule #6）。不并发实施多个计划中的任务。
3. **跨仓必须串行**（Local Rule #7）：在 `fluentwork-backend` 与 `fluentwork-ios` 之间，
   先在一侧完成并验证，再动另一侧。
4. **开发在 `main` 上，`--ff-only`，不开 PR**（Local Rule #8）。注意远端 `main` 的分支保护
   要求 PR + 3 项状态检查，与这条冲突——每次推送都报 `Bypassed rule violations`，
   **待仓库管理员处理**（见 `docs/70_tts_wss_refactor/25_` §5）。
5. **落地门禁三项**：host Debug build + `swift test` + 一份编号实现说明，**三者一起提交**。
6. **缺陷修复纪律**：每个修复从一条会失败的测试开始；实现说明的测试节**必须逐字引用
   改动前的失败输出**，不能转述。三条例外（新能力 / 只能真机 / 确实不可自动化）
   必须在说明里写明用了哪一条。
7. **禁用 `NSLock` / `NSRecursiveLock`**。用 actor 隔离或 `OSAllocatedUnfairLock`。

## 本机环境（会反复踩）

1. **`swift build` / `swift test` 必须加 `--disable-sandbox`**，否则 `sandbox_apply: Operation not permitted`。
2. **Bash 工具环境里 `USER` 未设置**（`LOGNAME=root`，但 `whoami` 返回 `tango`）。
   读 `USER` 的 CLI 会挂（已知 XcodeGen 报 `Couldn't find current username` 且静默不生成工程）。
   解法：`USER=$(id -un)` 前缀。
3. **裸 `swiftc` 编译带宏的 SwiftUI 代码必然失败**。要验证 SwiftUI 行为必须走 SPM。
4. **同一文件的多次编辑必须串行。** 同一条消息里对同一文件发多个 Edit，两次都回「成功」，
   但**只有后一次落盘**。不同文件可并发；改完必须 grep 复核，**不要相信「成功」回执**。

## 语音链路的关键事实（改这块之前先读）

- `SpeechSessionMachine` 是纯状态机，零 IO。**没有 phase→`.idle` 的迁移**——`.enterRoom`
   重置 `state.session = .initial`，是回 `.idle` 的唯一路径。
- `SpeechSessionMiddleware` 里有两个泵：`audioEventPump`（上行）与 `transportEventPump`（下行）。
   两个都由 `OnceFlag` 保证**每进程只起一次**，**且都属于引擎/传输层，不属于会话**——
   `endSession` 刻意不取消它们。**任何 `return nil` 出泵循环都是缺陷**（已撞到 D14、D15 两次）。
- `SpeechCaptureGate` 是「这一段 PCM 该不该上行」的唯一权威。关闭入口只有 `endSpeech()`
  与 `abort()`。`takeForwardDecision()` 在拒绝时**计数**，所以关闸本身就是抑制器。
- 二进制音频帧：`[4B 大端 sequence] + payload`，**没有 `turn_id`**（这就是 D7 与 Stage 3）。
- 埋点是**字符串字面量**，不是符号——改名或删键编译通过、测试全绿，而真机日志里那行没了。
  `70_/24_` 已为上行 11 条建断言。

## 复盘习惯

- 修完一处缺陷，**grep 同形状的兄弟**（D14 修完，同文件里还有 3 处逐字同形）。
- **数完数字，再问「命中的是不是都算数，没命中的是不是都不算数」**——两头都要问。
  本仓已三次同错：注释被多算、多行调用被少算、按前缀扫一族漏掉不共享前缀的成员。
