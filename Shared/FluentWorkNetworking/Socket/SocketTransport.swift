import Foundation

public enum SocketConnectionState: String, Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting
    case disconnected
}

public enum SocketTransportError: Error, Equatable, Sendable {
    case invalidURL
    case notConnected
    case handshakeFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case network(String)
    case pingTimedOut
    case cancelled
}

public enum SocketTransportEvent: Equatable, Sendable {
    case stateChanged(SocketConnectionState)
    case control(WSControlFrame)
    case audio(WSAudioFrame)
    case failure(SocketTransportError)
    /// Non-control observation emitted by the transport for timing /
    /// observability purposes. Always optional to consume; reducer layers
    /// outside `FluentWorkNetworking` can ignore it without breaking the
    /// speaking-room state machine.
    case diagnostic(SocketTransportDiagnostic)
}

/// Side-channel events the transport emits for observability. Kept off the
/// `control` / `audio` channels so the speaking-room reducer doesn't have
/// to filter timing samples out of its inbound frame stream.
public enum SocketTransportDiagnostic: Equatable, Sendable {
    /// Wall-clock duration of a single `URLSessionWebSocketTask.receive()`
    /// → `handle(message:)` cycle. Captured by the receive loop on every
    /// successful frame so timing regressions in the decode / dispatch path
    /// show up next to the frame type instead of being averaged out.
    case receiveLatency(frameType: String, sizeBytes: Int, elapsedMs: Double)

    /// A barge-in watermark discarded an inbound audio frame.
    ///
    /// Reported once per watermark rather than once per frame: the gate drops
    /// silently, and a run of silent drops is what turns a numbering regression
    /// into "the reply is half missing" with nothing in any log to say why. The
    /// watermark value is the datum — an audio sequence at or below it, arriving
    /// after the turn that set it, is what says the numbering went backwards.
    case audioFrameDropped(sequence: UInt32, watermark: UInt32, dropped: Int)

    /// A ping/pong round trip produced a tighter gateway↔phone clock estimate
    /// than any before it.
    ///
    /// Emitted only when the estimate actually improves, so a steady session
    /// logs one line instead of one per heartbeat. Consumers that never see it
    /// (a transport that does not probe, or a session shorter than one ping)
    /// must read `server_ts_ms` as unmeasurable rather than as zero skew —
    /// treating a missing offset as zero silently bills the clock difference to
    /// the latency the field exists to measure.
    case clockOffsetEstimated(ClockOffset)
}

public protocol SocketTransportProtocol: Sendable {
    /// Connects to `url`, sends the handshake control frame with `ticket`, then starts receive/ping loops.
    func connect(url: URL, sessionID: String, ticket: String) async throws

    func disconnect() async

    func send(control frame: WSControlFrame) async throws
    func send(audio data: Data) async throws

    /// Marks the interrupt watermark using the highest observed audio sequence so far.
    func markInterrupted() async

    /// Server → client events (state, control, audio, failures).
    var events: AsyncStream<SocketTransportEvent> { get }
}

/// No-op transport used before a live session is wired.
public final class PlaceholderSocketTransport: SocketTransportProtocol, Sendable {
    nonisolated public let events: AsyncStream<SocketTransportEvent>
    private nonisolated let continuation: AsyncStream<SocketTransportEvent>.Continuation

    public init() {
        let pair = AsyncStream.makeStream(of: SocketTransportEvent.self)
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    public func connect(url: URL, sessionID: String, ticket: String) async throws {
        continuation.yield(.stateChanged(.connecting))
        continuation.yield(.stateChanged(.connected))
    }

    public func disconnect() async {
        continuation.yield(.stateChanged(.disconnected))
    }

    public func send(control frame: WSControlFrame) async throws {}

    public func send(audio data: Data) async throws {}

    public func markInterrupted() async {}
}
