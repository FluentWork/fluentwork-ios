import Foundation

/// Test double that records outbound frames and lets tests inject inbound events.
public actor InMemorySocketTransport: SocketTransportProtocol {
    public private(set) var connectCalls: [(url: URL, sessionID: String, ticket: String)] = []
    public private(set) var sentControlFrames: [WSControlFrame] = []
    public private(set) var sentAudioPayloads: [Data] = []
    public private(set) var interruptMarks = 0
    public private(set) var disconnectCount = 0

    nonisolated public let events: AsyncStream<SocketTransportEvent>
    private let continuation: AsyncStream<SocketTransportEvent>.Continuation
    private var dropGate = AudioFrameDropGate()
    private var isConnected = false

    public init() {
        let pair = AsyncStream.makeStream(of: SocketTransportEvent.self)
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    public func connect(url: URL, sessionID: String, ticket: String) async throws {
        connectCalls.append((url, sessionID, ticket))
        isConnected = true
        dropGate = AudioFrameDropGate()

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

    public func markInterrupted() async {
        interruptMarks += 1
        dropGate.markInterrupted()
    }

    public func emitFailure(_ error: SocketTransportError) async {
        continuation.yield(.failure(error))
    }

    public func emitControl(_ frame: WSControlFrame) async {
        continuation.yield(.control(frame))
    }

    /// Injects an audio frame through the same drop-gate path as production transport.
    @discardableResult
    public func emitAudio(_ frame: WSAudioFrame) -> Bool {
        dropGate.observe(sequence: frame.sequence)
        let shouldDeliver = dropGate.shouldDeliver(sequence: frame.sequence)
        if shouldDeliver {
            continuation.yield(.audio(frame))
        }
        return shouldDeliver
    }
}
