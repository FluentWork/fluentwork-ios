import Foundation
import FluentWorkNetworking
import Testing

/// Raw `feedback.badge` bytes the backend BadgeEmitter writes over WSS
/// (`fluentwork-backend/internal/voicegateway/handler_dev_echo_test.go`
/// asserts every field on a live connection). `session_id` and `dedupe_key`
/// are backend correlation fields iOS does not model — decoding must stay
/// tolerant of them while reading every field iOS consumes.
private let backendDevEchoFeedbackBadgeJSON = #"""
{"type":"feedback.badge","badge":"Let's ship it.","phrase_block_id":"block-ship-it","tier":"soft","session_id":"s1","turn_id":"turn-e2e-1","dedupe_key":"s1|turn-e2e-1|block-ship-it"}
"""#

@Test func feedbackBadgeDecodesBackendWireFrame() throws {
    let decoded = try WSControlFrameCodec.decode(
        Data(backendDevEchoFeedbackBadgeJSON.utf8)
    )
    #expect(
        decoded == .feedbackBadge(
            badge: "Let's ship it.",
            phraseBlockID: "block-ship-it",
            tier: .soft,
            turnID: "turn-e2e-1"
        )
    )
}

@Test func feedbackBadgeMissingTierFallsBackToNil() throws {
    // Runbook §6.1: pre-B12 backend versions emit `feedback.badge` without
    // `tier`. Decode must succeed with `tier == nil`; the cross-cutting
    // reducer then falls back to `.unknown` for display.
    let json = #"{"type":"feedback.badge","badge":"表达自然","phrase_block_id":"block-1","turn_id":"turn-1"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(
        decoded == .feedbackBadge(
            badge: "表达自然",
            phraseBlockID: "block-1",
            tier: nil,
            turnID: "turn-1"
        )
    )
}

@Test func feedbackBadgeMissingTurnIDDecodesAsNil() throws {
    // `turn_id` was added to the backend emit payload in the B12 fix; frames
    // that predate it (or omit it) must not fail the whole decode.
    let json = #"{"type":"feedback.badge","badge":"ship it","phrase_block_id":"block-2","tier":"highlight"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(
        decoded == .feedbackBadge(
            badge: "ship it",
            phraseBlockID: "block-2",
            tier: .highlight,
            turnID: nil
        )
    )
}

@Test func feedbackBadgeRejectsMisspelledTier() {
    // Runbook §6.2: `FeedbackBadgeTier` is a strict enum; a backend typo like
    // `"Soft"` / `"SOFT"` must surface as a DecodingError so the team treats
    // it as a backend bug instead of silently dropping the badge.
    let json = #"{"type":"feedback.badge","badge":"ship it","phrase_block_id":"block-2","tier":"Soft"}"#
    #expect(throws: DecodingError.self) {
        _ = try WSControlFrameCodec.decode(Data(json.utf8))
    }
}
