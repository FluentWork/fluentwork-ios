import Foundation
import Testing

@testable import FluentWorkCore

@MainActor
@Test func awaitHelperReturnsAsSoonAsTheConditionHolds() async throws {
    var polls = 0
    try await waitUntil(timeoutNanoseconds: 200_000_000, pollIntervalNanoseconds: 1_000_000) {
        polls += 1
        return true
    }
    #expect(polls == 1)
}

@MainActor
@Test func awaitHelperThrowsWhenTheConditionNeverHolds() async {
    await #expect(throws: AwaitTimeout.self) {
        try await waitUntil(timeoutNanoseconds: 50_000_000, pollIntervalNanoseconds: 1_000_000) {
            false
        }
    }
}

@MainActor
@Test func awaitHelperNamesTheCallSiteAndTheBudgetInTheTimeout() async throws {
    var captured: AwaitTimeout?
    do {
        try await waitUntil(timeoutNanoseconds: 50_000_000, pollIntervalNanoseconds: 1_000_000) {
            false
        }
    } catch let error as AwaitTimeout {
        captured = error
    }

    let timeout = try #require(captured)
    #expect(timeout.budgetMilliseconds == 50)
    #expect(timeout.file.contains("AwaitTests"))
    #expect(timeout.label.contains("awaitHelperNamesTheCallSiteAndTheBudgetInTheTimeout"))
    #expect(timeout.description.contains("50ms"))
}

@MainActor
@Test func awaitHelperSupportsAnAsyncCondition() async throws {
    var value = 0
    try await waitUntil(timeoutNanoseconds: 500_000_000, pollIntervalNanoseconds: 1_000_000) {
        value += 1
        return value >= 3
    }
    #expect(value >= 3)
}
