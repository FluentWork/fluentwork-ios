import FluentWorkNetworking
import Foundation
import Testing
@testable import FluentWorkCore

/// **The ordering guard.**
///
/// `feed` is synchronous and playback is `async`, so a bridge is required — and
/// the obvious bridge, one `Task` per frame, breaks this silently. Out-of-order
/// audio is still audio; it just sounds wrong, and a test that only counted
/// frames would pass.
///
/// Frames must reach the player in the order they were fed.
@Test func engineBackedDecoderPlaysInTheOrderItWasFed() async throws {
    let recorder = FrameOrderRecorder()
    let decoder = EngineBackedTTSDecoder { frame in
        await recorder.record(frame.sequence)
    }

    try decoder.prepare(voiceId: "v", sampleRate: 16_000, codec: "pcm")
    // Enough frames, fed fast enough, that a per-frame `Task` would let the
    // executor reorder some of them. The odd sizes make each one distinct.
    for sequence in UInt32(1)...200 {
        try decoder.feed(
            seq: sequence,
            bytes: Data(repeating: 0x01, count: Int(sequence) + 1),
            turnId: "turn-1"
        )
    }

    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        await recorder.count == 200
    }
    #expect(await recorder.sequences == Array(UInt32(1)...200))
}

/// A second turn must not interleave with the first — that is the same
/// invariant across a boundary the dispatcher creates.
@Test func engineBackedDecoderKeepsTurnsInOrder() async throws {
    let recorder = FrameOrderRecorder()
    let decoder = EngineBackedTTSDecoder { frame in
        await recorder.record(frame.sequence)
    }

    for sequence in UInt32(1)...50 {
        try decoder.feed(seq: sequence, bytes: Data([0x01]), turnId: "turn-1")
    }
    for sequence in UInt32(51)...100 {
        try decoder.feed(seq: sequence, bytes: Data([0x01]), turnId: "turn-2")
    }

    try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
        await recorder.count == 100
    }
    #expect(await recorder.sequences == Array(UInt32(1)...100))
}

/// The dispatcher calls `prepare` before it claims frames, and a codec this path
/// cannot carry has to fail **there** — swallowing it would play noise.
@Test func engineBackedDecoderRejectsACodecItCannotCarry() {
    let decoder = EngineBackedTTSDecoder { _ in }
    #expect(throws: TTSDecoderError.unsupportedCodec("flac")) {
        try decoder.prepare(voiceId: "v", sampleRate: 16_000, codec: "flac")
    }
    #expect(throws: TTSDecoderError.unsupportedSampleRate(8_000)) {
        try decoder.prepare(voiceId: "v", sampleRate: 8_000, codec: "pcm")
    }
}

/// An empty payload is a protocol error, not silence.
@Test func engineBackedDecoderRejectsAnEmptyPayload() throws {
    let decoder = EngineBackedTTSDecoder { _ in }
    #expect(throws: TTSDecoderError.emptyPayload) {
        try decoder.feed(seq: 1, bytes: Data(), turnId: "turn-1")
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64,
    pollIntervalNanoseconds: UInt64 = 5_000_000,
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
            throw TimeoutError()
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
}

private struct TimeoutError: Error {}

private actor FrameOrderRecorder {
    private(set) var sequences: [UInt32] = []
    var count: Int { sequences.count }

    func record(_ sequence: UInt32) {
        sequences.append(sequence)
    }
}
