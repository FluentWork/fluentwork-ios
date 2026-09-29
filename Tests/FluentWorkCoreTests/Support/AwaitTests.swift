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
    // 预算**不测速度**，只测「条件为 async 时也接得住」（见 `Await.swift` 顶部那段）。
    // 原来给的是 500ms，那正是它点名批评过的错误：负载高的 runner 上一次
    // `Task.sleep(1ms)` 可以走几百毫秒，三次轮询就超了 —— 2026-09-29 CI 上实测红，
    // 本机绿。条件第二次为真需要 2 次 sleep，给足预算，别把它变成延迟断言。
    try await waitUntil(timeoutNanoseconds: 5_000_000_000, pollIntervalNanoseconds: 1_000_000) {
        value += 1
        return value >= 3
    }
    #expect(value >= 3)
}
