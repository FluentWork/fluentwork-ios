import FactoryKit
import FluentWorkCore
import FluentWorkDiagnostics
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

/// 每日一读的播放失败**必须留下记录**，而不只是屏幕上一句人话。
///
/// 这是 R10 的同一条纪律在另一条链路：说的房间走 `session_failed`（传输）与
/// `audio_engine_failed`（引擎），而每日一读的播放器有自己的事件流 —— 在补这条之前，
/// 它 `.failed` 之后**一个字都没记**，事后只能问用户看到了什么。
///
/// 判据三半：有记录、带 origin、detail 与屏幕读的是同一句。
@MainActor
@Test func dailyReadPlaybackFailureIsRecordedWithItsOrigin() async throws {
  let api = StubDailyReadAPIClient(responses: [.ready(makeDailyRead())])
  let client = StubDailyReadClient(api: api)
  let player = StubDailyReadAudioPlayer()
  let tracker = RecordingTracker()

  let container = Container()
  container.reset()
  container.dailyReadClient.register { client }
  container.dailyReadAudioPlayer.register { player }
  container.tracker.register { tracker }

  var initial = AppState.initial
  initial.dailyRead.phase = .ready
  initial.dailyRead.dailyRead = makeDailyRead()
  initial.dailyRead.audioPhase = .idle

  let store = AppStoreFactory.make(container: container, initialState: initial)
  store.dispatch(AppAction.dailyRead(.playTapped))
  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    store.state.dailyRead.audioPhase == .playing
  }

  player.emit(.failed("音频解码失败，请重试"))

  try await waitUntil(timeoutNanoseconds: 2_000_000_000) {
    tracker.events.contains { $0.0 == "dailyRead_audio_failed" }
  }
  let hit = tracker.events.first { $0.0 == "dailyRead_audio_failed" }
  #expect(hit != nil, "每日一读的播放失败没有留下任何记录：\(tracker.events.map(\.0))")
  #expect(hit?.1["origin"] == "dailyRead.audio")
  #expect(
    hit?.1["detail"] == "音频解码失败，请重试",
    "记录必须与屏幕读同一句话，否则两份文案会各自漂移"
  )
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
/// 本文件自己的记录型 tracker。
///
/// 不用 `CapturingTracker`：那个替身不在本 target 的作用域里，而这里要断言的只是
/// 「有一条事件、带 origin、detail 与屏幕读同一句」——需要一个能取回事件的最小件，
/// 不需要把别的 target 的测试装置拖过来。
private final class RecordingTracker: TrackerClientProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [(String, [String: String])] = []

  func track(event: String, properties: [String: String]) {
    lock.lock()
    defer { lock.unlock() }
    storage.append((event, properties))
  }

  var events: [(String, [String: String])] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
