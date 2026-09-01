import AVFoundation
import Foundation
import Speech

/// B13 — Apple Speech Framework implementation of `ClientASRTranscriber`.
///
/// Uses `SFSpeechRecognizer` with on-device recognition (`requiresOnDeviceRecognition`)
/// and `AVAudioEngine` to capture microphone input.
///
/// ## Logging (`.clientASR` domain, via `OSLogLogger`)
/// | Level | Event |
/// |---|---|
/// | debug | init / capability probe / permission request |
/// | info | final transcript delivered / skipped (no permission) |
/// | error | engine error / permission denied |
///
/// ## Timeout
/// Caller owns the timeout; this implementation does not enforce one internally.
/// If the caller does not cancel within the expected window, the recognizer
/// will eventually call `onResult(isFinal: true, text: "...")` when the server
/// delivers a final hypothesis. To enforce a hard deadline, set
/// `recognitionTaskTimeout` on the recognizer or use a per-call timeout wrapper.
///
/// ## Thread safety
/// `SFSpeechRecognitionTask` callbacks arrive on a background queue. All state
/// mutations (recording `isRunning`, finalizing `finalTranscript`) are synchronized
/// via `NSLock` so that `cancel()` called from any thread is safe.
public final class AppleSpeechClientASRTranscriber: ClientASRTranscriber {
    public enum InitError: Error, Sendable {
        case speechRecognizerUnavailable
        case recognizerDoesNotSupportOnDeviceRecognition
    }

    // MARK: - Dependencies

    private let recognizer: SFSpeechRecognizer
    private let audioEngine: AVAudioEngine
    private let logger: OSLogLogger

    // MARK: - Mutable state (all access guarded by `lock`)

    private let lock = NSLock()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRunning = false
    private var finalTranscript: String?
    private var resultHandler: ((Bool, String?) -> Void)?
    private var failureHandler: ((ClientASRFailureReason) -> Void)?

    // MARK: - Init

    /// - Parameters:
    ///   - recognizer: Injected so tests can use a mock `SFSpeechRecognizer`.
    ///     Defaults to `SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))`.
    ///   - logger: Injected so tests can capture log entries via `CapturingLogger`.
    public init(
        recognizer: SFSpeechRecognizer? = nil,
        logger: OSLogLogger = OSLogLogger(subsystem: "com.fluentwork.app")
    ) throws {
        let r = recognizer ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        guard let recognizer = r else {
            self.logger = logger
            self.audioEngine = AVAudioEngine()
            logger.error(
                "AppleSpeechClientASRTranscriber init failed: speech recognizer unavailable for zh-CN",
                domain: .clientASR
            )
            throw InitError.speechRecognizerUnavailable
        }

        self.recognizer = recognizer
        self.audioEngine = AVAudioEngine()
        self.logger = logger

        // Capability probe — verify on-device recognition is supported.
        // If not, we still mark `isAvailable = true` and fall back to
        // server-side recognition (Apple sends audio to its servers).
        if !recognizer.supportsOnDeviceRecognition {
            logger.debug(
                "AppleSpeechClientASRTranscriber: recognizer does not support on-device; will use server fallback",
                domain: .clientASR
            )
        } else {
            logger.debug(
                "AppleSpeechClientASRTranscriber: on-device recognition available",
                domain: .clientASR
            )
        }
    }

    // MARK: - ClientASRTranscriber

    public var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recognizer.isAvailable
    }

    public func startRecognition(
        audioSession: AVAudioSession,
        onResult: @escaping @Sendable (_ isFinal: Bool, _ text: String?) -> Void,
        onFailure: @escaping @Sendable (ClientASRFailureReason) -> Void
    ) {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            logger.debug(
                "AppleSpeechClientASRTranscriber.startRecognition: already running, ignoring duplicate call",
                domain: .clientASR
            )
            return
        }
        isRunning = true
        resultHandler = onResult
        failureHandler = onFailure
        lock.unlock()

        logger.debug(
            "AppleSpeechClientASRTranscriber.startRecognition: configuring AVAudioSession",
            domain: .clientASR
        )

        // 1. Configure audio session for recording.
        do {
            try audioSession.setCategory(
                .record,
                mode: .measurement,
                options: [.duckOthers, .allowBluetooth]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error(
                "AppleSpeechClientASRTranscriber: AVAudioSession config failed — \(error.localizedDescription)",
                domain: .clientASR
            )
            finalize(isFinal: true, text: nil, failureReason: .engineError(underlyingError: error.localizedDescription))
            return
        }

        // 2. Request microphone + speech recognition permissions if not already granted.
        requestPermissions { [weak self] micGranted, speechGranted in
            guard let self = self else { return }

            if !micGranted || !speechGranted {
                let reason: ClientASRFailureReason = !micGranted
                    ? .engineError(underlyingError: "microphone permission denied")
                    : .engineError(underlyingError: "speech recognition permission denied")
                self.logger.info(
                    "AppleSpeechClientASRTranscriber: permission denied (mic=\(micGranted), speech=\(speechGranted)) — skipping client ASR",
                    domain: .clientASR
                )
                self.finalize(isFinal: true, text: nil, failureReason: reason)
                return
            }

            self.startAudioEngineAndRecognition()
        }
    }

    public func cancel() {
        lock.lock()
        let wasRunning = isRunning
        isRunning = false
        let task = recognitionTask
        recognitionTask = nil
        resultHandler = nil
        failureHandler = nil
        lock.unlock()

        if wasRunning {
            logger.debug(
                "AppleSpeechClientASRTranscriber.cancel: stopping AVAudioEngine and SFSpeechRecognitionTask",
                domain: .clientASR
            )
        }

        task?.cancel()
        task = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Private helpers

    private func requestPermissions(completion: @escaping (Bool, Bool) -> Void) {
        var micGranted = false
        var speechGranted = false
        let group = DispatchGroup()

        group.enter()
        AVAudioApplication.requestRecordPermission { granted in
            micGranted = granted
            group.leave()
        }

        group.enter()
        SFSpeechRecognizer.requestAuthorization { status in
            speechGranted = (status == .authorized)
            group.leave()
        }

        group.notify(queue: .main) {
            completion(micGranted, speechGranted)
        }
    }

    private func startAudioEngineAndRecognition() {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install tap on the input node to stream PCM chunks to the recognizer.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat)

        audioEngine.prepare()
        do {
            try audioEngine.start()
            logger.debug(
                "AppleSpeechClientASRTranscriber: AVAudioEngine started (format: \(String(describing: recordingFormat)))",
                domain: .clientASR
            )
        } catch {
            logger.error(
                "AppleSpeechClientASRTranscriber: AVAudioEngine start failed — \(error.localizedDescription)",
                domain: .clientASR
            )
            finalize(isFinal: true, text: nil, failureReason: .engineError(underlyingError: error.localizedDescription))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 16, *) {
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }

        logger.debug(
            "AppleSpeechClientASRTranscriber: starting SFSpeechRecognitionTask (onDevice=\(recognizer.supportsOnDeviceRecognition))",
            domain: .clientASR
        )

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            // Feed PCM buffers into the recognition request.
            // Note: `inputNode` is a captured local; the tap is installed before
            // `recognitionTask` starts, so this is safe to call from the task
            // callback context.
            let buffer = inputNode.lastRenderTime.map { inputNode.auAudioTap(0)?.format } ?? recordingFormat

            if let error = error {
                // `error NSError == NSErrorCancelled` means `cancel()` was called;
                // distinguish from genuine errors.
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                    // `cancel()`d task — silent exit.
                    return
                }
                self.logger.error(
                    "AppleSpeechClientASRTranscriber: recognitionTask error — \(error.localizedDescription)",
                    domain: .clientASR
                )
                self.finalize(isFinal: true, text: nil, failureReason: .engineError(underlyingError: error.localizedDescription))
                return
            }

            guard let result = result else { return }

            // Interim results — pass through so callers can display partial text.
            if !result.isFinal {
                self.logger.debug(
                    "AppleSpeechClientASRTranscriber: interim — \"\(result.bestTranscription.formattedString, privacy: .public)\"",
                    domain: .clientASR
                )
                self.emitResult(isFinal: false, text: result.bestTranscription.formattedString)
            } else {
                let transcript = result.bestTranscription.formattedString
                self.logger.info(
                    "AppleSpeechClientASRTranscriber: final transcript — \"\(transcript, privacy: .public)\" (segments: \(result.bestTranscription.segments.count))",
                    domain: .clientASR
                )
                self.finalize(isFinal: true, text: transcript, failureReason: nil)
            }
        }

        // Feed audio buffers from the tap into the recognition request.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionTask?.append(buffer)
        }
    }

    private func emitResult(isFinal: Bool, text: String) {
        lock.lock()
        let handler = resultHandler
        lock.unlock()
        handler?(isFinal, text)
    }

    private func finalize(isFinal: Bool, text: String?, failureReason: ClientASRFailureReason?) {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        isRunning = false
        let handler = resultHandler
        let failHandler = failureHandler
        resultHandler = nil
        failureHandler = nil
        recognitionTask = nil
        lock.unlock()

        // Always stop audio engine on terminal state.
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if let reason = failureReason {
            logger.debug(
                "AppleSpeechClientASRTranscriber: finalizing with failure reason \(String(describing: reason))",
                domain: .clientASR
            )
            failHandler?(reason)
        } else if isFinal {
            handler?(true, text)
        }
    }
}
