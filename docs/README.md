# docs 目录索引

本目录采用单一规则：

1. **主线文档**：放在 `docs/` 根目录，使用编号前缀维护阅读顺序
2. **目录索引**：保留 `docs/README.md` 作为阅读入口与命名规则说明

---

## 1. 当前主文档顺序

### 00-04：开发入口与架构基线

1. `00_开发入口与第一波范围.md`
2. `01_iOS技术架构审核与C0 Gap.md`
3. `02_iOS架构实现约定.md`
4. `03_iOS基础组件分析与引入清单.md`
5. `04_Bootstrap与导航导读.md`

### 05-09：阶段任务与运行手册

6. `05_第二波开发范围与任务清单.md`
7. `06_第一波iPhone17Pro_Smoke_Runbook.md`
8. `07_语料库本地优先同步策略定案.md`
9. `08_I7_review_视图集成踩坑说明.md`
10. `09_I10_smoke_test_runbook.md`

### 10-13：专项实现与联调

11. `10_I12_audio_engine_decoder_pitfalls.md`
12. `11_I13_iOS_backend_wss联调_runbook.md`
13. `12_mock_device_测试支持说明.md`
14. `13_ClientASR集成与使用指南.md`

### 14-19：Bootstrap / Auth / 启动性能 / 测试规范

15. `14_Bootstrap_Surface_使用指南.md`
16. `15_游客升级注册用户流程修复方案.md`
17. `16_Token刷新与错误处理方案.md`
18. `17_Bootstrap设计原理说明.md`
19. `18_启动性能优化与测量指南.md`
20. `19_测试分层与依赖隔离规范.md`

### 20+：专项与基线

21. `20_I20_voice_turn_boundary_pitfalls.md` — turn 边界历史踩坑
22. `23_iOS-arch-baseline-report_2026-09-09.md` — ISSUE-08 Instruments 程序；测量本身仍 pending
23. `24_voice_turn_timeout_contingency.md` — B15 70s 与 I20 `client.turn.abort` 双路径维护合同
24. `25_I20_turn_outcome.md` — T-I20-2 `TurnOutcome` 上报与 abort outcome 枚举
25. `26_I20_system_prompt_builder.md` — T-I20-3 `SystemPromptBuilder` V2.0
26. `27_I20_turn_telemetry.md` — T-I20-4 `turn.timeout` / `turn.outcome`、TTS 追踪日志；生产走 `Container.shared`，测试注入同一份本地 Container
27. `28_I21_session_phase_waits.md` — T-I21-1 `waitingForAIAnswer` / `waitingForEvaluation` 相位与 label
28. `29_I21_wait_phase_transitions.md` — T-I21-2 等待相位转换；B15 timeout 仍走 `.failed("turn_timeout")`
29. `30_I21_wait_phase_ui.md` — T-I21-3 等待相位 UI
30. `31_I21_transition_labels.md` — T-I21-4 `speech_session_transition` 的 from_label / to_label
31. `32_B15_ai_turn_end_timeout_joint_debug.md` — `ai.turn.end outcome=timeout` → `.failed("turn_timeout")` 联调
32. `33_I20_client_turn_abort_joint_debug.md` — `client.turn.abort` 网关接受后会话仍活
33. `34_I20_manual_speech_boundary.md` — I20 Item 4 手动开口主路径，自动 VAD 降级
34. `35_I20_trace_alignment_joint_debug.md` — I20 Item 3 `turn_id` + `log_id` 跨仓联调
35. `36_sync_lock_boxes.md` — `OSAllocatedUnfairLock` 同步盒子；按真实双写路径覆盖并发
36. `37_wait_phase_watchdog_and_failure_matrix.md` — abort 落点语义、评价 20s watchdog、重连丢 turn、路由重配
37. `38_wait_phase_update_analysis.md` — 本次收口的问题分析与图例（评审误判、死边、重连、badge 误清）
38. `IOS_ARCH_REVIEW_DONE.md` — ISSUES 01–07 PR 指针；ISSUE-08 等待 Instruments

---

## 2. 当前目录状态

当前 `docs/` 根目录只保留：

1. 编号主线文档
2. 本索引文件 `README.md`
3. 例外：`IOS_ARCH_REVIEW_DONE.md` 作为 ISSUE-01–08 的短状态指针（ISSUE-08 仍等待 Instruments）

不再保留其它无编号的阶段性工作文档、PR 材料、临时总结稿。

---

## 3. 新文档命名规则

### 放在根目录并作为主线的文档

必须满足两个条件：

1. 会长期作为团队参考
2. 属于主线架构、实现约定、runbook、专题指南之一

命名格式：

```text
NN_主题名.md
```

### 不应再新增的文档

以下类型不应再直接放进 `docs/` 根目录：

1. PR body / PR summary
2. implementation summary
3. working notes
4. 临时调查稿
5. 阶段性结项记录

---

## 4. 后续维护原则

1. 主线知识优先写入编号文档
2. 阶段材料不要新增到 `docs/` 根目录
3. 若已有主文档能承接，优先更新旧文档，不新增平行版本
4. 新增长期文档优先走编号命名
