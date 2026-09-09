# iOS 系统生态整合层 · 性能/内存基线

**日期**: 2026-09-09
**代码基准**: stacked PRs #50–#55（ISSUE-01–07 + ISSUE-06 processing substages）
**设备目标**: iPhone 17 Pro Simulator（若本机没有则 iPhone 16 Simulator）
**测量状态**: **NOT RUN** in the agent session（没有 30 分钟 Instruments attach，也没有导出 Allocations / Leaks / Time Profiler 痕迹）

本报告只交付可重复跑测程序与诚实的 pending 门禁表。**没有填写任何测量数字。** 不要把下面的门禁阈值当成已通过结果。

相关 PR:

| ISSUE | PR | 内容 |
|---|---|---|
| 01–02 | [#50](https://github.com/FluentWork/fluentwork-ios/pull/50) | Audio session manager + injection |
| 03 | [#51](https://github.com/FluentWork/fluentwork-ios/pull/51) | Interruption observer → speech session |
| 04 | [#52](https://github.com/FluentWork/fluentwork-ios/pull/52) | forceClose 后台拆除 |
| 05 | [#53](https://github.com/FluentWork/fluentwork-ios/pull/53) | scenePhase → forceClose / reconnect |
| 07 | [#54](https://github.com/FluentWork/fluentwork-ios/pull/54) | Task closure weak sweep |
| 06 | [#55](https://github.com/FluentWork/fluentwork-ios/pull/55) | processing 子阶段 |

对比 commit `bf0ae8b`（改造前）的 before/after 数字 **未采集**。没有 matching pre-change Instruments run，因此本报告不编造差距分析。

---

## 门禁（pending measurement）

| 指标 | 门禁 | Status | 实测值 |
|---|---|---|---|
| LiveAudioEngine instances | ≤ 2 | pending measurement | — |
| NotificationCenter observers | 稳定（反复进房不增长） | pending measurement | — |
| URLSessionSocketTransport | ≤ 2 | pending measurement | — |
| Leaks | 0 | pending measurement | — |
| `LiveAudioEngine.startCapture` avg | < 50ms | pending measurement | — |

截图附件（Allocations / Leaks / Time Profiler）同样 **未采集**。跑完后放到 `build/instruments/` 旁或本报告下方链接，再把 Status 改成 pass/fail。

---

## How to run

```bash
bash Scripts/instruments-baseline.sh --dry-run   # 只解析 scheme / 模拟器 / xctrace 命令
bash Scripts/instruments-baseline.sh             # 真跑：build FluentWorkHost + 三个模板各 TIME_LIMIT（默认 30m）
```

脚本会：

1. 以仓库根为 `PROJECT_ROOT`
2. 优先 `iPhone 17 Pro` 模拟器，否则 `iPhone 16`
3. 优先 `FluentWorkHost` scheme（`project.yml` + `xcodebuild -list`）；没有则挑 Host app scheme
4. 把 `.trace` 写到 `build/instruments/{allocations,leaks,time-profiler}.trace`

覆盖变量：`TIME_LIMIT`、`SIMULATOR_NAME`、`SKIP_BUILD=1`、`ATTACH_PID`。

---

## Scenario checklist

与 ISSUE-08 / T-008-1 对齐。每个 Instruments 模板录制期间都要走完：

1. 启动 App → **进入 Speaking Room**
2. 点击开始 → **5 个 turn**（录音约 5s + 等待约 3s）
3. 触发模拟 **interruption**（系统通知 / 电话打断）
4. 触发 **background / foreground**（后台约 5s 再回前台）
5. 走 **forceClose** 路径，然后退出 Speaking Room

---

## 填写实测时

1. 打开三个 `.trace`，在 Allocations 里统计 `LiveAudioEngine` 与 `URLSessionSocketTransport` 实例；反复创建 5 次会话，实例数不应增长。
2. Leaks 视图确认 0 leak 标记。
3. Time Profiler 看 `startCapture` 平均耗时是否 < 50ms。
4. 只有存在 `bf0ae8b` 上同等场景的对照 trace 时，才写改造前/后对比。没有对照就保持 “not measured”。
