# 断线重连的真机验证程序（iOS-S0-3 的第二半）

**状态**：单元层已覆盖，**真机一次都没跑**（barge-in 已于 2026-09-30 真机验证）。
本文件只描述怎么验、看什么、怎么判——不重复单元判据。

## 为什么还需要真机

单元判据证明「状态机在给定事件下走对」，证不了这三件只有真机能回答的事：

1. `URLSessionWebSocketTask` 在真断网（飞行模式 / 关 Wi-Fi）时报的是哪一类失败，
   以及 `SocketTransportEventMapper` 有没有把它映射成 `.networkLost`（而不是别的分支）；
2. 重连窗口的时长在真机上是否与用户感知一致（窗口来自 `ProcessingTimeouts`）；
3. 断线时**在途的 AI 语音**（TTS PCM 还在播）会不会被正确丢弃而不是接在重连后的下一轮上。

## 前置

- 后端在跑且手机可达：`cd fluentwork-backend && ./scripts/dev-up.sh --host <你的 LAN IP>`
  （**必须带 `--host`**，否则下发的 `wss_url` 是 `127.0.0.1`，手机连自己）。
- 一次**大于 5 秒**的 AI 回复：短回复在断网前就播完了，等于没测到第 3 条。

## 步骤（可证伪的预测写在括号里）

1. 进房间，说一句，让 AI 开始一段长回复。
2. AI 播到一半时**开飞行模式**。
   （预测：相位进 `degradedText` 的**前置**是重连窗口超时，所以中间应有一段
   `isReconnecting == true` 而相位**不变**——不是立刻跳到 degradedText。）
3. 在窗口内关掉飞行模式。
   （预测：socket 重连成功 → `.reconnectSucceeded` 清掉 `isReconnecting`；
   若当时是 `aiSpeaking` / `processing`，**被取代的那一轮必须丢弃**，
   不能让它的帧落到新一轮上。）
4. 再来一次，这次**在窗口内不恢复网络**，等它超时。
   （预测：进入 `degradedText`，且**不**是 `.failed`——断网不是练习失败。）

## 怎么看

- 控制台/日志：`timing_*` 里找 `speech_session_transition` 序列，确认
  `isReconnecting` 的置位与清除各只有一次；`timing_transport_consumer_exit` 的
  `cancelled` 字段能区分「我们自己拆」与「流真的没了」。
- 后端 `.dev-logs/voice-gateway.log`：断线那一会话的收尾是 `EOF` 还是
  `write: broken pipe`（后者=客户端先走）。

## 判否（出现即开票）

- 断网后**直接**进 `degradedText`（说明窗口没被武装，或 `.networkLost` 没被派出去）；
- 重连后听到**上一轮**的残余语音（在途帧没被丢弃）；
- 断网被判成 `.failed`（用户会看到「失败」，而事实只是网络抖动）。
