import Foundation

/// Test double that records outbound frames and lets tests inject inbound events.
public actor InMemorySocketTransport: SocketTransportProtocol {
    public private(set) var connectCalls: [(url: URL, sessionID: String, ticket: String)] = []
    public private(set) var sentControlFrames: [WSControlFrame] = []
    public private(set) var sentAudioPayloads: [Data] = []
    /// Diagnostics the double emitted. Recorded as well as streamed, so a test
    /// can assert on them without draining a stream that never finishes — the
    /// double has no `deinit` that would end it.
    public private(set) var emittedDiagnostics: [SocketTransportDiagnostic] = []
    public private(set) var disconnectCount = 0

    nonisolated public let events: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation
    private var isConnected = false

    public init() {
        let pair = AsyncStream.makeStream(of: SocketTransportEvent.self)
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    public func connect(url: URL, sessionID: String, ticket: String) async throws {
        connectCalls.append((url, sessionID, ticket))
        isConnected = true

        continuation.yield(.stateChanged(.connecting))
        continuation.yield(
            .control(.auth(ticket: ticket))
        )
        continuation.yield(.stateChanged(.connected))
    }

    public func disconnect() async {
        disconnectCount += 1
        isConnected = false
        continuation.yield(.stateChanged(.disconnected))
    }

    public func send(control frame: WSControlFrame) async throws {
        guard isConnected else {
            throw SocketTransportError.notConnected
        }
        sentControlFrames.append(frame)
    }

    public func send(audio data: Data) async throws {
        guard isConnected else {
            throw SocketTransportError.notConnected
        }
        sentAudioPayloads.append(data)
    }

    public func emitFailure(_ error: SocketTransportError) async {
        continuation.yield(.failure(error))
    }

    public func emitDiagnostic(_ diagnostic: SocketTransportDiagnostic) async {
        continuation.yield(.diagnostic(diagnostic))
    }

    public func emitControl(_ frame: WSControlFrame) async {
        continuation.yield(.control(frame))
    }

    /// Injects an audio frame exactly as production transport does.
    ///
    /// "Exactly as" now means **no drop decision at all**. This used to run the
    /// frame past a barge-in sequence watermark, and it used to report the drops
    /// it made so the double and production could not drift. Both went with the
    /// watermark: a sequence number cannot say which turn a frame belongs to, so
    /// there was nothing for the gate to decide correctly. The drop decision
    /// lives in `TTSPlaybackCoordinator`, on the turn axis.
    @discardableResult
    public func emitAudio(_ frame: WSAudioFrame) -> Bool {
        continuation.yield(.audio(frame))
        return true
    }
}
