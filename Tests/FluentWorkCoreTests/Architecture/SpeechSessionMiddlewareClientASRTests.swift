import Testing
import Foundation
@testable import FluentWorkCore
import FluentWorkNetworking
import FluentWorkDiagnostics
import FactoryKit

/// B14: Tests for SpeechSessionMiddleware server-side ASR flow.
///
/// After B14, the middleware no longer runs a client-side ASR transcriber.
/// PCM chunks are forwarded to `sendAudioPCM` for backend ASR; the
/// authoritative transcript is relayed back via WSS `client.asr.transcription`
/// and dispatched as `serverASRReceived(text:turnID:)` which triggers an
/// immediate `sendSpeechBoundary(text:)` call for badge hit detection.
///
/// These tests verify that:
/// 1. PCM chunks are forwarded to `sendAudioPCM` in order
/// 2. Boundary frames are sent with `text: nil` so the backend can use its
///    own transcript for badge detection
/// 3. Speech boundary frames carry the right turn IDs
/// 4. Telemetry `speech_turn_ended` event is emitted at speech-end time
@Suite("SpeechSessionMiddleware Client ASR")
struct SpeechSessionMiddlewareClientASRTests {
    
    // MARK: - Test 1: PCM Chunks Forwarded to sendAudioPCM During Turn
    //
    // B14 removed client-side ASR transcription; PCM chunks are no longer
    // buffered for a local transcriber. Instead, every PCM chunk is
    // forwarded to `sendAudioPCM` so the backend can run server-side ASR.

    @MainActor
    @Test func pcmBufferCapturesDuringTurn() async throws {
        let audioEngine = ControllableAudioEngine()
        let speechClient = RecordingSpeechClient()
        let transcriber = RecordingClientASRTranscriber()
        let tracker = RecordingTracker()
        let container = makeTestContainer(
            audioEngine: audioEngine,
            speechClient: speechClient,
            tracker: tracker,
            clientASRTranscriber: transcriber
        )

        let store = AppStoreFactory.make(container: container)

        // Start session
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))

        // Simulate speech turn with 3 PCM chunks
        audioEngine.emit(.speechStarted)
        await Task.yield()

        let chunk1 = Data([0x01, 0x02, 0x03, 0x04])
        let chunk2 = Data([0x05, 0x06, 0x07, 0x08])
        let chunk3 = Data([0x09, 0x0A, 0x0B, 0x0C])

        audioEngine.emit(.pcmChunk(chunk1))
        await Task.yield()
        audioEngine.emit(.pcmChunk(chunk2))
        await Task.yield()
        audioEngine.emit(.pcmChunk(chunk3))
        await Task.yield()

        // End speech turn
        audioEngine.emit(.speechEnded)
        await Task.yield()

        // Wait for async sends to complete
        try await Task.sleep(for: .milliseconds(100))

        // B14: Verify all PCM chunks were forwarded to sendAudioPCM in order
        let payloads = await speechClient.audioPayloads
        #expect(payloads == [chunk1, chunk2, chunk3])
    }
    
    // MARK: - Test 2: PCM Chunks Forwarded Across Multiple Turns
    //
    // B14: PCM chunks are forwarded in order across multiple turns; no
    // transcriber buffering is needed (server-side ASR handles it).

    @MainActor
    @Test func pcmBufferClearsAfterTurn() async throws {
        let audioEngine = ControllableAudioEngine()
        let speechClient = RecordingSpeechClient()
        let transcriber = RecordingClientASRTranscriber()
        let tracker = RecordingTracker()
        let container = makeTestContainer(
            audioEngine: audioEngine,
            speechClient: speechClient,
            tracker: tracker,
            clientASRTranscriber: transcriber
        )

        let store = AppStoreFactory.make(container: container)

        store.dispatch(.speakingRoom(.session(.sessionStartTap)))

        // First turn
        audioEngine.emit(.speechStarted)
        await Task.yield()
        audioEngine.emit(.pcmChunk(Data([0x01, 0x02])))
        await Task.yield()
        audioEngine.emit(.speechEnded)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        // Second turn - PCM chunks should still be forwarded in order
        audioEngine.emit(.speechStarted)
        await Task.yield()
        audioEngine.emit(.pcmChunk(Data([0x03, 0x04])))
        await Task.yield()
        audioEngine.emit(.speechEnded)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        // Verify both turns' chunks were forwarded in order
        let payloads = await speechClient.audioPayloads
        #expect(payloads == [Data([0x01, 0x02]), Data([0x03, 0x04])])
    }
    
    // MARK: - Test 3: Server-Side ASR Is Used In Place Of Client ASR
    //
    // B14 removed the client ASR transcriber; the middleware now sends
    // `sendSpeechBoundary(text: nil)` at speech-end time so the backend
    // can use its own (server-side) transcript for badge hit detection.
    // The authoritative transcript later arrives via the
    // `serverASRReceived` action (relayed from WSS `client.asr.transcription`).

    @MainActor
    @Test func clientASRSuccessWithinTimeout() async throws {
        let audioEngine = ControllableAudioEngine()
        let speechClient = RecordingSpeechClient()
        let tracker = RecordingTracker()
        let transcriber = MockClientASRTranscriber(
            result: .success("你好世界"),
            delay: .milliseconds(300) // Well within 800ms timeout
        )
        let container = makeTestContainer(
            audioEngine: audioEngine,
            speechClient: speechClient,
            tracker: tracker,
            clientASRTranscriber: transcriber
        )

        let store = AppStoreFactory.make(container: container)

        store.dispatch(.speakingRoom(.session(.sessionStartTap)))

        // Simulate speech turn
        audioEngine.emit(.speechStarted)
        await Task.yield()
        audioEngine.emit(.pcmChunk(Data([0x01, 0x02])))
        await Task.yield()
        audioEngine.emit(.speechEnded)
        await Task.yield()

        // Wait for boundary to be sent
        try await Task.sleep(for: .milliseconds(200))

        // B14: user.speech.end is sent with text=nil so the backend can use
        // its own transcript for badge detection.
        let calls = await speechClient.speechBoundaryCalls
        #expect(calls.count == 2)
        let endCall = calls[1]
        #expect(endCall.started == false)
        #expect(endCall.text == nil)
        #expect(endCall.turnID == "turn-1")
    }
    
    // MARK: - Test 4: Client ASR Timeout Falls Back to Nil
    
    @MainActor
    @Test func clientASRTimeoutFallsBackToNil() async throws {
        let audioEngine = ControllableAudioEngine()
        let speechClient = RecordingSpeechClient()
        let tracker = RecordingTracker()
        let transcriber = MockClientASRTranscriber(
            result: .success("never arrives"),
            delay: .milliseconds(1000) // Exceeds 800ms timeout
        )
        let container = makeTestContainer(
            audioEngine: audioEngine,
            speechClient: speechClient,
            tracker: tracker,
            clientASRTranscriber: transcriber
        )
        
        let store = AppStoreFactory.make(container: container)
        
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        
        audioEngine.emit(.speechStarted)
        await Task.yield()
        audioEngine.emit(.pcmChunk(Data([0x01, 0x02])))
        await Task.yield()
        audioEngine.emit(.speechEnded)
        await Task.yield()
        
        // Wait for timeout to trigger
        try await Task.sleep(for: .milliseconds(900))
        
        // Verify user.speech.end was sent with nil (fallback to server-side ASR)
        let calls = await speechClient.speechBoundaryCalls
        #expect(calls.count == 2)
        let endCall = calls[1]
        #expect(endCall.text == nil)
    }
    
    // MARK: - Test 5: Client ASR Not Available Falls Back to Nil
    
    @MainActor
    @Test func clientASRNotAvailableFallsBackToNil() async throws {
        let audioEngine = ControllableAudioEngine()
        let speechClient = RecordingSpeechClient()
        let tracker = RecordingTracker()
        let transcriber = MockClientASRTranscriber(
            result: .failure(ClientASRError.notAvailable),
            delay: .milliseconds(0)
        )
        let container = makeTestContainer(
            audioEngine: audioEngine,
            speechClient: speechClient,
            tracker: tracker,
            clientASRTranscriber: transcriber
        )
        
        let store = AppStoreFactory.make(container: container)
        
        store.dispatch(.speakingRoom(.session(.sessionStartTap)))
        
        audioEngine.emit(.speechStarted)
        await Task.yield()
        audioEngine.emit(.pcmChunk(Data([0x01, 0x02])))
        await Task.yield()
        audioEngine.emit(.speechEnded)
        await Task.yield()
        
        try await Task.sleep(for: .milliseconds(100))
        
        // Verify user.speech.end was sent with nil
        let calls = await speechClient.speechBoundaryCalls
        #expect(calls.count == 2)
        let endCall = calls[1]
        #expect(endCall.text == nil)
    }
    
    // MARK: - Test 6: PCM Chunks Outside Speech Turn Are Also Forwarded
    //
    // B14: PCM chunks are forwarded to sendAudioPCM regardless of speech
    // state — no client-side buffering is required. Only the speech boundary
    // frames (start/end) are gated by VAD events.

    @MainActor
    @Test func pcmNotBufferedOutsideSpeechTurn() async throws {
        let audioEngine = ControllableAudioEngine()
        let speechClient = RecordingSpeechClient()
        let tracker = RecordingTracker()
        let transcriber = RecordingClientASRTranscriber()
        let container = makeTestContainer(
            audioEngine: audioEngine,
            speechClient: speechClient,
            tracker: tracker,
            clientASRTranscriber: transcriber
        )

        let store = AppStoreFactory.make(container: container)

        store.dispatch(.speakingRoom(.session(.sessionStartTap)))

        // Send PCM chunks BEFORE speechStarted
        audioEngine.emit(.pcmChunk(Data([0x01, 0x02])))
        await Task.yield()
        audioEngine.emit(.pcmChunk(Data([0x03, 0x04])))
        await Task.yield()

        // Now start speech
        audioEngine.emit(.speechStarted)
        await Task.yield()
        audioEngine.emit(.pcmChunk(Data([0x05, 0x06])))
        await Task.yield()
        audioEngine.emit(.speechEnded)
        await Task.yield()

        try await Task.sleep(for: .milliseconds(100))

        // B14: All PCM chunks (both before and during speech) are forwarded
        // to sendAudioPCM in order.
        let payloads = await speechClient.audioPayloads
        #expect(payloads == [
            Data([0x01, 0x02]),
            Data([0x03, 0x04]),
            Data([0x05, 0x06]),
        ])
    }
    
    // MARK: - Test 7: speech_turn_ended Telemetry Event
    //
    // B14 removed the `speech_client_asr_completed` event. Instead, the
    // middleware emits `speech_turn_ended` at speech-end time (with
    // `stage: "turn_boundary"`).

    @MainActor
    @Test func telemetryEventsEmittedCorrectly() async throws {
        let audioEngine = ControllableAudioEngine()
        let speechClient = RecordingSpeechClient()
        let tracker = RecordingTracker()
        let transcriber = MockClientASRTranscriber(
            result: .success("test transcription"),
            delay: .milliseconds(200)
        )
        let container = makeTestContainer(
            audioEngine: audioEngine,
            speechClient: speechClient,
            tracker: tracker,
            clientASRTranscriber: transcriber
        )

        let store = AppStoreFactory.make(container: container)

        store.dispatch(.speakingRoom(.session(.sessionStartTap)))

        audioEngine.emit(.speechStarted)
        await Task.yield()
        audioEngine.emit(.pcmChunk(Data([0x01, 0x02])))
        await Task.yield()
        audioEngine.emit(.speechEnded)
        await Task.yield()

        try await Task.sleep(for: .milliseconds(400))

        // Verify speech_turn_ended event was tracked at speech-end time
        let allEvents = await tracker.getEvents()
        let turnEndedEvents = allEvents.filter { $0.name == "speech_turn_ended" }
        #expect(turnEndedEvents.count == 1)

        let event = turnEndedEvents[0]
        #expect(event.properties["turn_id"] == "turn-1")
        #expect(event.properties["source"] == "ios")
        #expect(event.properties["stage"] == "turn_boundary")
    }
}

// MARK: - Test Helpers

/// Mock transcriber that records all received PCM chunks
final class RecordingClientASRTranscriber: ClientASRTranscriber, @unchecked Sendable {
    private actor State {
        var transcribeCalls: Int = 0
        var recordedPCMChunks: [[Data]] = []
        
        func recordCall(_ chunks: [Data]) {
            recordedPCMChunks.append(chunks)
            transcribeCalls += 1
        }
        
        func getTranscribeCalls() -> Int {
            transcribeCalls
        }
        
        func getLastReceivedPCMChunks() -> [Data] {
            guard !recordedPCMChunks.isEmpty else { return [] }
            return recordedPCMChunks.last!
        }
        
        func getPCMChunksFromCall(_ index: Int) -> [Data] {
            guard index < recordedPCMChunks.count else { return [] }
            return recordedPCMChunks[index]
        }
    }
    
    private let state = State()
    
    var transcribeCalls: Int {
        get async { await state.getTranscribeCalls() }
    }
    
    func transcribe(pcm: AsyncStream<Data>) async throws -> String {
        var chunks: [Data] = []
        for await chunk in pcm {
            chunks.append(chunk)
        }
        await state.recordCall(chunks)
        return "mock result"
    }
    
    func lastReceivedPCMChunks() async -> [Data] {
        await state.getLastReceivedPCMChunks()
    }
    
    func pcmChunksFromCall(_ index: Int) async -> [Data] {
        await state.getPCMChunksFromCall(index)
    }
}

/// Mock transcriber with configurable behavior
struct MockClientASRTranscriber: ClientASRTranscriber {
    let result: Result<String, Error>
    let delay: Duration
    
    func transcribe(pcm: AsyncStream<Data>) async throws -> String {
        // Consume the stream
        for await _ in pcm {
            // Discard
        }
        
        // Simulate processing delay
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        
        return try result.get()
    }
}

/// Recording speech client for verifying sendSpeechBoundary calls
final class RecordingSpeechClient: SpeechSessionClientProtocol, @unchecked Sendable {
    struct BoundaryCall {
        let started: Bool
        let turnID: String?
        let text: String?
    }

    private actor State {
        var speechBoundaryCalls: [BoundaryCall] = []
        var audioPayloads: [Data] = []

        func recordCall(_ call: BoundaryCall) {
            speechBoundaryCalls.append(call)
        }

        func recordAudioPayload(_ data: Data) {
            audioPayloads.append(data)
        }

        func getCalls() -> [BoundaryCall] {
            speechBoundaryCalls
        }

        func getAudioPayloads() -> [Data] {
            audioPayloads
        }
    }

    private let state = State()

    var speechBoundaryCalls: [BoundaryCall] {
        get async { await state.getCalls() }
    }

    var audioPayloads: [Data] {
        get async { await state.getAudioPayloads() }
    }

    func startSession() async throws {}
    func submitTranscript(_ text: String) async {}
    func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {
        await state.recordCall(BoundaryCall(started: started, turnID: turnID, text: text))
    }
    func sendAudioPCM(_ data: Data) async throws {
        await state.recordAudioPayload(data)
    }
    func transportEvents() -> AsyncStream<SocketTransportEvent> {
        AsyncStream { _ in }
    }
    func sendDegradedTextMessage(_ text: String) async throws -> PostMessageResponse {
        throw APIError.backend(code: "not_implemented", message: "test stub")
    }
    func pollReview(sessionID: String) async throws -> ReviewPollResponse {
        ReviewPollResponse(sessionID: sessionID, status: .ready, review: nil)
    }
    func endSession() async {}
}

/// Recording tracker for telemetry verification
final class RecordingTracker: TrackerClientProtocol, @unchecked Sendable {
    struct Event: Sendable {
        let name: String
        let properties: [String: String]
    }
    
    private actor State {
        var events: [Event] = []
        
        func recordEvent(_ event: Event) {
            events.append(event)
        }
        
        func getEvents() -> [Event] {
            events
        }
    }
    
    private let state = State()
    
    func track(event: String, properties: [String: String]) {
        Task { await state.recordEvent(Event(name: event, properties: properties)) }
    }
    
    func getEvents() async -> [Event] {
        await state.getEvents()
    }
}

// Helper to set up test container with injectable dependencies
func makeTestContainer(
    audioEngine: AudioEngineProtocol,
    speechClient: SpeechSessionClientProtocol,
    tracker: TrackerClientProtocol,
    clientASRTranscriber: ClientASRTranscriber
) -> Container {
    let container = Container()
    container.reset()
    container.audioEngine.register { audioEngine }
    container.speechSessionClient.register { speechClient }
    container.tracker.register { tracker }
    container.clientASRTranscriber.register { clientASRTranscriber }
    return container
}

/// Controllable audio engine for tests
final class ControllableAudioEngine: AudioEngineProtocol, @unchecked Sendable {
    private let stream: AsyncStream<AudioEngineEvent>
    private let continuation: AsyncStream<AudioEngineEvent>.Continuation
    
    init() {
        let pair = AsyncStream.makeStream(of: AudioEngineEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }
    
    func startCapture() async throws {}
    func stopCapture() async {}
    func play(frame: WSAudioFrame) async {}
    func interruptNow() async {}
    
    func events() -> AsyncStream<AudioEngineEvent> {
        stream
    }
    
    func emit(_ event: AudioEngineEvent) {
        continuation.yield(event)
    }
}
