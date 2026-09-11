import Foundation
import Testing
@testable import FluentWorkCore

/// Which stage tags the iOS log and the gateway log **actually share**.
///
/// `77_` P1-20: the iOS `stageTag` was documented as mirroring the gateway's
/// `stage` field, so a reader would search the server log for a label the
/// client printed. For most labels that search comes back empty — and an empty
/// search reads as "that event was lost", not as "that label is client-only".
///
/// The count was recorded as 3 of 13. This pins the exact overlap so the
/// documentation claim and the vocabulary cannot drift apart again: adding an
/// iOS tag that no server produces, or a server stage no iOS phase maps to, is
/// fine — but it must show up here rather than in a reader's wasted afternoon.
@Suite("Stage tag vocabulary")
struct StageTagVocabularyTests {

    /// Every `stage` value the voice gateway emits.
    ///
    /// Sourced from the `"stage", "..."` log attributes in
    /// `internal/voicegateway/` and `internal/voicepoc/`. `scheduler` lives in
    /// the content service and `transport` in the duplex client — they are in
    /// the gateway process's vocabulary but no iOS phase corresponds to them.
    static let gatewayStages: Set<String> = [
        "orchestration", "asr", "tts", "scheduler", "transport",
    ]

    /// iOS tags that a gateway log line actually carries.
    ///
    /// **Empty on purpose would be wrong** — these three really do join, and
    /// that is what makes the cross-log search worth trying at all.
    static let joined: Set<String> = ["orchestration", "asr", "tts"]

    @Test func everyIOSStageTagIsEitherSharedOrExplicitlyLocal() {
        var iosTags: Set<String> = []
        for phase in SpeechSessionPhase.allCases {
            iosTags.insert(phase.stageTag)
        }
        for stage in ProcessingStage.allCases {
            iosTags.insert(stage.stageTag)
        }

        // The overlap is exactly the pinned set — no more, no less.
        #expect(
            iosTags.intersection(Self.gatewayStages) == Self.joined,
            "the iOS/gateway stage overlap changed; update the doc comment on SpeechSessionPhase.stageTag and this set together"
        )

        // And the claim is honest the other way too: the great majority of iOS
        // tags have no server-side counterpart. If this ever becomes false,
        // the "mostly iOS-local" wording above needs revisiting.
        #expect(
            iosTags.subtracting(Self.gatewayStages).count > Self.joined.count,
            "most iOS stage tags are client-only; that is what the doc says"
        )
    }

    /// The tags that *do* join must keep their exact spelling — that is the
    /// only thing making the cross-log search work.
    @Test func theSharedTagsSpellTheGatewayVocabularyExactly() {
        #expect(SpeechSessionPhase.connecting.stageTag == "orchestration")
        #expect(SpeechSessionPhase.aiSpeaking.stageTag == "tts")
        #expect(SpeechSessionPhase.processing.stageTag == "processing")
        #expect(ProcessingStage.asr.stageTag == "asr")

        // The pipeline stages that *look* like server vocabulary but are not:
        // the gateway emits no `llm`, `review`, `waiting_for_evaluation` or
        // `waiting_for_ai_answer` stage. Pinned so nobody re-adds the claim.
        #expect(!Self.gatewayStages.contains(ProcessingStage.llm.stageTag))
        #expect(!Self.gatewayStages.contains(ProcessingStage.review.stageTag))
        #expect(!Self.gatewayStages.contains(ProcessingStage.evaluation.stageTag))
        #expect(!Self.gatewayStages.contains(ProcessingStage.aiAnswer.stageTag))
    }
}
