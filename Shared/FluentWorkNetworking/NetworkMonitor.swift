import Foundation
import Network

public struct NetworkPathSnapshot: Equatable, Sendable {
    public var isConnected: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool

    public init(
        isConnected: Bool,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public static let connected = NetworkPathSnapshot(isConnected: true)
    public static let disconnected = NetworkPathSnapshot(isConnected: false)
}

public protocol NetworkMonitorProtocol: Sendable {
    func currentSnapshot() -> NetworkPathSnapshot
    func connectivityUpdates() -> AsyncStream<NetworkPathSnapshot>
}

/// State is serialized on a queue rather than an actor: `NetworkMonitorProtocol.currentSnapshot()`
/// is a synchronous requirement read from reducer/middleware contexts that cannot await.
public final class NWPathNetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let stateQueue = DispatchQueue(label: "com.fluentwork.network-monitor.state")
    private var latest: NetworkPathSnapshot

    public init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        self.queue = DispatchQueue(label: "com.fluentwork.network-monitor")
        self.latest = NetworkPathSnapshot(
            isConnected: monitor.currentPath.status == .satisfied,
            isExpensive: monitor.currentPath.isExpensive,
            isConstrained: monitor.currentPath.isConstrained
        )
    }

    public func currentSnapshot() -> NetworkPathSnapshot {
        stateQueue.sync {
            latest
        }
    }

    public func connectivityUpdates() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream { continuation in
            continuation.yield(currentSnapshot())

            monitor.pathUpdateHandler = { [weak self] path in
                let snapshot = NetworkPathSnapshot(
                    isConnected: path.status == .satisfied,
                    isExpensive: path.isExpensive,
                    isConstrained: path.isConstrained
                )
                self?.stateQueue.sync {
                    self?.latest = snapshot
                }
                continuation.yield(snapshot)
            }
            monitor.start(queue: queue)

            continuation.onTermination = { [monitor] _ in
                monitor.cancel()
            }
        }
    }
}

/// Same synchronous-boundary constraint as `NWPathNetworkMonitor`; kept queue-serialized.
public final class StubNetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.fluentwork.stub-network-monitor")
    private var snapshot: NetworkPathSnapshot
    private var continuations: [UUID: AsyncStream<NetworkPathSnapshot>.Continuation] = [:]

    public init(snapshot: NetworkPathSnapshot = .connected) {
        self.snapshot = snapshot
    }

    public func currentSnapshot() -> NetworkPathSnapshot {
        stateQueue.sync {
            snapshot
        }
    }

    public func connectivityUpdates() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            let current = stateQueue.sync { () -> NetworkPathSnapshot in
                continuations[id] = continuation
                return snapshot
            }
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.stateQueue.sync {
                    self?.continuations[id] = nil
                }
            }
        }
    }

    public func emit(_ snapshot: NetworkPathSnapshot) {
        let targets = stateQueue.sync { () -> [AsyncStream<NetworkPathSnapshot>.Continuation] in
            self.snapshot = snapshot
            return Array(continuations.values)
        }
        for continuation in targets {
            continuation.yield(snapshot)
        }
    }

    public func subscriberCountForTesting() -> Int {
        stateQueue.sync {
            continuations.count
        }
    }
}
