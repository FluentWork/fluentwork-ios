import Testing
import Foundation
@testable import FluentWorkCore

@Test func greetingUsesProvidedName() {
    #expect(PackageBaseline.greeting(for: "FluentWork") == "Hello, FluentWork.")
}

@Test func repoNameMatchesRepository() {
    #expect(PackageBaseline.repoName == "fluentwork-ios")
}

@Test func sharedSchemaMirrorsAreBundled() throws {
    let transport = try SharedSchemaMirror.wssControlFramesV1.data()
    let transportV2 = try SharedSchemaMirror.wssControlFramesV2.data()
    let events = try SharedSchemaMirror.speechObservabilityEventsV1.data()

    let transportDoc = try #require(
        JSONSerialization.jsonObject(with: transport) as? [String: Any]
    )
    let transportV2Doc = try #require(
        JSONSerialization.jsonObject(with: transportV2) as? [String: Any]
    )
    let eventDoc = try #require(
        JSONSerialization.jsonObject(with: events) as? [String: Any]
    )

    #expect(transportDoc["title"] as? String == "FluentWork WSS control frames v1")
    #expect(transportV2Doc["title"] as? String == "FluentWork WSS control frames v2")
    #expect(eventDoc["title"] as? String == "FluentWork speech observability events v1")

    let transportDefs = try #require(transportDoc["$defs"] as? [String: Any])
    let transportV2Defs = try #require(transportV2Doc["$defs"] as? [String: Any])
    let eventDefs = try #require(eventDoc["$defs"] as? [String: Any])

    #expect(transportDefs["aiTurnEnd"] != nil)
    #expect(transportV2Defs["aiTTSStart"] != nil)
    #expect(transportV2Defs["aiTTSEnd"] != nil)
    #expect(eventDefs["speechTurnEnded"] != nil)
}

@Test func wssControlFramesV2SchemaPinsTTSFramesAndKeepsAudioBinary() throws {
    // Pins the frozen WSS V2 contract mirrored from fluentwork-infra.
    // `ai.tts.start` / `ai.tts.end` are JSON control frames; `ai.tts.audio`
    // is documented in $defs only and must not appear in JSON oneOf.
    let transport = try SharedSchemaMirror.wssControlFramesV2.data()
    let transportDoc = try #require(
        JSONSerialization.jsonObject(with: transport) as? [String: Any]
    )
    let defs = try #require(transportDoc["$defs"] as? [String: Any])
    let oneOf = try #require(transportDoc["oneOf"] as? [[String: Any]])
    let refs = Set(oneOf.compactMap { $0["$ref"] as? String })

    let start = try #require(defs["aiTTSStart"] as? [String: Any])
    let startProperties = try #require(start["properties"] as? [String: Any])
    let sampleRate = try #require(startProperties["sample_rate"] as? [String: Any])
    let codec = try #require(startProperties["codec"] as? [String: Any])

    #expect(startProperties["turn_id"] != nil)
    #expect(startProperties["voice_id"] != nil)
    let sampleRates = try #require(sampleRate["enum"] as? [NSNumber])
    #expect(sampleRates.map(\.intValue) == [16_000, 24_000, 48_000])
    #expect(codec["enum"] as? [String] == ["opus", "pcm"])

    let end = try #require(defs["aiTTSEnd"] as? [String: Any])
    let endProperties = try #require(end["properties"] as? [String: Any])
    let completion = try #require(endProperties["completion_status"] as? [String: Any])
    #expect(completion["enum"] as? [String] == ["ok", "interrupted", "error"])

    #expect(defs["aiTTSAudio"] != nil)
    #expect(refs.contains("#/$defs/aiTTSStart"))
    #expect(refs.contains("#/$defs/aiTTSEnd"))
    #expect(refs.contains("#/$defs/clientTurnAbort"))
    #expect(!refs.contains("#/$defs/aiTTSAudio"))

    let abort = try #require(defs["clientTurnAbort"] as? [String: Any])
    let abortProperties = try #require(abort["properties"] as? [String: Any])
    let abortType = try #require(abortProperties["type"] as? [String: Any])
    let abortOutcome = try #require(abortProperties["outcome"] as? [String: Any])
    #expect(abortType["const"] as? String == "client.turn.abort")
    #expect(abortOutcome["const"] as? String == "timeout")
    #expect(abortProperties["turn_id"] != nil)
    #expect(abortProperties["session_id"] == nil)

    let textDelta = try #require(defs["aiTextDelta"] as? [String: Any])
    let textDeltaProperties = try #require(textDelta["properties"] as? [String: Any])
    #expect(textDeltaProperties["server_ts_ms"] != nil)
}

@Test func wssControlFramesSchemaHasUserSpeechEndTurnAndText() throws {
    // Pins the wire contract used for ASR segmentation. If the schema drops
    // `turn_id` or `text` from `user.speech.end` the cross-team 联调 breaks:
    // backend's BadgeEmitter key is `session|turn|phrase_block` and iOS must
    // send the same turn_id for the LRU to dedupe correctly.
    let transport = try SharedSchemaMirror.wssControlFramesV1.data()
    let transportDoc = try #require(
        JSONSerialization.jsonObject(with: transport) as? [String: Any]
    )
    let defs = try #require(transportDoc["$defs"] as? [String: Any])
    let userSpeechEnd = try #require(defs["userSpeechEnd"] as? [String: Any])
    let properties = try #require(userSpeechEnd["properties"] as? [String: Any])

    #expect(properties["text"] != nil)
    #expect(properties["turn_id"] != nil)
}

@Test func wssControlFramesSchemaHasFeedbackBadgePhraseBlockAndTier() throws {
    // Pins the wire contract used to enrich badge display. iOS reads both
    // fields; backend's `NewFeedbackBadge` always populates them.
    let transport = try SharedSchemaMirror.wssControlFramesV1.data()
    let transportDoc = try #require(
        JSONSerialization.jsonObject(with: transport) as? [String: Any]
    )
    let defs = try #require(transportDoc["$defs"] as? [String: Any])
    let feedbackBadge = try #require(defs["feedbackBadge"] as? [String: Any])
    let properties = try #require(feedbackBadge["properties"] as? [String: Any])

    #expect(properties["badge"] != nil)
    #expect(properties["phrase_block_id"] != nil)

    let tier = try #require(properties["tier"] as? [String: Any])
    #expect(tier["enum"] as? [String] == ["soft", "highlight", "celebrate"])
}

@Test func speechObservabilitySchemaHasTurnIDAndSource() throws {
    // Pins the observability contract used for ASR-segmented logging. The
    // iOS middleware emits `speech_turn_ended` with `turn_id` + `source` so
    // backend and iOS can correlate one turn end-to-end.
    let events = try SharedSchemaMirror.speechObservabilityEventsV1.data()
    let eventDoc = try #require(
        JSONSerialization.jsonObject(with: events) as? [String: Any]
    )
    let defs = try #require(eventDoc["$defs"] as? [String: Any])
    let eventBase = try #require(defs["eventBase"] as? [String: Any])
    let properties = try #require(eventBase["properties"] as? [String: Any])

    #expect(properties["turn_id"] != nil)
    let source = try #require(properties["source"] as? [String: Any])
    #expect((source["enum"] as? [String])?.contains("ios") == true)
}
