import Foundation

/// Domain events for the SpeechSession machine (tech design §2.2).
///
/// `badgeHit` is intentionally absent — feedback badges bypass this machine and
/// dispatch display actions directly.
public enum SpeechSessionEvent: Equatable, Sendable {
    case sessionStartTap
    case socketReady
    case aiAudioEnd
    case vadSpeechStart
    case holdStart
    case vadSpeechEnd
    case holdEnd
    case aiFirstAudioChunk
    case networkLost
    case reconnectTimedOut
    case reconnectSucceeded
    case interruptedBySystem
    case systemInterruptEnded
    case textMessageSent
    case textReplyReceived
    case endTap
    case failed(String)
}
