import FluentWorkNetworking
import Foundation
import TGReduxKitTesting
import Testing

@testable import FluentWorkCore

@Test func dailyReadReducerHandlesPendingResponse() {
  let store = TestStore(
    initialState: AppState.initial,
    reducer: appReducer
  )

  var expected = AppState.initial
  expected.dailyRead.phase = .generating
  store.send(.dailyRead(.loadTriggered))
  #expect(expected == store.state)

  expected.dailyRead.phase = .generating
  expected.dailyRead.genDate = "2026-09-01"
  store.send(
    .dailyRead(.applyResponse(makeTodayResponse(status: .pending, genDate: "2026-09-01")))
  )
  #expect(expected == store.state)
}

@Test func dailyReadReducerHandlesReadyResponse() {
  let store = TestStore(
    initialState: AppState.initial,
    reducer: appReducer
  )

  var expected = AppState.initial
  expected.dailyRead.phase = .generating
  store.send(.dailyRead(.loadTriggered))
  #expect(expected == store.state)

  expected.dailyRead.phase = .ready
  expected.dailyRead.dailyRead = makeDailyRead()
  expected.dailyRead.genDate = "2026-09-01"
  store.send(
    .dailyRead(.applyResponse(makeReadyTodayResponse(genDate: "2026-09-01")))
  )
  #expect(expected == store.state)
}

@Test func dailyReadReducerFallsBackToPresetWhenServerFails() {
  let store = TestStore(
    initialState: AppState.initial,
    reducer: appReducer
  )

  var expected = AppState.initial
  expected.dailyRead.phase = .generating
  store.send(.dailyRead(.loadTriggered))
  #expect(expected == store.state)

  expected.dailyRead.phase = .fallbackPreset
  expected.dailyRead.dailyRead = nil
  expected.dailyRead.fallbackBody = expected.dailyRead.fallbackBody  // preset body set by reducer
  expected.dailyRead.genDate = "2026-09-01"
  store.send(
    .dailyRead(.applyResponse(makeTodayResponse(status: .failed, genDate: "2026-09-01")))
  )
  #expect(expected.dailyRead.phase == store.state.dailyRead.phase)
  #expect(store.state.dailyRead.dailyRead == nil)
  #expect(store.state.dailyRead.fallbackBody?.isEmpty == false)
}

@Test func dailyReadReducerPreservesV1V11NoScoringDisplay() {
  // V1.1 hard constraint: read_score is never shown, even when backend sends it.
  let store = TestStore(
    initialState: AppState.initial,
    reducer: appReducer
  )

  var response = makeReadyTodayResponse(genDate: "2026-09-01")
  response.dailyRead?.readScore = 9.5
  store.send(.dailyRead(.applyResponse(response)))
  #expect(store.state.dailyRead.displayScore == nil)
}

@Test func dailyReadReducerTracksAudioPlaybackLifecycle() {
  let store = TestStore(
    initialState: AppState.initial,
    reducer: appReducer
  )

  store.send(.dailyRead(.applyResponse(makeReadyTodayResponse(genDate: "2026-09-01"))))
  #expect(store.state.dailyRead.audioPhase == .idle)

  store.send(.dailyRead(.playTapped))
  #expect(store.state.dailyRead.audioPhase == .loading)

  // Simulate playback finished.
  store.send(.dailyRead(.audioFinished))
  #expect(store.state.dailyRead.audioPhase == .idle)
  #expect(store.state.dailyRead.audioPlaybackTime == 0)
}

@Test func dailyReadReducerTracksFollowReadSubmission() {
  let store = TestStore(
    initialState: AppState.initial,
    reducer: appReducer
  )

  store.send(.dailyRead(.applyResponse(makeReadyTodayResponse(genDate: "2026-09-01"))))
  store.send(.dailyRead(.followReadRecordingStarted))
  #expect(store.state.dailyRead.followReadPhase == .recording)

  store.send(.dailyRead(.followReadSubmitted))
  #expect(store.state.dailyRead.followReadPhase == .submitting)

  store.send(.dailyRead(.followReadSucceeded))
  #expect(store.state.dailyRead.followReadPhase == .recorded)
  #expect(store.state.dailyRead.hasFollowRead == true)

  store.send(.dailyRead(.followReadFailed("网络异常")))
  #expect(store.state.dailyRead.followReadPhase == .failed("网络异常"))
}

@Test func dailyReadReducerClearResetsToIdle() {
  let store = TestStore(
    initialState: AppState.initial,
    reducer: appReducer
  )

  store.send(.dailyRead(.applyResponse(makeReadyTodayResponse(genDate: "2026-09-01"))))
  #expect(store.state.dailyRead.phase == .ready)

  store.send(.dailyRead(.clear))
  #expect(store.state.dailyRead.phase == .idle)
  #expect(store.state.dailyRead.dailyRead == nil)
}

// MARK: - Helpers

private func makeTodayResponse(status: DailyReadStatus, genDate: String) -> DailyReadTodayResponse {
  DailyReadTodayResponse(
    genDate: genDate,
    status: status,
    dailyRead: nil
  )
}

private func makeReadyTodayResponse(genDate: String) -> DailyReadTodayResponse {
  DailyReadTodayResponse(
    genDate: genDate,
    status: .ready,
    dailyRead: makeDailyRead()
  )
}

private func makeDailyRead() -> DailyRead {
  DailyRead(
    id: "dr-001",
    title: "Daily Read Sample",
    body: "Welcome to today's daily read. Practice with the AI tutor.",
    audioURL: "https://example.com/audio.mp3",
    generator: "volc-ark",
    usedBlockIDs: [],
    sourceRefs: [:],
    readScore: nil
  )
}
