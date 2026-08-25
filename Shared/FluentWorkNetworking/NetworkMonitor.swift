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

public final class NWPathNetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
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
        lock.lock()
        defer { lock.unlock() }
        return latest
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
                self?.lock.lock()
                self?.latest = snapshot
                self?.lock.unlock()
                continuation.yield(snapshot)
            }
            monitor.start(queue: queue)

            continuation.onTermination = { [monitor] _ in
                monitor.cancel()
            }
        }
    }
}

public final class StubNetworkMonitor: NetworkMonitorProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: NetworkPathSnapshot
    private var continuations: [UUID: AsyncStream<NetworkPathSnapshot>.Continuation] = [:]

    public init(snapshot: NetworkPathSnapshot = .connected) {
        self.snapshot = snapshot
    }

    public func currentSnapshot() -> NetworkPathSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    public func connectivityUpdates() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let current = snapshot
            lock.unlock()
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    public func emit(_ snapshot: NetworkPathSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(snapshot)
        }
    }
}
