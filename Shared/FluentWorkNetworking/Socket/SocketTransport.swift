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
