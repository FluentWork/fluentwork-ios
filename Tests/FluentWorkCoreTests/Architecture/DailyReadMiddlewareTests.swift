import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKitTesting
import Testing

@testable import FluentWorkCore

@MainActor
@Test func dailyReadMiddlewareLoadTriggeredAppliesReadyResponse() async throws {
  let api = StubDailyReadAPIClient(responses: [
    .ready(makeDailyRead())
  ])
  let client = StubDailyReadClient(api: api)

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }

  let store = AppStoreFactory.make(
    container: container,
    initialState: AppState.initial
  )

  store.dispatch(AppAction.dailyRead(.loadTriggered))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.phase == .ready
  }
  #expect(store.state.dailyRead.dailyRead?.id == "dr-001")
  #expect(store.state.dailyRead.genDate == "2026-09-01")
}

@MainActor
@Test func dailyReadMiddlewarePollsPendingUntilReady() async throws {
  let api = StubDailyReadAPIClient(responses: [
    .pending,
    .pending,
    .ready(makeDailyRead()),
  ])
  let client = StubDailyReadClient(api: api)

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }

  let store = AppStoreFactory.make(
    container: container,
    initialState: AppState.initial
  )

  store.dispatch(AppAction.dailyRead(.loadTriggered))

  try await waitUntil(timeoutNanoseconds: 10_000_000_000) {
    store.state.dailyRead.phase == .ready
  }
  #expect(await api.callCount == 3)
}

@MainActor
@Test func dailyReadMiddlewareFallsBackToFailedWhenServerSaysFailed() async throws {
  let api = StubDailyReadAPIClient(responses: [
    .failed
  ])
  let client = StubDailyReadClient(api: api)

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }

  let store = AppStoreFactory.make(
    container: container,
    initialState: AppState.initial
  )

  store.dispatch(AppAction.dailyRead(.loadTriggered))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.phase == .fallbackPreset
  }
  #expect(store.state.dailyRead.fallbackBody?.isEmpty == false)
}

@MainActor
@Test func dailyReadMiddlewareSurfacesLoadFailedForTransportErrors() async throws {
  let client = ThrowingDailyReadClient()

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }

  let store = AppStoreFactory.make(
    container: container,
    initialState: AppState.initial
  )

  store.dispatch(AppAction.dailyRead(.loadTriggered))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.phase == .failed
  }
  #expect(store.state.dailyRead.lastErrorMessage?.isEmpty == false)
}

@MainActor
@Test func dailyReadMiddlewareFollowReadSubmittedMarksRecordedOnSuccess() async throws {
  let api = StubDailyReadAPIClient(responses: [.ready(makeDailyRead())])
  api.followReadResult = FollowReadResponse(
    dailyReadID: "dr-001",
    recorded: true,
    readScore: nil,
    generator: "volc-ark"
  )
  let client = StubDailyReadClient(api: api)

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }

  var initial = AppState.initial
  initial.dailyRead.phase = .ready
  initial.dailyRead.dailyRead = makeDailyRead()
  initial.dailyRead.followReadPhase = .recording

  let store = AppStoreFactory.make(
    container: container,
    initialState: initial
  )

  store.dispatch(AppAction.dailyRead(.followReadSubmitted))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.followReadPhase == .recorded
  }
  #expect(store.state.dailyRead.hasFollowRead == true)
}

@MainActor
@Test func dailyReadMiddlewareFollowReadFailureCarriesMessage() async throws {
  let api = StubDailyReadAPIClient(responses: [.ready(makeDailyRead())])
  api.followReadError = APIError.backend(code: "boom", message: "网络异常")
  let client = StubDailyReadClient(api: api)

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }

  var initial = AppState.initial
  initial.dailyRead.phase = .ready
  initial.dailyRead.dailyRead = makeDailyRead()
  initial.dailyRead.followReadPhase = .recording

  let store = AppStoreFactory.make(
    container: container,
    initialState: initial
  )

  store.dispatch(AppAction.dailyRead(.followReadSubmitted))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    if case .failed = store.state.dailyRead.followReadPhase { return true }
    return false
  }
}

// MARK: - Stubs

private enum DailyReadStubResponse {
  case pending
  case ready(DailyRead)
  case failed
}

private final class StubDailyReadAPIClient: DailyReadAPIClientProtocol, @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.fluentwork.test.daily-read-api")
  private var responses: [DailyReadStubResponse]
  private var index = 0

  var followReadResult: FollowReadResponse?
  var followReadError: Error?

  private(set) var callCount: Int = 0

  init(responses: [DailyReadStubResponse]) {
    self.responses = responses
  }

  func getDailyReadToday(accessToken: String) async throws -> DailyReadTodayResponse {
    let snapshot: DailyReadStubResponse = queue.sync {
      callCount += 1
      let next: DailyReadStubResponse =
        index < self.responses.count
        ? self.responses[index]
        : self.responses.last ?? .pending
      index += 1
      return next
    }
    switch snapshot {
    case .pending:
      return DailyReadTodayResponse(genDate: "2026-09-01", status: .pending)
    case .ready(let read):
      return DailyReadTodayResponse(
        genDate: "2026-09-01",
        status: .ready,
        dailyRead: read
      )
    case .failed:
      return DailyReadTodayResponse(genDate: "2026-09-01", status: .failed)
    }
  }

  func postFollowRead(
    accessToken: String,
    dailyReadID: String,
    audioURL: String?
  ) async throws -> FollowReadResponse {
    let (result, error): (FollowReadResponse?, Error?) = queue.sync {
      (self.followReadResult, self.followReadError)
    }
    if let error {
      throw error
    }
    return result
      ?? FollowReadResponse(
        dailyReadID: dailyReadID,
        recorded: true,
        readScore: nil,
        generator: "volc-ark"
      )
  }
}

private final class StubDailyReadClient: DailyReadClientProtocol, @unchecked Sendable {
  let api: StubDailyReadAPIClient

  init(api: StubDailyReadAPIClient) {
    self.api = api
  }

  func loadToday() async throws -> DailyReadTodayResponse {
    try await api.getDailyReadToday(accessToken: "stub-token")
  }

  func submitFollowRead(dailyReadID: String, audioURL: String?) async throws -> FollowReadResponse {
    try await api.postFollowRead(
      accessToken: "stub-token",
      dailyReadID: dailyReadID,
      audioURL: audioURL
    )
  }
}

private final class ThrowingDailyReadClient: DailyReadClientProtocol, @unchecked Sendable {
  func loadToday() async throws -> DailyReadTodayResponse {
    throw APIError.network(description: "boom")
  }

  func submitFollowRead(dailyReadID: String, audioURL: String?) async throws -> FollowReadResponse {
    throw APIError.network(description: "unused")
  }
}

private func makeDailyRead() -> DailyRead {
  DailyRead(
    id: "dr-001",
    title: "Daily Read Sample",
    body: "Today's short passage for practice.",
    audioURL: "https://example.com/audio.mp3",
    generator: "volc-ark",
    usedBlockIDs: [],
    sourceRefs: [:],
    readScore: nil
  )
}

/// First action through `dailyReadAudioObserver` must start exactly one task.
@Test func observerStartedBoxConcurrentTryMarkStartedSucceedsOnce() async {
  let box = ObserverStartedBox()
  let successes = ObserverStartedSuccessCounter()

  await withTaskGroup(of: Void.self) { group in
    for _ in 0..<32 {
      group.addTask {
        if box.tryMarkStarted() {
          await successes.increment()
        }
      }
    }
  }

  #expect(await successes.value == 1)
  #expect(box.isStarted())
  #expect(!box.tryMarkStarted())
}

private actor ObserverStartedSuccessCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

// MARK: - 只读展示缓存（F9）

/// 稿子 §07 场景 06：弱网浏览**不留白页**。
///
/// 与历史不同的是这里多一条断言：屏幕上的日期必须是**这份内容自己的日期**。
/// 跨了一天又连不上服务端，只把昨天的正文端上来、日期却写今天，就是让缓存说谎。
@MainActor
@Test func cachedContentShowsWithItsOwnDateWhenTheNetworkIsDown() async throws {
  let client = ThrowingDailyReadClient()
  let cache = InMemoryDailyReadCacheStore()

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }
  container.dailyReadCacheStore.register { cache }

  try await cache.saveSnapshot(
    CachedDailyReadSnapshot(genDate: "2026-08-31", dailyRead: makeDailyRead()),
    scope: cacheScope(for: AppState.initial)
  )

  let store = AppStoreFactory.make(container: container, initialState: AppState.initial)
  store.dispatch(AppAction.dailyRead(.loadTriggered))

  try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
    store.state.dailyRead.dailyRead != nil
  }
  #expect(store.state.dailyRead.phase == .ready, "有内容可读就不该是错误页")
  #expect(store.state.dailyRead.genDate == "2026-08-31", "日期必须是这份内容自己的日期")
  #expect(store.state.dailyRead.dailyRead?.id == "dr-001")
  #expect(store.state.dailyRead.lastErrorMessage != nil, "同时仍要告知这次没取到")
}

/// 拉到新内容后要把快照存下来（含 `genDate`），否则下次离线没有东西可显示。
@MainActor
@Test func aReadyResponseIsStoredForTheNextOfflineOpen() async throws {
  let api = StubDailyReadAPIClient(responses: [.ready(makeDailyRead())])
  let cache = InMemoryDailyReadCacheStore()

  let container = Container()
  container.reset()
  container.dailyReadClient.register { StubDailyReadClient(api: api) }
  container.dailyReadCacheStore.register { cache }

  let store = AppStoreFactory.make(container: container, initialState: AppState.initial)
  store.dispatch(AppAction.dailyRead(.loadTriggered))

  try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
    store.state.dailyRead.phase == .ready
  }

  let snapshot = try await cache.loadSnapshot(scope: cacheScope(for: store.state))
  #expect(snapshot?.genDate == "2026-09-01")
  #expect(snapshot?.dailyRead.id == "dr-001")
}
