import FluentWorkNetworking
import TGReduxKit

// MARK: - Phase

/// Screen phase — mirrors ReviewScreenPhase / CorpusScreenPhase naming.
public enum DailyReadScreenPhase: String, Equatable, Sendable {
  /// Not yet loaded.
  case idle
  /// Polling: backend status == pending.
  case generating
  /// Content ready.
  case ready
  /// Backend status == failed; showing preset fallback.
  case fallbackPreset
  /// Network error.
  case failed
}

// MARK: - Audio playback phase

public enum DailyReadAudioPhase: String, Equatable, Sendable {
  case idle
  case loading
  case playing
  case paused
}

// MARK: - Follow-read phase

public enum FollowReadPhase: Equatable, Sendable {
  case idle
  case recording
  case submitting
  case recorded
  case failed(String)
}

// MARK: - State

public struct DailyReadState: Equatable, Sendable, State {
  /// Screen phase.
  public var phase: DailyReadScreenPhase
  /// The fetched daily read. Present when phase == .ready.
  public var dailyRead: DailyRead?
  /// Gen date string from response, for display.
  public var genDate: String?
  /// Fallback preset body used when backend fails.
  public var fallbackBody: String?
  /// Audio playback state.
  public var audioPhase: DailyReadAudioPhase
  /// Current playback time in seconds (for scrubber).
  public var audioPlaybackTime: Double
  /// Total audio duration in seconds.
  public var audioDuration: Double
  /// Follow-read recording state.
  public var followReadPhase: FollowReadPhase
  /// Whether a follow-read has already been submitted for today.
  public var hasFollowRead: Bool
  /// Last error message for display.
  public var lastErrorMessage: String?

  public init(
    phase: DailyReadScreenPhase = .idle,
    dailyRead: DailyRead? = nil,
    genDate: String? = nil,
    fallbackBody: String? = nil,
    audioPhase: DailyReadAudioPhase = .idle,
    audioPlaybackTime: Double = 0,
    audioDuration: Double = 0,
    followReadPhase: FollowReadPhase = .idle,
    hasFollowRead: Bool = false,
    lastErrorMessage: String? = nil
  ) {
    self.phase = phase
    self.dailyRead = dailyRead
    self.genDate = genDate
    self.fallbackBody = fallbackBody
    self.audioPhase = audioPhase
    self.audioPlaybackTime = audioPlaybackTime
    self.audioDuration = audioDuration
    self.followReadPhase = followReadPhase
    self.hasFollowRead = hasFollowRead
    self.lastErrorMessage = lastErrorMessage
  }

  /// True when the skeleton / loading skeleton should be shown.
  public var showsSkeleton: Bool {
    phase == .generating || phase == .idle
  }

  /// V1.1 hard constraint: read score is always nil on the client.
  public var displayScore: Double? { nil }
}

// MARK: - Actions

public enum DailyReadAction: Equatable, Sendable, Action {
  /// Trigger initial load of today's daily read.
  case loadTriggered
  /// Apply server poll response.
  case applyResponse(DailyReadTodayResponse)
  /// Network / decoding failure.
  case loadFailed(String)
  /// User tapped play / resume.
  case playTapped
  /// User tapped pause.
  case pauseTapped
  /// Audio finished playing naturally.
  case audioFinished
  /// Audio loading failed.
  case audioFailed(String)
  /// Playback time updated by timer.
  case playbackTimeUpdated(Double)
  /// User started follow-read recording.
  case followReadRecordingStarted
  /// Follow-read recording ended; submit to backend.
  case followReadSubmitted
  /// Follow-read submission succeeded.
  case followReadSucceeded
  /// Follow-read submission failed.
  case followReadFailed(String)
  /// Clear / reset back to idle.
  case clear
}

// MARK: - Reducer

/// Preset fallback content shown when backend is unavailable or generation failed.
/// Mirrors B11 预置内容兜底口径.
private let presetFallbackBody = """
  欢迎来到每日一读！

  今天的内容正在准备中。请稍后再来，或者先在说的房间练习一段对话吧。
  每天坚持练习，你的英语表达会更加地道！
  """

public let dailyReadReducer: Reducer<DailyReadState, DailyReadAction> = { state, action in
  switch action {
  case .loadTriggered:
    state.phase = .generating
    state.lastErrorMessage = nil
    state.dailyRead = nil
    state.genDate = nil

  case .applyResponse(let response):
    state.genDate = response.genDate
    switch response.status {
    case .pending:
      state.phase = .generating
      state.lastErrorMessage = nil
    case .ready:
      state.phase = .ready
      state.dailyRead = response.dailyRead
      state.lastErrorMessage = nil
    case .failed:
      // Fallback to preset — backend gen failed, content still consumable.
      state.phase = .fallbackPreset
      state.dailyRead = nil
      state.fallbackBody = presetFallbackBody
      state.lastErrorMessage = nil
    }
    // Reset audio and follow-read whenever content arrives.
    state.audioPhase = .idle
    state.audioPlaybackTime = 0
    state.followReadPhase = .idle

  case .loadFailed(let message):
    state.phase = .failed
    state.lastErrorMessage = message

  case .playTapped:
    if state.audioPhase == .idle || state.audioPhase == .paused {
      state.audioPhase = .loading
    }

  case .pauseTapped:
    if state.audioPhase == .playing {
      state.audioPhase = .paused
    }

  case .audioFinished:
    state.audioPhase = .idle
    state.audioPlaybackTime = 0

  case .audioFailed(let message):
    state.audioPhase = .idle
    state.lastErrorMessage = message

  case .playbackTimeUpdated(let time):
    state.audioPlaybackTime = time

  case .followReadRecordingStarted:
    state.followReadPhase = .recording

  case .followReadSubmitted:
    state.followReadPhase = .submitting

  case .followReadSucceeded:
    state.followReadPhase = .recorded
    state.hasFollowRead = true

  case .followReadFailed(let message):
    state.followReadPhase = .failed(message)

  case .clear:
    state = DailyReadState()
  }
}
