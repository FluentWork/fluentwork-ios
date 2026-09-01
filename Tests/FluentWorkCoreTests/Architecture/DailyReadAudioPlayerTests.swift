import FactoryKit
import FluentWorkCore
import FluentWorkNetworking
import Foundation
import TGReduxKitTesting
import Testing

@MainActor
@Test func dailyReadMiddlewarePlayTappedLoadsAndStartsPlayback() async throws {
  let api = StubDailyReadAPIClient(responses: [.ready(makeDailyRead())])
  let client = StubDailyReadClient(api: api)
  let player = StubDailyReadAudioPlayer()

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }
  container.dailyReadAudioPlayer.register { player }

  var initial = AppState.initial
  initial.dailyRead.phase = .ready
  initial.dailyRead.dailyRead = makeDailyRead()
  initial.dailyRead.audioPhase = .idle

  let store = AppStoreFactory.make(container: container, initialState: initial)

  store.dispatch(AppAction.dailyRead(.playTapped))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.audioPhase == .playing
  }
}

@MainActor
@Test func dailyReadMiddlewarePlayTappedFailsWhenAudioURLEmpty() async throws {
  let api = StubDailyReadAPIClient(responses: [.ready(makeDailyRead())])
  let client = StubDailyReadClient(api: api)
  let player = StubDailyReadAudioPlayer()

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }
  container.dailyReadAudioPlayer.register { player }

  var initial = AppState.initial
  initial.dailyRead.phase = .ready
  initial.dailyRead.dailyRead = DailyRead(
    id: "dr-001",
    title: "Sample",
    body: "Body",
    audioURL: nil,
    generator: "volc-ark",
    usedBlockIDs: [],
    sourceRefs: [:],
    readScore: nil
  )

  let store = AppStoreFactory.make(container: container, initialState: initial)

  store.dispatch(AppAction.dailyRead(.playTapped))

  // No audio URL → no playback started, phase stays idle.
  try await Task.sleep(nanoseconds: 100_000_000)
  #expect(store.state.dailyRead.audioPhase == .idle)
}

@MainActor
@Test func dailyReadMiddlewarePauseTappedSwitchesToPaused() async throws {
  let api = StubDailyReadAPIClient(responses: [.ready(makeDailyRead())])
  let client = StubDailyReadClient(api: api)
  let player = StubDailyReadAudioPlayer()

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }
  container.dailyReadAudioPlayer.register { player }

  var initial = AppState.initial
  initial.dailyRead.phase = .ready
  initial.dailyRead.dailyRead = makeDailyRead()
  initial.dailyRead.audioPhase = .playing

  let store = AppStoreFactory.make(container: container, initialState: initial)

  store.dispatch(AppAction.dailyRead(.pauseTapped))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.audioPhase == .paused
  }
}

@MainActor
@Test func dailyReadAudioObserverForwardsPlaybackTimeToReducer() async throws {
  let player = StubDailyReadAudioPlayer()
  let container = Container()
  container.reset()
  container.dailyReadAudioPlayer.register { player }

  let store = AppStoreFactory.make(container: container, initialState: AppState.initial)

  // Dispatch a no-op action to start the observer middleware.
  store.dispatch(AppAction.dailyRead(.playTapped))

  player.emit(.playbackTimeUpdated(12.5))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.audioPlaybackTime == 12.5
  }
}

@MainActor
@Test func dailyReadAudioObserverForwardsDurationToReducer() async throws {
  let player = StubDailyReadAudioPlayer()
  let container = Container()
  container.reset()
  container.dailyReadAudioPlayer.register { player }

  let store = AppStoreFactory.make(container: container, initialState: AppState.initial)

  store.dispatch(AppAction.dailyRead(.playTapped))

  player.emit(.durationLoaded(120))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.audioDuration == 120
  }
}

@MainActor
@Test func dailyReadAudioObserverForwardsFinishedEvent() async throws {
  let player = StubDailyReadAudioPlayer()
  let container = Container()
  container.reset()
  container.dailyReadAudioPlayer.register { player }

  var initial = AppState.initial
  initial.dailyRead.audioPhase = .playing
  initial.dailyRead.audioPlaybackTime = 60

  let store = AppStoreFactory.make(container: container, initialState: initial)

  store.dispatch(AppAction.dailyRead(.playTapped))

  player.emit(.finished)

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.audioPhase == .idle
      && store.state.dailyRead.audioPlaybackTime == 0
  }
}

@MainActor
@Test func dailyReadAudioObserverForwardsFailure() async throws {
  let player = StubDailyReadAudioPlayer()
  let container = Container()
  container.reset()
  container.dailyReadAudioPlayer.register { player }

  let store = AppStoreFactory.make(container: container, initialState: AppState.initial)

  store.dispatch(AppAction.dailyRead(.playTapped))

  player.emit(.failed("audio decoding error"))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.audioPhase == .idle
      && store.state.dailyRead.lastErrorMessage == "audio decoding error"
  }
}

@MainActor
@Test func dailyReadReducerAudioDurationLoadedUpdatesDuration() async throws {
  let initial = AppState.initial
  let store = TestStore(initialState: initial, reducer: appReducer)

  var expected = initial
  expected.dailyRead.audioDuration = 180

  store.send(.dailyRead(.audioDurationLoaded(180)))
  try store.assert(equals: expected)
}

@MainActor
@Test func dailyReadReducerAudioPlaybackStartedMovesToPlaying() async throws {
  var initial = AppState.initial
  initial.dailyRead.audioPhase = .loading
  let store = TestStore(initialState: initial, reducer: appReducer)

  var expected = initial
  expected.dailyRead.audioPhase = .playing

  store.send(AppAction.dailyRead(.audioPlaybackStarted))
  try store.assert(equals: expected)
}

// MARK: - Stubs (reusing the existing dailyRead stub infrastructure)

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