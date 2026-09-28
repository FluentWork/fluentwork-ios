import Foundation
import FluentWorkCore
import FluentWorkNetworking
import Testing

/// Every control frame this client can put on the wire, with every optional
/// field populated, so the encoding path is exercised in full rather than
/// through its narrowest branch.
///
/// These are the frames constructed in `DefaultSpeechSessionClient` and
/// `URLSessionSocketTransport` — the ones that actually leave the device.
private let framesThisClientSends: [WSControlFrame] = [
    .auth(ticket: "ticket"),
    .sessionStart(.init(
        materialID: "material-1",
        sceneType: "standup",
        voice: "voice-1",
        continueFromSessionID: "session-9"
    )),
    .userSpeechStart,
    .userSpeechEnd(text: "hello", turnID: "turn-1"),
    .clientTurnAbort(turnID: "turn-1", outcome: .timeout),
    .clientRescueRequest,
    .interrupt,
    .ping(ts: 1),
    .sessionEnd(reason: "user"),
]

/// `$defs` of the mirrored WSS v2 control-frame schema.
private func mirroredTransportDefs() throws -> [String: [String: Any]] {
    let data = try SharedSchemaMirror.wssControlFramesV2.data()
    let doc = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    try #require(
        doc["title"] as? String == "FluentWork WSS control frames v2",
        "loaded something other than the WSS v2 control-frame contract"
    )
    return try #require(doc["$defs"] as? [String: [String: Any]])
}

/// The `$def` whose `type` constant is `wireType`, or nil when the contract has
/// no frame by that name.
///
/// Found by looking rather than by a second hand-kept table of def names, so a
/// rename on the contract side cannot leave this pointing at a def nobody uses.
private func schemaDef(
    forWireType wireType: String,
    in defs: [String: [String: Any]]
) -> (name: String, def: [String: Any])? {
    for (name, entry) in defs {
        let properties = entry["properties"] as? [String: Any]
        let type = properties?["type"] as? [String: Any]
        if type?["const"] as? String == wireType {
            return (name, entry)
        }
    }
    return nil
}

/// The client's own frames are the published contract's frames.
///
/// `SharedSchemaMirror.wssControlFramesV2` is a copy of `fluentwork-infra`'s
/// contract, and every def in it is `additionalProperties: false`. That makes a
/// field this client sends and the contract does not declare more than a
/// documentation defect: a peer validating iOS's frames against the contract
/// rejects them, and the symptom on this side is silence.
///
/// It happened. `session.start` carried `continue_from_session_id` — the field
/// the gateway reads to make "continue where we left off" work — for as long as
/// the contract failed to declare it. `sessionStartPayloadKeysMatchTheGateway`
/// could not see it: that test pins key names against the backend's Go source
/// in prose, so it stayed green while the published contract was wrong.
@Test func everyKeyThisClientSendsIsDeclaredInTheMirroredSchema() throws {
    let defs = try mirroredTransportDefs()

    // Self-calibrating floor. If the walk ever stops seeing the file, "no def
    // declares anything" would make every assertion below vacuous; requiring at
    // least one def per frame to be checked turns that into a failure.
    #expect(
        defs.count >= framesThisClientSends.count,
        "the mirrored contract carries \(defs.count) $defs, fewer than the \(framesThisClientSends.count) frames this test sends — the walk has stopped seeing the file"
    )

    for frame in framesThisClientSends {
        let data = try WSControlFrameCodec.encode(frame)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let wireType = try #require(json["type"] as? String)

        let found = try #require(
            schemaDef(forWireType: wireType, in: defs),
            "\(wireType) can be sent, but the mirrored contract has no $def with that type constant"
        )
        #expect(
            found.def["additionalProperties"] as? Bool == false,
            "$defs.\(found.name) must set additionalProperties:false, otherwise sending an undeclared field is not a defect"
        )
        let properties = try #require(found.def["properties"] as? [String: Any])
        for key in json.keys.sorted() {
            #expect(
                properties[key] != nil,
                "\(wireType) sends \(key), which $defs.\(found.name) does not declare; with additionalProperties:false every frame carrying it is invalid"
            )
        }
    }
}
