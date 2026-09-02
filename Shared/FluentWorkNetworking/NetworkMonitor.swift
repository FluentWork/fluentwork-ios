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
///
/// ## Initialization timing
/// `NWPathMonitor` requires up to several hundred milliseconds to complete its first network
/// scan on iOS. Reading `currentPath` immediately after construction can return a stale
/// `.unsatisfied` state even when the device is online. The monitor therefore starts
/// immediately in `init`, waits for the first `pathUpdateHandler` call (which signals
/// the first scan is complete), and only then publishes the initial snapshot. Middleware
/// and UI that read `currentSnapshot()` before the first update will get a conservative
/// "assumed online" value; the real state arrives via the `connectivityUpdates()` stream.
public final class NWPathNetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let stateQueue = DispatchQueue(label: "com.fluentwork.network-monitor.state")

    /// Latest confirmed snapshot (set only after the monitor's first scan completes).
    private var confirmed: NetworkPathSnapshot?

    public init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.fluentwork.network-monitor")
        self.confirmed = nil
    }

    /// Returns the confirmed snapshot once available, or an optimistic default before
    /// the first scan completes (avoids false "offline" on launch).
    public func currentSnapshot() -> NetworkPathSnapshot {
        stateQueue.sync {
            confirmed ?? NetworkPathSnapshot.connected
        }
    }

    public func connectivityUpdates() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream { continuation in
            // Publish the confirmed snapshot if already available, otherwise
            // assume online until the monitor's first scan confirms the real state.
            let initial = stateQueue.sync { confirmed ?? NetworkPathSnapshot.connected }
            continuation.yield(initial)

            self.monitor.pathUpdateHandler = { [weak self] path in
                guard let self = self else { return }
                let snapshot = NetworkPathSnapshot(
                    isConnected: path.status == .satisfied,
                    isExpensive: path.isExpensive,
                    isConstrained: path.isConstrained
                )
                self.stateQueue.sync {
                    // First handler call = initial scan complete. Lock in the confirmed state.
                    if self.confirmed == nil {
                        self.confirmed = snapshot
                    } else {
                        self.confirmed = snapshot
                    }
                }
                continuation.yield(snapshot)
            }
            self.monitor.start(queue: self.queue)

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
