import Foundation

/// Assembles the V2.0 speaking-room system prompt (I20 T-I20-3).
///
/// Pure string assembly: no UserDefaults, no network, no session machine.
/// Hits are optional context; user level is always appended so the model has
/// a stable instruction even on a first session.
public enum SystemPromptBuilder {
    /// Prompt engineer contract: at most the 8 most recent B7 hits.
    public static let recentHitLimit = 8

    public static func build(
        basePrompt: String,
        recentHits: [RecordedHit],
        userLevel: UserLevel
    ) -> String {
        var prompt = basePrompt
        let hits = Array(recentHits.suffix(recentHitLimit))
        if !hits.isEmpty {
            prompt += "\n\n## 最近用户命中过的话术块:\n"
            for hit in hits {
                prompt += "- \(hit.intentZh): \(hit.chunkEn)\n"
            }
        }
        prompt += "\n\n## 用户水平:\(userLevel.rawValue)"
        return prompt
    }
}
