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
    /// Sourced from the `ErrorFrame{...}` call sites in
    /// `internal/voicegateway/handler.go`. **Adding a code there means adding
    /// it here**, which is the point: the copy table and the code table have to
    /// move together, and this list is where that shows up.
    ///
    /// Exactly **eleven**. `77_` P1-19 recorded twelve, and this list carried
    /// that twelfth entry for a while — `idle_timeout`. It is not an error
    /// code: it is the *persist reason* the gateway records when a session's
    /// read deadline expires (`handler.go` `persistOnExit`), and no error frame
    /// ever carries it. A "code table" with a non-code in it stops being the
    /// thing the copy table is supposed to be checked against.
    static let gatewayErrorCodes = [
        "activate_failed",
        "already_authenticated",
        "client_asr_required",
        "end_failed",
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

/// 传输层失败的用户文案（`SocketTransportError.userFacingMessage`）。
///
/// 这张表以前**没有判据**，而它确实会到达屏幕，且有两处不符合仓里既定的口径：
///
/// - `.network(detail)` 把诊断串原文当文案 —— 学员读到的是
///   `[NSPOSIXErrorDomain 57] Socket is not connected`（真机 2026-09-29 那条）；
/// - 其余几条是英文，而这个 App 的其它文案都是中文。
///
/// 口径与 `userFacingErrorText` 一致：**人话在前、机器标识进括号**。诊断串不许丢 ——
/// 它是真机上唯一能分辨「连接被我们自己取消」「帧协议违约」「服务端关闭」的东西
/// （`URLSessionSocketTransport.mapError` 特意保留 domain+code）。
@Suite("SocketTransportError 的用户文案")
struct SocketTransportErrorUserCopyTests {

    /// 全部 case。**加一个新 case 就要加进这里**：漏了的那个会自己走一条没人检查的分支。
    static let allErrors: [SocketTransportError] = [
        .invalidURL,
        .notConnected,
        .handshakeFailed("handshake detail"),
        .encodingFailed("encoding detail"),
        .decodingFailed("decoding detail"),
        .network("[NSPOSIXErrorDomain 57] Socket is not connected"),
        .pingTimedOut,
        .cancelled,
    ]

    @Test(arguments: allErrors)
    func everyErrorReadsAsAHumanSentence(error: SocketTransportError) {
        let text = error.userFacingMessage

        #expect(!text.isEmpty)
        #expect(!text.hasPrefix("["), "诊断串被当成了文案：\(text)")
        #expect(
            text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
            "没有中文人话：\(text)"
        )
        #expect(text.contains("请") || text.contains("已"), "既没有动作也没有状态：\(text)")
    }

    /// 诊断串留在括号里：人话在前，支持要的标识符在后。
    @Test func theDiagnosticStringStaysInTheParentheses() {
        let text = SocketTransportError
            .network("[NSPOSIXErrorDomain 57] Socket is not connected")
            .userFacingMessage

        #expect(text.contains("NSPOSIXErrorDomain"))
        #expect(text.contains("57"))
        #expect(text.contains("（"), "细节没有进括号：\(text)")
        #expect(text.hasPrefix("语音服务"), "人话必须在前：\(text)")
    }

    /// 带 detail 的 case 必须把 detail 带出来，否则排查时只剩一句「请重试」。
    @Test(arguments: [
        SocketTransportError.handshakeFailed("handshake detail"),
        .encodingFailed("encoding detail"),
        .decodingFailed("decoding detail"),
    ])
    func casesWithDetailCarryIt(error: SocketTransportError) {
        #expect(error.userFacingMessage.contains("detail"))
    }
}

