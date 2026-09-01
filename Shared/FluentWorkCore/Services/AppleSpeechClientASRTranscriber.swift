import Foundation
@preconcurrency import Speech
import OSLog

/// Client ASR transcriber using Apple's Speech framework.
///
/// This implementation uses on-device speech recognition (iOS 13+)
/// and requires the following:
/// - `NSSpeechRecognitionUsageDescription` in Info.plist
/// - User authorization via `SFSpeechRecognizer.requestAuthorization()`
///
/// ## Availability
///
/// - iOS 13.0+: Basic on-device recognition
/// - iOS 17.0+: Enhanced accuracy and performance
///
/// ## Usage
///
/// ```swift
/// let transcriber = AppleSpeechClientASRTranscriber(locale: Locale(identifier: "zh-CN"))
/// let text = try await transcriber.transcribe(pcm: pcmStream)
/// ```
///
/// - Note: Transcription typically completes within 300-500ms for short utterances.
public final class AppleSpeechClientASRTranscriber: ClientASRTranscriber {
    
    private let recognizer: SFSpeechRecognizer?
    private let logger = Logger(subsystem: "com.fluentwork.app", category: "AppleSpeechASR")
    
    /// Creates a new Apple Speech ASR transcriber.
    ///
    /// - Parameter locale: Language locale for recognition (default: Chinese Simplified)
    public init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        
        if recognizer == nil {
            logger.warning("SFSpeechRecognizer not available for locale: \(locale.identifier)")
        } else if recognizer?.isAvailable == false {
            logger.warning("SFSpeechRecognizer is not currently available")
        }
    }
    
    public func transcribe(pcm: AsyncStream<Data>) async throws -> String {
        guard let recognizer = recognizer else {
            throw ClientASRError.notAvailable
        }
        
        guard recognizer.isAvailable else {
            throw ClientASRError.notAvailable
        }
        
        // Check authorization
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        guard authStatus == .authorized else {
            throw ClientASRError.authorizationDenied
        }
        
        // Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false // Only want final result
        
        if #available(iOS 13.0, *) {
            request.requiresOnDeviceRecognition = true // Force on-device
        }
        
        // Create task
        return try await withCheckedThrowingContinuation { [logger] continuation in
            var resumed = false
            var recognitionTask: SFSpeechRecognitionTask?
            
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    if !resumed {
                        resumed = true
                        logger.error("Speech recognition error: \(error.localizedDescription)")
                        continuation.resume(throwing: ClientASRError.engineError(error.localizedDescription))
                    }
                    return
                }
                
                if let result = result, result.isFinal {
                    if !resumed {
                        resumed = true
                        let transcript = result.bestTranscription.formattedString
                        logger.info("Speech recognition completed: \(transcript.count) chars")
                        continuation.resume(returning: transcript)
                    }
                }
            }
            
            // Feed PCM data to the recognizer
            Task { [logger] in
                do {
                    for try await chunk in pcm {
                        // Convert PCM data to AVAudioPCMBuffer
                        // PCM format: 16-bit, 16kHz, mono
                        let format = AVAudioFormat(
                            commonFormat: .pcmFormatInt16,
                            sampleRate: 16000,
                            channels: 1,
                            interleaved: false
                        )!
                        
                        let frameCount = chunk.count / 2 // 16-bit = 2 bytes per sample
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
                            continue
                        }
                        
                        buffer.frameLength = AVAudioFrameCount(frameCount)
                        
                        // Copy PCM data
                        chunk.withUnsafeBytes { rawBufferPointer in
                            guard let baseAddress = rawBufferPointer.baseAddress else { return }
                            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
                            buffer.int16ChannelData?[0].update(from: int16Pointer, count: frameCount)
                        }
                        
                        request.append(buffer)
                    }
                    
                    // Signal end of audio
                    request.endAudio()
                    
                } catch {
                    if !resumed {
                        resumed = true
                        logger.error("Error feeding PCM data: \(error.localizedDescription)")
                        continuation.resume(throwing: ClientASRError.engineError(error.localizedDescription))
                    }
                    recognitionTask?.cancel()
                }
            }
        }
    }
}
