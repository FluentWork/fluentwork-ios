import FluentWorkNetworking
import Foundation

/// 闪测的「听一句话、转成文字」。
///
/// 它住在中间件与「引擎 + 转写器」之间，理由与 `DefaultDrillClient` 同一条：
/// 中间件不该知道「要起采集」「收尾等哪条事件」「转写有 800ms 预算」这些事。
///
/// ## 它不建会话
///
/// 闪测没有会话、不走网关，所以它只做三件事：起采集（**整轮一次**，惰性）、
/// 收这一句的 PCM、交给 `ClientASRTranscriber`。
///
/// ## 它读的是**第二条**采集流
///
/// `audioEngine.events()` 是进程级单消费者流（房间的 `audioEventPump` 一直读着），
/// 闪测去读会**和房间抢帧**。所以它读 `captureEventStream()` —— 见那条契约。
public protocol DrillAnswerCapturing: Sendable {
    /// 听一句话。`seconds` 是这一题的作答限时。
    ///
    /// - Returns: 听清了就是那句话；**没听清（超时 / 静音 / 转写为空）返回 `nil`**（不是错误）——
    ///   那种情况交给 5 秒到点的 `answerDeadlineReached` 兜底。中间件不该再分一支失败出来：
    ///   两处都报「没听清」只会让屏幕上出现两个互相矛盾的说法。
    /// - Throws: 只在「采集根本起不来」（权限 / 引擎）时抛。
    func captureAnswer(seconds: Double) async throws -> String?
    /// 这一轮结束，把音频会话的认领还回去。
    ///
    /// **必须**与第一次 `captureAnswer` 成对，理由见
    /// `AudioEngineProtocol.releaseSessionClaim()`：不还的话名册上会永远挂着一个名字，
    /// 此后任何一次归还都判「还有人占着」，于是**别人的声音被关掉**。
    func stopListening() async
}

/// 生产实现：真引擎 + 客户端转写。
///
/// ## 为什么要先 `startCapture()`
///
/// 真引擎的 tap 只在 `startCapture()` 之后才开始回调（它同时认领音频会话、装 tap）。
/// 而 `startCapture()` **不幂等**（会拆了重装 tap），所以它**整轮只起一次**，
/// 由第一次 `captureAnswer` 惰性触发，由机器的 `.stopListening` 收尾。
public actor DefaultDrillAnswerCapturer: DrillAnswerCapturing {
    private let audioEngine: AudioEngineProtocol
    private let transcriber: ClientASRTranscriber
    private var isListening = false

    public init(audioEngine: AudioEngineProtocol, transcriber: ClientASRTranscriber) {
        self.audioEngine = audioEngine
        self.transcriber = transcriber
    }

    public func captureAnswer(seconds: Double) async throws -> String? {
        try await ensureListening()

        let stream = audioEngine.captureEventStream()
        let collector = Task { await Self.collectUtterance(from: stream, limit: seconds) }
        // 起这一轮的话。`beginManualSpeech()` 在替身上就是「说一句脚本里的话」，
        // 在真引擎上是开一轮 tap-to-start —— 两条路都靠它，闪测的「自动开始作答」
        // 就是**机器替学员按下了这个开始**。
        await audioEngine.beginManualSpeech()

        let chunks = await collector.value
        guard !chunks.isEmpty else { return nil }

        let text = try await transcriber.transcribe(pcm: Self.stream(of: chunks))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func stopListening() async {
        guard isListening else { return }
        isListening = false
        await audioEngine.stopCapture()
        // 归还与 `startCapture()` 里的认领成对。**不能**塞进 `stopCapture()`（见协议注释）。
        await audioEngine.releaseSessionClaim()
    }

    private func ensureListening() async throws {
        guard !isListening else { return }
        try await audioEngine.startCapture()
        isListening = true
    }

    /// 收「这一句话」的 PCM：等 `.speechStarted` 起，到 `.speechEnded` 止，或超时。
    ///
    /// ⚠️ **收尾等的是 `.speechEnded`，不是时钟**。稿子写的是「话音落下 → 300ms 翻转进判定中」；
    /// 死等整段限时还会和 `answerDeadlineReached`（到点就带空文本提交）撞车 ——
    /// 转写结果回来时机器已经进了 `.judging`，那一句就白说了。
    ///
    /// 两条路都需要各自的「到点」：`AsyncStream` 上如果没有事件，`for await` 会一直挂着，
    /// 光靠 `Task.sleep` 是叫不醒它的 —— 所以这里是并发的一对，先到先赢。
    private static func collectUtterance(
        from stream: AsyncStream<AudioEngineEvent>,
        limit: Double
    ) async -> [Data] {
        await withTaskGroup(of: [Data]?.self) { group in
            group.addTask {
                var chunks: [Data] = []
                var started = false
                for await event in stream {
                    switch event {
                    case .speechStarted:
                        started = true
                    case let .pcmChunk(data) where started:
                        chunks.append(data)
                    case .speechEnded where started:
                        return chunks
                    default:
                        break
                    }
                }
                return chunks
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(limit))
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result ?? []
            }
            return []
        }
    }

    /// 把攒下来的块拼成转写器要的那条流。
    ///
    /// 先攒后转（而不是边收边转）是刻意的：这一句最多几秒、16 kHz 单声道 PCM16 也就百来 KB，
    /// 换来的是一条**不用处理「流没关好就跑掉」的路径** —— 转写器那边一旦有人在读，
    /// 把流收干净的时机就只有一处。
    private static func stream(of chunks: [Data]) -> AsyncStream<Data> {
        AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}
