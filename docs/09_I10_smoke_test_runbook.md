# I10 每日一读 — 真实设备 Smoke Runbook

> 适用范围：iOS 17+ 真机（iPhone 15/16 系列优先）；后台播放 / AVPlayer / AudioSession 行为无法在模拟器真实复现
> 前置：`feat/i10-daily-read-page` 已合并到 `main`，PR #29
> 关联：32 号文档 §3.3 切后台行（C7 任务单），52 号文档 §5.3 每日一读生成与兜底门禁

---

## 1. 准备

### 1.1 设备与账号

| 项目 | 要求 |
|---|---|
| 机型 | iPhone 15 / iPhone 16 Pro（优先），旧机型次之 |
| 系统 | iOS 17.0+（开发版亦可，需标注） |
| 网络 | Wi-Fi 优先；蜂窝需开启 VolTE 避免音频中断 |
| 账号 | 用 `Guest Sign In` 即可，无需注册 |
| 后端 | `fluentwork-backend` dev 部署，daily-reads endpoint 可访问 |

### 1.2 App 安装

```bash
# 在 Xcode 中选中 FluentWorkHost scheme
# Destination 选真机（不要选模拟器）
xcodebuild -scheme FluentWorkHost \
  -destination 'platform=iOS,name=Your iPhone' \
  -configuration Debug \
  build
# 或 Xcode UI：⌘R
```

确认 Info.plist 已包含：

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

### 1.3 后端准备

确认 `B11` 已部署：

```bash
# 触发后端生成今日文章（POST /daily-reads/today 或 GET /daily-reads/today 触发 generate）
curl -H "Authorization: Bearer <guest-token>" \
  https://dev-api.fluentwork.app/v1/daily-reads/today | jq

# 返回 status:
#   - "pending"：文章生成中，前端会轮询
#   - "ready"   ：返回 dailyRead 含 audio_url
#   - "failed"  ：前端回落到预设内容
```

`audio_url` 必须返回 **HTTPS** 且 **< 60s** 的 mp3/m4a。火山 TTS 的 sample rate 24kHz、单声道最佳。

---

## 2. Smoke 用例（按优先级）

### 2.1 P0 — 核心闭环

#### Case A：今日文章展示

1. 启动 App，进入工作台 tab
2. 点击「每日一读」入口（feature flag 已开启）
3. **预期**：
   - 首次进入显示 skeleton（"每日一读生成中..."）
   - 后端 pending 时持续轮询（最多 60s），最终切到 ready 态
   - ready 后展示标题、正文、阅读时长、引用块数
4. **失败信号**：一直停在 skeleton > 60s；或切到 failed 但 retry 按钮无效

#### Case B：AI 朗读播放

1. 在 ready 文章页面，点击「播放 AI 朗读」
2. **预期**：
   - 按钮立刻变 loading 态
   - 播放器加载 ~1-3s 后开始播放，进度条前进
   - 顶部 status text 显示「播放中」
3. **断言**：
   - AVAudioSession category 是 `.playback` + mode `.spokenAudio`（开发者控制台可用 `AVAudioSession.sharedInstance().category` 验证）
   - 进度条每秒前进
   - 播放完毕自动回到 idle（audioPlaybackTime = 0）
4. **失败信号**：点击无反应 / loading 卡死 / 报错

#### Case C：暂停/恢复

1. 播放中点击「暂停」
2. **预期**：立即停止，进度条冻结；按钮文案回到「播放 AI 朗读」
3. 再次点击播放：从冻结点继续（不是从头）
4. **失败信号**：暂停后无法恢复 / 进度条异常归零

### 2.2 P0 — 后台播放

#### Case D：锁屏持续播放

1. 播放 AI 朗读，立刻锁屏（按电源键）
2. **预期**：
   - 音频**继续**播放
   - 锁屏界面出现媒体控件（标题 / 进度 / 播放暂停）
3. **断言**：
   - `Info.plist` UIBackgroundModes 已含 `audio`（Xcode → target → Info → Custom iOS Target Properties）
4. **失败信号**：锁屏后立即停播

#### Case E：切后台继续播放

1. 播放中，从底部上滑切到主屏
2. **预期**：音频继续，控制中心出现 media tile
3. **失败信号**：切后台即停

#### Case F：来电中断

1. 播放中，模拟来电（设置 → 电话 → 模拟来电；或真机呼叫另一台手机）
2. **预期**：
   - 音频立刻暂停
   - 通话结束后**不自动恢复**（不抢通话）
3. **断言**：AVAudioSession interruption notification 被接收

### 2.3 P1 — 异常路径

#### Case G：网络断开

1. 进入 App 后开飞行模式
2. 进入每日一读
3. **预期**：
   - skeleton 出现，几秒后切到 failed
   - 显示「今日一读暂时不可用 / 网络异常」+ Retry 按钮
4. 点击 Retry → 恢复飞行模式 → 应自动重新加载

#### Case H：后端 failed 状态

1. 让后端强制返回 `status: "failed"`（mock 或临时改 server 逻辑）
2. **预期**：
   - 前端切到 `fallbackPreset` 态
   - 显示预设文案「今日内容准备中...」
   - **不显示**跟读按钮（fallback 无 dailyRead.id）
3. **断言**：`store.state.dailyRead.phase == .fallbackPreset`

#### Case I：跟读提交

1. ready 文章页，点击「开始跟读」
2. **预期**：状态行显示「录音中...」红色
3. 点击「停止跟读」（按钮文案切换）
4. **预期**：
   - 状态切到「正在提交...」+ ProgressView
   - ~1s 后切到「今日已跟读」绿色
   - 按钮永久 disabled（`hasFollowRead == true`）
5. **断言**：网络日志看到 `POST /daily-reads/{id}/follow-read` 请求

#### Case J：跟读失败

1. 提交跟读时拔网（飞行模式）
2. **预期**：
   - 状态切到 failed("...")，红色 ⚠️
   - 用户可再次点击「开始跟读」重试

### 2.4 P1 — V1.1 评分硬约束

#### Case K：UI 不显示评分

1. 让后端 `daily_read.read_score = 0.85`（mock 注入）
2. 前端拉取并展示文章
3. **预期**：UI **任何地方**不出现「0.85」「85 分」字样
4. **断言**（开发者 console）：`store.state.dailyRead.displayScore == nil`
5. **失败信号**：UI 出现评分 → 立即回滚，违反 V1.1 硬约束

### 2.5 P2 — 锁屏媒体控件（按需）

> 此项依赖后续工作（`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`），目前不在 I10 范围内。若发现锁屏无控件，仅记录到 backlog，不阻塞本次合并。

---

## 3. 抓取与日志

### 3.1 Console 日志

启动时附加 `Console.app` 过滤 `process:FluentWorkHost`，收集：

- `[Tracker] daily_read_*`（如已埋点）
- `[Logger] audio_session_*`
- 任何 `domain=FluentWork.*` 的错误

### 3.2 网络抓包

Charles / Proxyman：

1. 抓 `GET /daily-reads/today` 完整请求链
2. 确认 token / device-id 正确
3. 抓 `POST /daily-reads/{id}/follow-read` 请求体

### 3.3 崩溃监控

Sentry / Firebase Crashlytics（如已接入）：检查 session 内是否产生与 daily_read 相关 crash。

---

## 4. 通过标准

- P0 全部 Case 通过
- P1 至少 Case G + I 通过
- Case K（V1.1 不出分）必须通过，否则判定为红线 bug，需立即修复并重跑

通过后将本 runbook 结果贴入 `docs/60_评审与复盘/` 周报，关联 PR #29 评论。

---

## 5. 已知限制 / Backlog

| 项 | 状态 | 备注 |
|---|---|---|
| 锁屏 / 控制中心媒体控件 | 待办 | 需 MPNowPlayingInfoCenter + MPRemoteCommandCenter |
| 播放速度切换（0.8x / 1.0x / 1.2x） | UI 占位 | 当前 status text 写了但按钮未接线 |
| 跟读真实录音上传 | 占位 | 当前 audioURL=nil，待 audio engine 接入 |
| 历史归档最小占位 | 待办 | I10 范围条目 5，下期启动 |
| 朗读音色切换 | 不在 MVP | PRD §5.4 |

---

## 6. 关联文档

- PRD：`fluentwork-meta/docs/20_产品设计/20_FluentWork产品需求文档PRD.md` §5.4 每日一读
- 技术设计：`fluentwork-meta/docs/30_技术方案/32_FluentWork-iOS App端技术设计文档.md` §3.3 切后台行 + §7 C7 任务单
- 后端：`fluentwork-backend/docs/19_B11_daily_reads_实现说明.md`
- UI 设计：`fluentwork-meta/docs/20_产品设计/21_FluentWork界面设计文档.md` §4.6 每日一读
- Issue 草案：`fluentwork-meta/docs/40_研发流程与协作/51_FluentWork第二波跨仓任务结构与Issue草案.md` §I10