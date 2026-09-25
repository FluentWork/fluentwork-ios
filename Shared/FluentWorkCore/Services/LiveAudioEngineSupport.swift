@preconcurrency import AVFoundation
import Foundation

public enum AudioEnginePermissionError: Error {
    case microphoneDenied
}

public enum AudioEngineError: Error {
    case invalidFormat(String)
    case audioSessionConflict(String)
}

struct AudioSpeechActivityTracker: Sendable {
    /// Endpointing hold for auto-VAD. Nobody taps in that mode, so silence is
    /// the only signal and the hold is what decides how long a turn waits.
    static let autoVADSilenceHold: Duration = .milliseconds(1500)
    /// Endpointing hold for tap-to-start. Deliberately much longer than the
    /// auto-VAD hold: the user opened the turn on purpose and is usually
    /// mid-thought, so a pause to find a word must not submit the turn.
    static let tapToStartSilenceHold: Duration = .milliseconds(8000)

    private(set) var isSpeechActive = false
    private(set) var lastSpeechAt: ContinuousClock.Instant?

    /// The shape of the utterance that just closed.
    private(set) var lastEndpoint: Endpoint?

    struct Endpoint: Equatable, Sendable {
        /// `manual` — the user pressed 说完了. `silenceHold` — the room decided.
        /// Only the second can cut someone off mid-sentence.
        enum Reason: String, Equatable, Sendable {
            case manual
            case silenceHold
        }

        let reason: Reason
        /// Last detected speech → close, i.e. how long the room waited after
        /// the last sound before submitting. The number the hold is measured
        /// against.
        ///
        /// `nil` on a tap, which has no trailing silence to measure — `nil`
        /// rather than zero, because a zero here reads as "the user stopped and
        /// immediately finished", which is a real and different case.
        let trailingSilence: Duration?
    }

    let speechThreshold: Float
    var silenceHold: Duration
    /// When false an utterance can only begin via `forceStart()`; energy is
    /// still what closes it. This is tap-to-start: the tap opens the turn, a
    /// stable silence submits it, so a turn costs one gesture instead of two.
    var autoStart: Bool

    init(
        speechThreshold: Float = 0.015,
        silenceHold: Duration = AudioSpeechActivityTracker.autoVADSilenceHold,
        autoStart: Bool = true
    ) {
        self.speechThreshold = speechThreshold
        self.silenceHold = silenceHold
        self.autoStart = autoStart
    }

    mutating func register(energy: Float, at now: ContinuousClock.Instant) -> AudioEngineEvent? {
        if energy >= speechThreshold {
            lastSpeechAt = now
            guard !isSpeechActive else { return nil }
            guard autoStart else { return nil }
            isSpeechActive = true
            return .speechStarted
        }

        // `lastSpeechAt` stays nil until the user actually speaks, so a tap
        // followed by silence never submits an empty turn — it falls through to
        // the recording abort instead.
        guard isSpeechActive, let lastSpeechAt else { return nil }
        let trailing = now - lastSpeechAt
        guard trailing >= silenceHold else { return nil }

        isSpeechActive = false
        self.lastSpeechAt = nil
        lastEndpoint = Endpoint(reason: .silenceHold, trailingSilence: trailing)
        return .speechEnded
    }

    mutating func forceStart() -> AudioEngineEvent? {
        guard !isSpeechActive else { return nil }
        isSpeechActive = true
        lastSpeechAt = nil
        return .speechStarted
    }

    mutating func forceEnd() -> AudioEngineEvent? {
        guard isSpeechActive else { return nil }
        discard()
        lastEndpoint = Endpoint(reason: .manual, trailingSilence: nil)
        return .speechEnded
    }

    mutating func reset() -> AudioEngineEvent? {
        let wasActive = isSpeechActive
        discard()
        return wasActive ? .speechEnded : nil
    }

    /// Clear in-progress speech without emitting `.speechEnded`.
    mutating func discard() {
        isSpeechActive = false
        lastSpeechAt = nil
    }

    /// The tracker a boundary mode implies — the one source of truth for the
    /// mode → (`autoStart`, `silenceHold`) mapping.
    static func forMode(_ mode: SpeechBoundaryMode) -> AudioSpeechActivityTracker {
        AudioSpeechActivityTracker(
            silenceHold: mode == .tapToStart ? tapToStartSilenceHold : autoVADSilenceHold,
            autoStart: mode == .autoVAD
        )
    }
}

/// The order in which one session's audio graph is torn down.
///
/// The rule the order has to obey: **graph mutations may not run while the
/// engine is running.** `engine.detach(_:)` and `inputNode.removeTap` are the
/// same mutation with two failure modes — the first raises an `NSException`
/// rather than throwing, the second is a burst of static in the speaker — so
/// the sequence is the part that can be wrong, and it is pure so it can be
/// asserted without an audio device.
enum PlaybackTeardown {
    enum Step: Equatable, Sendable {
        case stopPlayer
        case resetPlayer
        case stopKeepAlive
        case resetKeepAlive
        case stopEngine
        case removeTap
        case detachPlayer
        case detachKeepAlive
    }

    /// The steps to run, in order, for the state capture is being stopped from.
    ///
    /// `stopEngine` is emitted whenever the engine is running, whether or not a
    /// player is attached: a session that never played anything still has a
    /// running engine, and leaving it running is what makes the *next*
    /// session's graph work against a stale one.
    ///
    /// Graph mutations (`removeTap`, `detach`) come *after* `stopEngine`.
    /// `resetPlayer` sits between `stopPlayer` and `stopEngine` so scheduled
    /// TTS buffers are dumped instead of draining as static through the stop.
    static func steps(
        playerAttached: Bool,
        engineRunning: Bool,
        tapInstalled: Bool = false,
        keepAliveAttached: Bool = false
    ) -> [Step] {
        var steps: [Step] = []
        if playerAttached {
            steps.append(.stopPlayer)
            steps.append(.resetPlayer)
        }
        // The keep-alive node gets the TTS player's treatment in full, detach
        // included: a node left attached across a teardown is the state the
        // next session's `play()` raises on, and "it was only the silent one"
        // is not a property `AVAudioPlayerNode` cares about.
        if keepAliveAttached {
            steps.append(.stopKeepAlive)
            steps.append(.resetKeepAlive)
        }
        if engineRunning {
            steps.append(.stopEngine)
        }
        if tapInstalled {
            steps.append(.removeTap)
        }
        if playerAttached {
            steps.append(.detachPlayer)
        }
        if keepAliveAttached {
            steps.append(.detachKeepAlive)
        }
        return steps
    }
}

enum EngineStart {
    struct Failure: Equatable, Sendable {
        let error: String?
        let interrupted: Bool
        let session: String

        var detail: String {
            let cause: String
            if let error {
                cause = "start() threw: \(error)"
            } else {
                cause = "start() returned normally and the engine is still not running"
            }
            return "engine not running after the start attempt (\(cause)); "
                + "interrupted=\(interrupted) \(session)"
        }
    }

    struct Outcome: Equatable, Sendable {
        let wasRunning: Bool
        let failure: Failure?
    }
}
