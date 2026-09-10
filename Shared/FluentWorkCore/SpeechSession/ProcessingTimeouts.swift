import Foundation

/// Client-side processing-stage timeouts for SpeechSession.
///
/// Numeric FeatureFlags are out of scope until `FeatureFlagSnapshot` supports
/// non-bool values. These compile-time defaults match the ISSUE-06 contract:
/// ASR 15s / LLM 45s / review 30s, with a 70s total cap (B15 turn timeout).
public struct ProcessingTimeouts: Equatable, Sendable {
    public var asr: Duration = .seconds(15)
    public var llm: Duration = .seconds(45)
    public var review: Duration = .seconds(30)
    public var totalCap: Duration = .seconds(70)
    /// Wait for `feedback.badge` after `ai.turn.end`. Not B15; timeout returns
    /// to `.waitingUser` instead of failing the session.
    public var evaluationWait: Duration = .seconds(20)

    public init(
        asr: Duration = .seconds(15),
        llm: Duration = .seconds(45),
        review: Duration = .seconds(30),
        totalCap: Duration = .seconds(70),
        evaluationWait: Duration = .seconds(20)
    ) {
        self.asr = asr
        self.llm = llm
        self.review = review
        self.totalCap = totalCap
        self.evaluationWait = evaluationWait
    }

    public static let standard = ProcessingTimeouts()
}
