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

@MainActor
private func waitUntil(
  timeoutNanoseconds: UInt64,
  pollIntervalNanoseconds: UInt64 = 20_000_000,
  condition: @escaping @MainActor () -> Bool
) async throws {
  let start = DispatchTime.now().uptimeNanoseconds
  while !condition() {
    if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
      throw TimeoutError()
    }
    try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
  }
}

private struct TimeoutError: Error {}
