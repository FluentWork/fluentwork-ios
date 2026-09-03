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

// MARK: - B15: ai.turn.end with explicit outcome + B15-I3: log_id trace

@Test func aiTurnEndWithOutcomeOk() throws {
    // B15: backend stamps outcome="ok" when the turn completed normally.
    // B15-I3: log_id carries the Volcengine vendor trace identifier.
    let json = #"{"type":"ai.turn.end","turn_id":"turn-1","outcome":"ok","log_id":"volc-abc123"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: "volc-abc123"))
}

@Test func aiTurnEndWithOutcomeTimeout() throws {
    // B15: outcome="timeout" tells iOS the backend's 60s collectTurn window
    // expired; iOS dispatches .failed("turn_timeout") to match the 70s
    // client-side fallback behavior.
    let json = #"{"type":"ai.turn.end","turn_id":"turn-3","outcome":"timeout","log_id":"volc-xyz789"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .aiTurnEnd(turnID: "turn-3", outcome: .timeout, logID: "volc-xyz789"))
}

@Test func aiTurnEndWithOutcomePartial() throws {
    let json = #"{"type":"ai.turn.end","turn_id":"turn-2","outcome":"partial"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .aiTurnEnd(turnID: "turn-2", outcome: .partial, logID: nil))
}

@Test func aiTurnEndWithOutcomeError() throws {
    let json = #"{"type":"ai.turn.end","turn_id":"turn-4","outcome":"error"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .aiTurnEnd(turnID: "turn-4", outcome: .error, logID: nil))
}

@Test func aiTurnEndWithoutOutcomeDecodesAsNil() throws {
    // B15: pre-B15 backend versions do not emit `outcome`. Decode must
    // succeed with `outcome == nil` so the new field is backward-compatible.
    // B15-I3: pre-I3 backend versions also omit log_id; must decode as nil.
    let json = #"{"type":"ai.turn.end","turn_id":"turn-1"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .aiTurnEnd(turnID: "turn-1", outcome: nil, logID: nil))
}

@Test func aiTurnEndWithTurnIDOnly() throws {
    // Minimal ai.turn.end — outcome and log_id both optional.
    let json = #"{"type":"ai.turn.end"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .aiTurnEnd(turnID: nil, outcome: nil, logID: nil))
}
