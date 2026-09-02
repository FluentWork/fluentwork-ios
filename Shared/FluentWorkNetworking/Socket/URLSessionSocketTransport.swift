import Foundation

/// Production WSS transport backed by `URLSessionWebSocketTask`.
///
/// Responsibilities: connect + handshake, control/audio codec, 30s ping,
/// interrupt drop-gate, and failure events. Business semantics stay outside.
public actor URLSessionSocketTransport: SocketTransportProtocol {
    public struct Configuration: Sendable {
        public var pingInterval: Duration
        public var pingFailureThreshold: Int
        public var reconnectWindow: Duration

        public init(
            pingInterval: Duration = .seconds(30),
            pingFailureThreshold: Int = 2,
            reconnectWindow: Duration = .seconds(3)
        ) {
            self.pingInterval = pingInterval
            self.pingFailureThreshold = pingFailureThreshold
            self.reconnectWindow = reconnectWindow
        }

        public static let `default` = Configuration()
    }

    private let session: URLSession
    private let configuration: Configuration
    nonisolated public let events: AsyncStream<SocketTransportEvent>
    private nonisolated let continuation: AsyncStream<SocketTransportEvent>.Continuation

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var dropGate = AudioFrameDropGate()
    private var connectionState: SocketConnectionState = .idle
    private var consecutivePingFailures = 0
    private var activeSessionID: String?
    private var activeTicket: String?
    private var activeURL: URL?

    public init(
        session: URLSession = .shared,
        configuration: Configuration = .default
    ) {
        self.session = session
        self.configuration = configuration
        let pair = AsyncStream.makeStream(
            of: SocketTransportEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    deinit {
        receiveTask?.cancel()
        pingTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    public func connect(url: URL, sessionID: String, ticket: String) async throws {
        await disconnect(emitDisconnected: false)

        activeURL = url
        activeSessionID = sessionID
        activeTicket = ticket
        dropGate = AudioFrameDropGate()
        consecutivePingFailures = 0

        emit(.stateChanged(.connecting))

        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        do {
            // Send auth frame (backend expects "auth" type, not "handshake")
            let auth = WSControlFrame.auth(ticket: ticket)
            try await send(control: auth, using: task)
            
            // Wait for session.ready response
            // The backend will send back session.ready with the actual session_id
            // For now we emit connected immediately after sending auth
            emit(.stateChanged(.connected))
            startReceiveLoop(task)
            startPingLoop(task)
        } catch {
            emit(.failure(mapError(error)))
            emit(.stateChanged(.disconnected))
            throw error
        }
    }

    public func disconnect() async {
        await disconnect(emitDisconnected: true)
    }

    public func send(control frame: WSControlFrame) async throws {
        let task = try currentTask()
        try await send(control: frame, using: task)
    }

    public func send(audio data: Data) async throws {
        let task = try currentTask()
        do {
            try await task.send(.data(data))
        } catch is CancellationError {
            throw SocketTransportError.cancelled
        } catch {
            throw SocketTransportError.network(error.localizedDescription)
        }
    }

    public func markInterrupted() async {
        dropGate.markInterrupted()
    }

    // MARK: - Private

    private func disconnect(emitDisconnected: Bool) async {
        receiveTask?.cancel()
        pingTask?.cancel()
        receiveTask = nil
        pingTask = nil
        let task = webSocketTask
        webSocketTask = nil
        connectionState = .disconnected

        task?.cancel(with: .goingAway, reason: nil)
        if emitDisconnected {
            emit(.stateChanged(.disconnected))
        }
    }

    private func currentTask() throws -> URLSessionWebSocketTask {
        guard let webSocketTask else {
            throw SocketTransportError.notConnected
        }
        return webSocketTask
    }

    private func send(control frame: WSControlFrame, using task: URLSessionWebSocketTask) async throws {
        do {
            let data = try WSControlFrameCodec.encode(frame)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SocketTransportError.encodingFailed("control frame is not UTF-8")
            }
            try await task.send(.string(text))
        } catch let error as SocketTransportError {
            throw error
        } catch {
            throw SocketTransportError.encodingFailed(error.localizedDescription)
        }
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
    }

    private func startPingLoop(_ task: URLSessionWebSocketTask) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            await self?.pingLoop(task)
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let receivedAt = ContinuousClock.now
            do {
                let message = try await task.receive()
                let decodedAt = ContinuousClock.now
                let receiveElapsedMs = Self.elapsedMs(from: receivedAt, to: decodedAt)
                try handle(message: message)
                logReceiveLatency(message: message, elapsedMs: receiveElapsedMs)
            } catch is CancellationError {
                break
            } catch {
                emit(.failure(mapError(error, receivePhase: true)))
                emit(.stateChanged(.disconnected))
                break
            }
        }
    }

    /// Converts a `ContinuousClock.Duration` to fractional milliseconds.
    /// Centralized here so the receive-loop latency column has the same
    /// granularity as the session-level `SpeechSessionTimingsRecorder`.
    private static func elapsedMs(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let duration = end - start
        let components = duration.components
        return Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func pingLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: configuration.pingInterval)
                guard !Task.isCancelled else { return }

                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    task.sendPing { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }

                consecutivePingFailures = 0
            } catch is CancellationError {
                break
            } catch {
                consecutivePingFailures += 1
                if consecutivePingFailures >= configuration.pingFailureThreshold {
                    emit(.failure(.pingTimedOut))
                    emit(.stateChanged(.disconnected))
                    break
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) throws {
        switch message {
        case let .string(text):
            guard let data = text.data(using: .utf8) else {
                throw SocketTransportError.decodingFailed(
                    "control frame text is not UTF-8 (bytes=\(text.utf8.count))"
                )
            }
            do {
                let frame = try WSControlFrameCodec.decode(data)
                emit(.control(frame))
            } catch let error as WSControlFrameCodingError {
                throw SocketTransportError.decodingFailed(
                    "control frame decode failed: \(describe(error)) (bytes=\(data.count))"
                )
            } catch {
                throw SocketTransportError.decodingFailed(
                    "control frame decode failed: \(error.localizedDescription) (bytes=\(data.count))"
                )
            }

        case let .data(data):
            do {
                let frame = try WSAudioFrameCodec.decode(data)
                dropGate.observe(sequence: frame.sequence)
                if dropGate.shouldDeliver(sequence: frame.sequence) {
                    emit(.audio(frame))
                }
            } catch {
                throw SocketTransportError.decodingFailed(
                    "audio frame decode failed: \(error.localizedDescription) (bytes=\(data.count))"
                )
            }

        @unknown default:
            throw SocketTransportError.decodingFailed("unsupported websocket message")
        }
    }

    /// Pretty-prints a `WSControlFrameCodingError` so the iOS log doesn't
    /// fall back to NSError's default "the operation couldn't be completed"
    /// bridge (`framecodingerror error 0`) when the backend sends a frame
    /// type iOS doesn't know about.
    private func describe(_ error: WSControlFrameCodingError) -> String {
        switch error {
        case let .unknownType(type):
            return "unknown type \"\(type)\""
        case let .missingField(field):
            return "missing required field \"\(field)\""
        }
    }

    /// Emits a transport-level timing marker (`timing_socket_receive`)
    /// once per inbound frame so the iOS log shows the wall-clock time
    /// between `URLSessionWebSocketTask.receive()` returning and `handle()`
    /// finishing. The `frame_type` tag is sourced from the parsed message
    /// when possible so the log can be filtered on `.string` vs `.data`
    /// (audio decode cost is the dominant contributor in the audio path).
    private nonisolated func logReceiveLatency(
        message: URLSessionWebSocketTask.Message,
        elapsedMs: Double
    ) {
        let (frameType, sizeBytes): (String, Int) = {
            switch message {
            case let .string(text):
                let firstQuote = text.firstIndex(of: "\"") ?? text.startIndex
                let afterQuote = text.index(after: firstQuote)
                let endQuote = text[afterQuote...].firstIndex(of: "\"") ?? text.endIndex
                let type = String(text[afterQuote..<endQuote])
                return (type.isEmpty ? "unknown" : type, text.utf8.count)
            case let .data(data):
                return ("audio_binary", data.count)
            @unknown default:
                return ("unknown", 0)
            }
        }()

        continuation.yield(.diagnostic(
            .receiveLatency(frameType: frameType, sizeBytes: sizeBytes, elapsedMs: elapsedMs)
        ))
    }

    private func emit(_ event: SocketTransportEvent) {
        if case let .stateChanged(state) = event {
            connectionState = state
        }
        continuation.yield(event)
    }

    private func mapError(_ error: Error, receivePhase: Bool = false) -> SocketTransportError {
        if error is CancellationError {
            return .cancelled
        }
        if let transportError = error as? SocketTransportError {
            return transportError
        }
        // Preserve `NSError` domain + code so the iOS log shows what the
        // system actually returned. Without this, the bare
        // `localizedDescription` collapses to "the operation couldn't be
        // completed framecodingerror error 0" and the underlying domain /
        // code (which is the only way to tell whether it's a transport
        // reset, a frame-protocol violation, or a server-initiated close)
        // is lost.
        let nsError = error as NSError
        if receivePhase {
            return .network("[\(nsError.domain) \(nsError.code)] \(nsError.localizedDescription)")
        }
        return .network(nsError.localizedDescription)
    }
}
