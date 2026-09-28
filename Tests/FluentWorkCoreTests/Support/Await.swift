import Foundation
import TGReduxKit

@testable import FluentWorkCore

struct AwaitTimeout: Error, CustomStringConvertible {
    let label: String
    let file: String
    let line: Int
    let budgetMilliseconds: Int

    var description: String {
        "\(file):\(line) —— \(label) 超时（预算 \(budgetMilliseconds)ms）"
    }
}

/// How long a test waits for the store to react before calling it hung.
///
/// **Not a latency assertion.** Everything these tests drive is in-memory; the
/// only reason a reaction is ever late is that its effect is a `Task` and the
/// machine is busy. A broken implementation does not react *slowly*, it never
/// reacts — so a generous budget catches the same regressions and only makes
/// the failure take longer to report.
///
/// It was one second, restated at twenty-one call sites, and that read like a
/// claim about how fast the middleware should be. It was not; it was how long a
/// loaded parallel CI runner was assumed to take. On 2026-09-12 two of them
/// proved the assumption wrong (`sessionStartPassesTheVoiceProcessingKillSwitchToTheEngine`
/// and `sessionStartTellsTheEngineVoiceProcessingIsOnAfterBootstrap` timed out on
/// `4fa3cd3` while passing 0.02s locally). The three callers that pass a
/// different number still do — those were chosen deliberately.
@MainActor
func waitUntil(
    timeoutNanoseconds: UInt64 = 10_000_000_000,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    label: String = #function,
    file: String = #fileID,
    line: Int = #line,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
            throw AwaitTimeout(
                label: label,
                file: file,
                line: line,
                budgetMilliseconds: Int(timeoutNanoseconds / 1_000_000)
            )
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}

@MainActor
func waitForBootstrap(
    _ store: Store<AppState, AppAction>,
    timeoutNanoseconds: UInt64 = 2_000_000_000
) async throws {
    try await waitUntil(
        timeoutNanoseconds: timeoutNanoseconds,
        label: "bootstrap 就绪"
    ) {
        switch store.state.bootstrapStatus {
        case .ready, .failed:
            return true
        case .idle, .loading:
            return false
        }
    }
}
