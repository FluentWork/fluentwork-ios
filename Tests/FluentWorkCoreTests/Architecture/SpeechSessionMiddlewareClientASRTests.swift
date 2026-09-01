import Testing
import Foundation
@testable import FluentWorkCore
import FluentWorkNetworking
import FluentWorkDiagnostics
import FactoryKit

/// B13: Tests for client-side ASR integration in SpeechSessionMiddleware.
///
/// These tests verify that:
/// 1. PCM chunks are correctly buffered during speech turns
/// 2. Buffered PCM is passed to the transcriber
/// 3. Transcriber results (or nil on failure) are sent to the backend
/// 4. Telemetry events are emitted correctly
@Suite("SpeechSessionMiddleware Client ASR")
struct SpeechSessionMiddlewareClientASRTests {
    
    // MARK: - Test 1: PCM Buffer Captures During Turn
    
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
        
        // Wait for async transcription to complete
        try await Task.sleep(for: .milliseconds(100))
        
        // Verify transcriber received all buffered chunks in order
        let callCount = await transcriber.transcribeCalls
        #expect(callCount == 1)
        
        let receivedChunks = await transcriber.lastReceivedPCMChunks()
        #expect(receivedChunks.count == 3)
        #expect(receivedChunks[0] == chunk1)
        #expect(receivedChunks[1] == chunk2)
        #expect(receivedChunks[2] == chunk3)
    }
    
    // MARK: - Test 2: PCM Buffer Clears After Turn
    
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
        try await Task.sleep(for: .milliseconds(100))
        
        // Second turn - should start with empty buffer
        audioEngine.emit(.speechStarted)
        await Task.yield()
        audioEngine.emit(.pcmChunk(Data([0x03, 0x04])))
        await Task.yield()
        audioEngine.emit(.speechEnded)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(100))
        
        // Verify second turn only received its own chunk
        let callCount = await transcriber.transcribeCalls
        #expect(callCount == 2)
        
        let secondTurnChunks = await transcriber.pcmChunksFromCall(1)
        #expect(secondTurnChunks.count == 1)
        #expect(secondTurnChunks[0] == Data([0x03, 0x04]))
    }
    
    // MARK: - Test 3: Client ASR Success Within Timeout
    
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
        
        // Wait for transcription to complete
        try await Task.sleep(for: .milliseconds(500))
        
        // Verify user.speech.end was sent with client ASR text
        let calls = await speechClient.speechBoundaryCalls
        #expect(calls.count == 2)
        let endCall = calls[1]
        #expect(endCall.started == false)
        #expect(endCall.text == "你好世界")
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
    
    // MARK: - Test 6: PCM Not Buffered Outside Speech Turn
    
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
        
        // Verify only the chunk during speech was buffered
        let receivedChunks = await transcriber.lastReceivedPCMChunks()
        #expect(receivedChunks.count == 1)
        #expect(receivedChunks[0] == Data([0x05, 0x06]))
    }
    
    // MARK: - Test 7: Telemetry Events Emitted Correctly
    
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
        
        // Verify speech_client_asr_completed event was tracked
        let allEvents = await tracker.getEvents()
        let asrEvents = allEvents.filter { $0.name == "speech_client_asr_completed" }
        #expect(asrEvents.count == 1)
        
        let event = asrEvents[0]
        #expect(event.properties["turn_id"] == "turn-1")
        #expect(event.properties["text_length"] == "18") // "test transcription".count
        #expect(event.properties["source"] == "ios")
        #expect(event.properties["elapsed_ms"] != nil)
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
        
        func recordCall(_ call: BoundaryCall) {
            speechBoundaryCalls.append(call)
        }
        
        func getCalls() -> [BoundaryCall] {
            speechBoundaryCalls
        }
    }
    
    private let state = State()
    
    var speechBoundaryCalls: [BoundaryCall] {
        get async { await state.getCalls() }
    }
    
    func startSession() async throws {}
    func submitTranscript(_ text: String) async {}
    func sendSpeechBoundary(started: Bool, turnID: String?, text: String?) async throws {
        await state.recordCall(BoundaryCall(started: started, turnID: turnID, text: text))
    }
    func sendAudioPCM(_ data: Data) async throws {}
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
