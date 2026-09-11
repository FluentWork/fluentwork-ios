import Foundation
@testable import FluentWorkNetworking
import Testing

/// The gateway's error codes must all reach the learner as human text.
///
/// `77_` P1-19: the copy table covered five of the twelve codes the gateway
/// sends. The other seven rendered as `[provider_start_failed] ...` — raw
/// machine text — and the split had no rationale: `provider_audio_failed` got a
/// careful line while its sibling from the same subsystem did not.
///
/// Nothing caught it, because a missing entry is not an error — the `default`
/// branch happily produced a string. The list below is therefore the guard:
/// every code the gateway can emit is enumerated, and each one is asserted to
/// produce copy rather than a fallback.
@Suite("SocketTransportEventMapper error copy")
struct SocketTransportEventMapperErrorCopyTests {

    /// Every `code` the voice gateway emits in an `error` frame.
    ///
    /// Sourced from `internal/voicegateway/handler.go` — the `ErrorFrame{...}`
    /// call sites. **Adding a code there means adding it here**, which is the
    /// point: the copy table and the code table have to move together, and this
    /// list is where that shows up.
    static let gatewayErrorCodes = [
        "activate_failed",
        "already_authenticated",
        "client_asr_required",
        "end_failed",
        "idle_timeout",
        "invalid_frame",
        "provider_audio_failed",
        "provider_control_failed",
        "provider_interrupt_failed",
        "provider_open_failed",
        "provider_start_failed",
        "session_not_started",
    ]

    @Test(arguments: gatewayErrorCodes)
    func everyGatewayErrorCodeRendersAsCopy(code: String) {
        let text = userFacingErrorText(code: code, rawMessage: "use of closed network connection")

        #expect(!text.isEmpty)
        // The give-away for a fall-through: the old shape led with the code in
        // brackets.
        #expect(!text.hasPrefix("["), "\(code) rendered as raw machine text")
        // And every code gets copy of its own rather than the shared fallback —
        // the fallback is the one that also carries the raw detail.
        #expect(
            !text.contains("use of closed network connection"),
            "\(code) fell through to the generic fallback"
        )
    }

    /// An unknown code is exactly when support needs the identifier — and
    /// exactly when the learner must not be shown it alone.
    @Test func anUnknownCodeKeepsItsIdentifierBesideAHumanSentence() {
        let text = userFacingErrorText(code: "brand_new_failure", rawMessage: "socket said no")

        #expect(text.contains("brand_new_failure"))
        #expect(text.contains("请重试"))
        // The human sentence comes first; the identifier is an appendix.
        #expect(!text.hasPrefix("["))
        #expect(text.hasPrefix("语音服务"))
    }

    /// Raw socket text ("write tcp ... broken pipe") is diagnostic detail, not
    /// something to show a learner — for known codes it must not appear at all.
    @Test func knownCodesDoNotLeakRawSocketText() {
        for code in Self.gatewayErrorCodes {
            let text = userFacingErrorText(code: code, rawMessage: "write tcp 1.2.3.4:5678: broken pipe")
            #expect(!text.contains("broken pipe"), "\(code) leaked raw socket text")
        }
    }

    /// A nil / empty message must not produce a dangling colon.
    @Test func anEmptyRawMessageDoesNotLeaveADanglingSeparator() {
        let text = userFacingErrorText(code: "brand_new_failure", rawMessage: nil)
        #expect(text == "语音服务出了点问题，请重试（brand_new_failure）")

        let empty = userFacingErrorText(code: "brand_new_failure", rawMessage: "")
        #expect(empty == "语音服务出了点问题，请重试（brand_new_failure）")
    }
}
