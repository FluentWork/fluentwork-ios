import AVFoundation
import Foundation

/// Plays AI 朗读 (AI-read audio) for the Daily Read feature.
///
/// Why a dedicated player instead of reusing `LiveAudioEngine`:
///   - `LiveAudioEngine` is wired to `.playAndRecord` + `.voiceChat` for the
///     speaking room; Daily Read only needs playback and must keep playing when
///     the user locks the screen or switches apps (Info.plist `audio` background
///     mode is set in `project.yml`).
///   - Playback timing callbacks (`audioPlaybackTimeUpdated`) feed the reducer,
///     so a simple `AVPlayer` is enough — no need for an AVAudioEngine graph.
public protocol DailyReadAudioPlayerProtocol: Sendable {
  func load(url: URL) async throws
  func play() async
  func pause() async
  func currentTime() async -> Double
  func duration() async -> Double
  func events() -> AsyncStream<DailyReadAudioEvent>
  func teardown() async
}

public enum DailyReadAudioEvent: Equatable, Sendable {
  case playbackTimeUpdated(Double)
  case durationLoaded(Double)
  case finished
  case failed(String)
}

/// Concrete `AVPlayer`-backed implementation.
///
/// Concurrency: `AVPlayer` itself is main-actor-friendly, so we run all state
/// updates on the main actor and bridge to a Sendable `AsyncStream` for the
/// Redux layer.
public final class DailyReadAudioPlayer: NSObject, DailyReadAudioPlayerProtocol, @unchecked Sendable {
  private let player = AVPlayer()
  private var timeObserverToken: Any?
  private var statusObserver: NSKeyValueObservation?
  private var rateObserver: NSKeyValueObservation?

  private let eventsStream: AsyncStream<DailyReadAudioEvent>
  private let eventsContinuation: AsyncStream<DailyReadAudioEvent>.Continuation

  private var didFinishObserver: NSObjectProtocol?

  public override init() {
    let pair = AsyncStream.makeStream(
      of: DailyReadAudioEvent.self,
      bufferingPolicy: .bufferingNewest(32)
    )
    self.eventsStream = pair.stream
    self.eventsContinuation = pair.continuation
    super.init()
    configureForBackgroundPlayback()
    installObservers()
  }

  deinit {
    if let token = timeObserverToken {
      player.removeTimeObserver(token)
    }
    if let observer = didFinishObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    statusObserver?.invalidate()
    rateObserver?.invalidate()
    eventsContinuation.finish()
  }

  public func load(url: URL) async throws {
    try configureAudioSessionForPlayback()

    await MainActor.run {
      let asset = AVURLAsset(url: url)
      let item = AVPlayerItem(asset: asset)
      self.player.replaceCurrentItem(with: item)
    }
  }

  public func play() async {
    await MainActor.run {
      self.player.play()
    }
  }

  public func pause() async {
    await MainActor.run {
      self.player.pause()
    }
  }

  public func currentTime() async -> Double {
    await MainActor.run {
      CMTimeGetSeconds(self.player.currentTime())
    }
  }

  public func duration() async -> Double {
    await MainActor.run {
      guard let item = self.player.currentItem else { return 0 }
      let duration = item.duration
      guard duration.isNumeric, !duration.isIndefinite else { return 0 }
      return CMTimeGetSeconds(duration)
    }
  }

  nonisolated public func events() -> AsyncStream<DailyReadAudioEvent> {
    eventsStream
  }

  public func teardown() async {
    await MainActor.run {
      self.player.pause()
      self.player.replaceCurrentItem(with: nil)
    }
    #if os(iOS)
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    #endif
  }

  // MARK: - Private

  private func configureForBackgroundPlayback() {
    #if os(iOS)
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .spokenAudio, options: [])
    } catch {
      eventsContinuation.yield(.failed(error.localizedDescription))
    }
    #endif
  }

  private func configureAudioSessionForPlayback() throws {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .spokenAudio, options: [])
    try session.setActive(true)
    #endif
  }

  private func installObservers() {
    // Periodic time observer (every 0.25s is enough for the scrubber UX).
    let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
    timeObserverToken = player.addPeriodicTimeObserver(
      forInterval: interval,
      queue: .main
    ) { [weak self] time in
      guard let self else { return }
      let seconds = CMTimeGetSeconds(time)
      self.eventsContinuation.yield(.playbackTimeUpdated(seconds))
    }

    // Detect item finish (e.g. AI 朗读 runs to end).
    didFinishObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.eventsContinuation.yield(.finished)
    }

    // Track KVO for duration (status becomes ready → duration is numeric).
    statusObserver = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
      guard let self else { return }
      self.evaluateLoadedDuration(player: player)
    }
    rateObserver = player.observe(\.currentItem?.duration, options: [.new]) { [weak self] player, _ in
      guard let self else { return }
      self.evaluateLoadedDuration(player: player)
    }
  }

  private func evaluateLoadedDuration(player: AVPlayer) {
    guard let item = player.currentItem else { return }
    let duration = item.duration
    guard duration.isNumeric, !duration.isIndefinite else { return }
    let seconds = CMTimeGetSeconds(duration)
    guard seconds > 0 else { return }
    eventsContinuation.yield(.durationLoaded(seconds))
  }
}

/// In-memory stub for previews / unit tests; mirrors the protocol surface
/// without touching AVFoundation.
public final class StubDailyReadAudioPlayer: DailyReadAudioPlayerProtocol, @unchecked Sendable {
  private let stream: AsyncStream<DailyReadAudioEvent>
  private let continuation: AsyncStream<DailyReadAudioEvent>.Continuation
  private var stubTime: Double = 0
  private var stubDuration: Double = 60

  public init() {
    let pair = AsyncStream.makeStream(
      of: DailyReadAudioEvent.self,
      bufferingPolicy: .bufferingNewest(32)
    )
    self.stream = pair.stream
    self.continuation = pair.continuation
  }

  public func load(url: URL) async throws {}

  public func play() async {
    continuation.yield(.playbackTimeUpdated(stubTime))
  }

  public func pause() async {}

  public func currentTime() async -> Double {
    stubTime
  }

  public func duration() async -> Double {
    stubDuration
  }

  nonisolated public func events() -> AsyncStream<DailyReadAudioEvent> {
    stream
  }

  public func teardown() async {
    continuation.finish()
  }

  public func emit(_ event: DailyReadAudioEvent) {
    continuation.yield(event)
  }

  public func setStubTime(_ value: Double) {
    stubTime = value
  }

  public func setStubDuration(_ value: Double) {
    stubDuration = value
  }
}