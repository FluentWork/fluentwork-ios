import FluentWorkNetworking
import Foundation
import Testing
@testable import FluentWorkCore

private let basePrompt = "You are a FluentWork speaking coach."

@Test func systemPromptBuilderWithoutHitsDoesNotAddHitsSection() {
    let built = SystemPromptBuilder.build(
        basePrompt: basePrompt,
        recentHits: [],
        userLevel: .beginner
    )

    #expect(
        built == """
        You are a FluentWork speaking coach.

        ## 用户水平:beginner
        """
    )
    #expect(!built.contains("最近用户命中过的话术块"))
    #expect(built.hasPrefix(basePrompt))
}

@Test func systemPromptBuilderIncludesLastEightHitsInOrder() {
    let hits = (1...9).map { index in
        RecordedHit(
            id: "block-\(index)",
            intentZh: "意图\(index)",
            chunkEn: "chunk \(index)"
        )
    }

    let built = SystemPromptBuilder.build(
        basePrompt: basePrompt,
        recentHits: hits,
        userLevel: .intermediate
    )

    #expect(!built.contains("意图1: chunk 1"))
    #expect(built.contains("- 意图2: chunk 2"))
    #expect(built.contains("- 意图9: chunk 9"))
    let hitLines = built.split(separator: "\n").filter { $0.hasPrefix("- ") }
    #expect(hitLines.count == SystemPromptBuilder.recentHitLimit)
    #expect(built.contains("## 最近用户命中过的话术块:"))
    #expect(built.contains("## 用户水平:intermediate"))

    let intent2 = built.range(of: "- 意图2: chunk 2")
    let intent9 = built.range(of: "- 意图9: chunk 9")
    #expect(intent2 != nil && intent9 != nil)
    if let intent2, let intent9 {
        #expect(intent2.lowerBound < intent9.lowerBound)
    }
}

@Test func systemPromptBuilderIncludesAdvancedUserLevel() {
    let built = SystemPromptBuilder.build(
        basePrompt: basePrompt,
        recentHits: [
            RecordedHit(id: "block-a", intentZh: "表达感谢", chunkEn: "Thanks for the update."),
        ],
        userLevel: .advanced
    )

    #expect(built.contains("## 用户水平:advanced"))
    #expect(built.contains("- 表达感谢: Thanks for the update."))
    #expect(built.hasPrefix(basePrompt))
}

@Test func recordedHitMapsPhraseBlockIntentAndExpression() {
    let block = PhraseBlock(
        id: "pb-1",
        intentZH: "请求帮助",
        expressionEN: "Could you walk me through that?",
        anchorUserSaid: "",
        sceneTag: "standup",
        functionTag: "ask",
        state: "active",
        successStreak: 0,
        nextDueAt: "",
        easeFactor: 2.5,
        realUseCount: 1,
        isFavorite: false,
        pinnedAt: nil,
        sourceSessionID: nil,
        createdAt: "",
        updatedAt: ""
    )

    let hit = RecordedHit(phraseBlock: block)
    #expect(hit.id == "pb-1")
    #expect(hit.intentZh == "请求帮助")
    #expect(hit.chunkEn == "Could you walk me through that?")
}

@Test func userLevelRawValuesMatchPromptContract() {
    #expect(UserLevel.beginner.rawValue == "beginner")
    #expect(UserLevel.intermediate.rawValue == "intermediate")
    #expect(UserLevel.advanced.rawValue == "advanced")
}
