# WebSocket 握手协议修复

## 问题

iOS 客户端录音时出现 `sockettransporterror error 1`，WebSocket 连接在握手阶段失败。

## 根本原因

**协议不匹配**：iOS 客户端发送的握手帧类型与后端期望不一致。

### iOS 原实现（错误）
```json
{
  "type": "handshake",
  "ticket": "...",
  "session_id": "..."
}
```

### 后端期望（正确）
```json
{
  "type": "auth",
  "ticket": "..."
}
```

后端握手流程（`internal/voicegateway/handler.go:149-210`）：
1. 客户端发送 `auth` 帧 + ticket
2. 后端验证 ticket
3. 后端返回 `session.ready` 帧，包含 `session_id` 和 `user_id`
4. 握手完成

## 修复方案

### 1. 添加新的帧类型

在 `WSControlFrame.swift` 中添加：
- `.auth(ticket: String)` - 客户端→服务器认证帧
- `.sessionReady(sessionID: String, userID: String?)` - 服务器→客户端就绪帧

保留 `.handshake` 用于向后兼容（未来可能移除）。

### 2. 更新握手逻辑

`URLSessionSocketTransport.connect()` 修改：
```swift
// 旧代码
let handshake = WSControlFrame.handshake(ticket: ticket, sessionID: sessionID)
try await send(control: handshake, using: task)

// 新代码
let auth = WSControlFrame.auth(ticket: ticket)
try await send(control: auth, using: task)
// 后端会返回 session.ready 包含真实的 session_id
```

### 3. 更新编解码

添加 `CodingKeys`:
```swift
case userID = "user_id"  // 用于 session.ready
```

添加解码逻辑：
```swift
case "auth":
    self = .auth(ticket: try container.decode(String.self, forKey: .ticket))

case "session.ready":
    self = .sessionReady(
        sessionID: try container.decode(String.self, forKey: .sessionID),
        userID: try container.decodeIfPresent(String.self, forKey: .userID)
    )
```

### 4. 更新测试

`SocketTransportTests.swift` 添加：
```swift
.auth(ticket: "t-1"),
.sessionReady(sessionID: "s-1", userID: "u-1"),
```

## 验证

### 前置条件
```bash
# 1. 后端服务运行
cd fluentwork-backend
go run cmd/app-server/main.go  # :8080
go run cmd/voice-gateway/main.go  # :8081

# 2. iOS 环境配置
AppEnvironment.current = .local
// apiBaseURL: http://192.168.2.15:8080/api/v1
// wssBaseURL: ws://192.168.2.15:8081/v1/voice
```

### 测试步骤
1. Guest Login → Promote（获取有效 token）
2. 点击录音按钮
3. 观察 WebSocket 连接状态

### 预期结果
- ✅ WebSocket 连接成功
- ✅ 接收到 `session.ready` 帧
- ✅ 可以开始录音和语音传输

## 相关文件

**iOS:**
- `Shared/FluentWorkNetworking/Socket/WSControlFrame.swift` - 帧定义
- `Shared/FluentWorkNetworking/Socket/URLSessionSocketTransport.swift` - 传输层
- `Tests/FluentWorkCoreTests/Networking/SocketTransportTests.swift` - 测试

**Backend:**
- `internal/voiceproto/frames.go` - 协议定义
- `internal/voicegateway/handler.go` - 握手处理

## 后续工作

1. [ ] 接收并处理 `session.ready` 帧，使用服务器返回的 `session_id`
2. [ ] 添加握手超时处理（当前 15 秒后端超时）
3. [ ] 考虑移除遗留的 `.handshake` 帧类型
4. [ ] 端到端测试：录音 → 转写 → 反馈徽章

## 参考

- Issue: #B13 Client ASR with PCM Buffer
- Backend PR: https://github.com/FluentWork/fluentwork-backend/pull/41
- iOS PR: https://github.com/FluentWork/fluentwork-ios/pull/29
