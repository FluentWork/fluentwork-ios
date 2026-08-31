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
