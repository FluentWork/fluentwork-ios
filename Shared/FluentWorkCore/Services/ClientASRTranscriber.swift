import Foundation
import AVFoundation
import Speech

/// B13 — protocol for a client-side ASR engine that transcribes audio in real time.
///
/// Three concrete implementations are provided:
///   `VolcengineClientASRTranscriber` — Volcengine SDK (B14+); placeholder throws `notAvailable`.
///   `AppleSpeechClientASRTranscriber` — Apple Speech Framework (iOS 17+); primary fallback.
///   `RawClientASRTranscriber` — returns `""` immediately; for debug / smoke tests.
///
/// All implementations MUST emit `AudioEngineEvent.clientASRCompleted` on success
/// and `AudioEngineEvent.clientASRFailed` on any terminal failure (including
/// timeout). The caller owns the timeout; implementors MUST NOT swallow it.
///
/// Logging contract (Apple Speech implementation):
///   debug  — init, capability probe, permission request, interim results
///   info   — final transcript delivered, fallback triggered
///   error  — engine error, permission denied, uncaught exception
public protocol ClientASRTranscriber: Sendable {
    /// Returns `true` when the engine is available on this device / OS combination.
    /// When `false`, the caller MUST NOT invoke `transcribe` and MUST emit
    /// `clientASRFailed(reason: .notAvailable)` instead.
    var isAvailable: Bool { get }

    /// Synchronously starts recognition and immediately returns control to the
    /// caller. Results are delivered via the `onResult` callback (may be called
    /// zero or more times with interim transcripts, then once with a final
    /// transcript or `nil` on failure).
    ///
    /// - Parameters:
    ///   - audioSession: The `AVAudioSession` to configure before recording.
    ///   - onResult: Called with `(isFinal: Bool, text: String?)`. The last call
    ///     with `isFinal == true` carries the final transcript. If the engine
    ///     fails without ever producing a final result, `onResult` is called with
    ///     `isFinal == true` and `text == nil`.
    ///   - onFailure: Called with the failure reason. Implementors MUST call
    ///     exactly once on terminal failure (including timeout).
    func startRecognition(
        audioSession: AVAudioSession,
        onResult: @escaping @Sendable (_ isFinal: Bool, _ text: String?) -> Void,
        onFailure: @escaping @Sendable (ClientASRFailureReason) -> Void
    )

    /// Cancels any in-flight recognition. Safe to call even if recognition
    /// has already finished. After `cancel()` returns, neither `onResult`
    /// nor `onFailure` will be called.
    func cancel()
}

// MARK: - Convenience overload for callers that only care about the final result.

extension ClientASRTranscriber {
    /// Convenience wrapper that waits for the final transcript (or failure)
    /// with an external timeout owned by the caller.
    ///
    /// Returns the transcript string, or `nil` if the engine was unavailable
    /// or timed out before producing a final result.
    ///
    /// Default implementation provided so that test stubs only need to override
    /// `startRecognition`; `transcribe` works without extra boilerplate.
    public func transcribe(timeoutMs: Int = 800) async -> String? {
        await withCheckedContinuation { continuation in
            var didReturn = false
            let guard_ = LockCheckedContinuationGuard(resuming: &continuation, once: &didReturn)

            startRecognition(
                audioSession: AVAudioSession.sharedInstance(),
                onResult: { isFinal, text in
                    guard_(.continue)
                    if isFinal {
                        guard_(.resume(returning: text ?? ""))
                    }
                },
                onFailure: { reason in
                    guard_(.continue)
                    guard_(.resume(returning: nil))
                    _ = reason // silence unused warning in default impl
                }
            )
        }
    }
}

// MARK: - LockCheckedContinuationGuard

/// Tracks whether a `CheckedContinuation` has already been resumed, then
/// calls the provided action and resumes once on the first invocation.
/// Subsequent calls are no-ops (prevents double-resume crash).
private struct LockCheckedContinuationGuard<T> {
    private let lock = NSLock()
    private var resumed = false
    private var continuation: CheckedContinuation<T, Never>?
    private var pendingAction: (() -> Void)?

    init(resuming: inout CheckedContinuation<T, Never>?, once: inout Bool) {
        self.continuation = resuming
    }

    enum Action {
        case `continue`
        case resume(returning: T)
    }

    mutating func callAsFunction(_ action: Action) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }

        switch action {
        case .continue:
            pendingAction?()
            pendingAction = nil
        case .resume(let value):
            resumed = true
            pendingAction?()
            pendingAction = nil
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
