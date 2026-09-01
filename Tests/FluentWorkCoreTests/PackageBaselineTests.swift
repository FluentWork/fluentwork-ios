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
    let events = try SharedSchemaMirror.speechObservabilityEventsV1.data()

    let transportDoc = try #require(
        JSONSerialization.jsonObject(with: transport) as? [String: Any]
    )
    let eventDoc = try #require(
        JSONSerialization.jsonObject(with: events) as? [String: Any]
    )

    #expect(transportDoc["title"] as? String == "FluentWork WSS control frames v1")
    #expect(eventDoc["title"] as? String == "FluentWork speech observability events v1")

    let transportDefs = try #require(transportDoc["$defs"] as? [String: Any])
    let eventDefs = try #require(eventDoc["$defs"] as? [String: Any])

    #expect(transportDefs["aiTurnEnd"] != nil)
    #expect(eventDefs["speechTurnEnded"] != nil)
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
