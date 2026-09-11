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

@Test func aiTurnEndMatchesBackendTraceWireFixture() throws {
    // Item 3 joint debug: same payload backend TestAITurnEndJSONMatchesIOSTraceWireFixture marshals.
    let json = #"{"type":"ai.turn.end","turn_id":"turn-1","outcome":"ok","log_id":"volc-abc123"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: "volc-abc123"))

    let encoded = try WSControlFrameCodec.encode(
        .aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: "volc-abc123")
    )
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object as NSDictionary == [
        "type": "ai.turn.end",
        "turn_id": "turn-1",
        "outcome": "ok",
        "log_id": "volc-abc123",
    ] as NSDictionary)
}

@Test func aiTurnEndWithOutcomeTimeout() throws {
    // B15: outcome="timeout" tells iOS the backend's 60s collectTurn window
    // expired; iOS dispatches .failed("turn_timeout") to match the 70s
    // client-side fallback behavior.
    let json = #"{"type":"ai.turn.end","turn_id":"turn-3","outcome":"timeout","log_id":"volc-xyz789"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .aiTurnEnd(turnID: "turn-3", outcome: .timeout, logID: "volc-xyz789"))
}

@Test func aiTurnEndMatchesBackendTimeoutWireFixture() throws {
    // Exact payload asserted by fluentwork-backend
    // TestHandler_AITurnEndCarriesTimeoutOutcomeOnWire.
    let json = #"{"type":"ai.turn.end","turn_id":"turn-timeout-1","outcome":"timeout","log_id":"volc-log-timeout"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .aiTurnEnd(turnID: "turn-timeout-1", outcome: .timeout, logID: "volc-log-timeout"))
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

@Test func aiTurnEndWithUnknownOutcomeDecodesAsNilOutcome() throws {
    let json = #"{"type":"ai.turn.end","turn_id":"turn-1","outcome":"not-a-contract-value"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .aiTurnEnd(turnID: "turn-1", outcome: nil, logID: nil))
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

// MARK: - I20 T-I20-1: client.turn.abort (recording abort, not B15 70s)

@Test func clientTurnAbortEncodesTimeoutOutcome() throws {
    let encoded = try WSControlFrameCodec.encode(
        .clientTurnAbort(turnID: "turn-1", outcome: .timeout)
    )
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(json["type"] as? String == "client.turn.abort")
    #expect(json["turn_id"] as? String == "turn-1")
    #expect(json["outcome"] as? String == "timeout")
    #expect(json["session_id"] == nil)
}

@Test func clientTurnAbortMatchesBackendTimeoutWireFixture() throws {
    // Exact payload TestHandler_ClientTurnAbortKeepsSessionAlive writes
    // after user.speech.start. Gateway must accept it with no error frame.
    let encoded = try WSControlFrameCodec.encode(
        .clientTurnAbort(turnID: "turn-1", outcome: .timeout)
    )
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(json as NSDictionary == [
        "type": "client.turn.abort",
        "turn_id": "turn-1",
        "outcome": "timeout",
    ] as NSDictionary)
}

@Test func clientTurnAbortDecodesWireFrame() throws {
    let json = #"{"type":"client.turn.abort","turn_id":"turn-2","outcome":"timeout"}"#
    let decoded = try WSControlFrameCodec.decode(Data(json.utf8))
    #expect(decoded == .clientTurnAbort(turnID: "turn-2", outcome: .timeout))
}

@Test func clientTurnAbortEncodesUserAbandonedAndError() throws {
    let abandoned = try WSControlFrameCodec.encode(
        .clientTurnAbort(turnID: "turn-3", outcome: .userAbandoned)
    )
    let abandonedJSON = try #require(JSONSerialization.jsonObject(with: abandoned) as? [String: Any])
    #expect(abandonedJSON["outcome"] as? String == "user_abandoned")

    let error = try WSControlFrameCodec.encode(
        .clientTurnAbort(turnID: "turn-4", outcome: .error)
    )
    let errorJSON = try #require(JSONSerialization.jsonObject(with: error) as? [String: Any])
    #expect(errorJSON["outcome"] as? String == "error")
}

@Test func clientTurnAbortRejectsOkOutcome() {
    let json = #"{"type":"client.turn.abort","turn_id":"turn-1","outcome":"ok"}"#
    #expect(throws: DecodingError.self) {
        try WSControlFrameCodec.decode(Data(json.utf8))
    }
}

/// **Pins a defect, deliberately. Do not read the assertions as intent.**
///
/// `session.start` is the one frame that carries what the practice session is
/// *about*, and the two ends do not agree on a single payload field name:
///
/// | | client sends (`WSControlFrame.CodingKeys`) | gateway reads (`voiceproto.SessionStart`) |
/// |---|---|---|
/// | material | `material_context` | `material_id` |
/// | scene | `scene` | `scene_type` |
/// | voice | `voice_id` | `voice` |
///
/// The gateway `json.Unmarshal`s into a struct with no matching tags, so all
/// three land empty and stay empty —
/// `voicegateway/provider_volc_duplex.go:instructionsForSessionStart` then
/// emits only its fixed preamble. Every backend test sends
/// `voiceproto.SessionStart{Type: ...}` with those fields unset, so the
/// `scene` and `material` branches have never run with a value in CI either.
///
/// This test pins the **current** bytes rather than the correct ones on purpose.
/// Asserting the gateway's names here would mean changing what the model is
/// told mid-conversation, on a path that is only verifiable on a device — that
/// is a behaviour change, not a rename, and it belongs in the commit that
/// implements session context (meta `77_` P1-25), not in a passing test.
///
/// When that commit lands, this test **changes** to assert `material_id` /
/// `scene_type` / `voice`. Failing here is not the goal; being the place the
/// mismatch is impossible to forget is.
@Test func sessionStartPayloadKeysDoNotMatchTheGateway() throws {
    let data = try WSControlFrameCodec.encode(
        .sessionStart(.init(materialContext: "material-1", scene: "standup", voiceID: "voice-1"))
    )
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["type"] as? String == "session.start")
    #expect(json["material_context"] as? String == "material-1")
    #expect(json["scene"] as? String == "standup")
    #expect(json["voice_id"] as? String == "voice-1")

    // The names the gateway actually reads. All three are absent, which is the
    // whole defect.
    #expect(json["material_id"] == nil)
    #expect(json["scene_type"] == nil)
    #expect(json["voice"] == nil)
}
