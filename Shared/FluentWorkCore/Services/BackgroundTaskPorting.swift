import Foundation

/// Abstracts `UIApplication.beginBackgroundTask` so middleware can buy a
/// short teardown window without calling UIKit from tests.
///
/// `0` is the invalid identifier. Callers must skip `end` when `begin` returns `0`.
public protocol BackgroundTaskPorting: Sendable {
    func begin(name: String, expirationHandler: @escaping @Sendable () -> Void) async -> UInt
    func end(_ id: UInt) async
}

/// macOS and tests: no system background-task budget.
public struct NoOpBackgroundTaskPort: BackgroundTaskPorting {
    public init() {}

    public func begin(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> UInt {
        0
    }

    public func end(_ id: UInt) async {}
}

#if os(iOS)
import UIKit

/// Production iOS port. UIKit calls run on `MainActor`.
public struct UIKitBackgroundTaskPort: BackgroundTaskPorting {
    public init() {}

    public func begin(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> UInt {
        await MainActor.run {
            var identifier = UIBackgroundTaskIdentifier.invalid
            identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
                expirationHandler()
                if identifier != .invalid {
                    UIApplication.shared.endBackgroundTask(identifier)
                }
            }
            guard identifier != .invalid else { return 0 }
            let raw = identifier.rawValue
            return raw > 0 ? UInt(raw) : 0
        }
    }

    public func end(_ id: UInt) async {
        guard id != 0 else { return }
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(
                UIBackgroundTaskIdentifier(rawValue: Int(id))
            )
        }
    }
}
#endif
