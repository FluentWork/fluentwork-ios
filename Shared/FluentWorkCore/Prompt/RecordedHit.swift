import FluentWorkNetworking
import Foundation

/// One B7 phrase-block hit to inject into the V2.0 system prompt (I20 T-I20-3).
///
/// Shaped for prompt assembly, not for badge UI. Fetching `recentHits` (B19)
/// is the caller's job; this type only carries `intent_zh` + English chunk.
public struct RecordedHit: Equatable, Sendable, Identifiable {
    public var id: String
    public var intentZh: String
    public var chunkEn: String

    public init(id: String, intentZh: String, chunkEn: String) {
        self.id = id
        self.intentZh = intentZh
        self.chunkEn = chunkEn
    }

    public init(phraseBlock: PhraseBlock) {
        self.init(
            id: phraseBlock.id,
            intentZh: phraseBlock.intentZH,
            chunkEn: phraseBlock.expressionEN
        )
    }
}
