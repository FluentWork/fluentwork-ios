import FluentWorkCore
import Foundation
import Testing

@testable import FluentWorkUI

/// 创建练习弹层（09-26 稿 屏 11）的投影。
///
/// 这一屏的规则几乎全是**边界**：多少字能开始、超了怎么办、在飞时能不能再点。
/// 边界最容易被写成视图里的一句 `disabled(...)`，然后没有任何东西在守它 ——
/// 所以规则住在 state 上，这里逐条钉的是「屏幕上呈现的还是那一条」。
@Suite("创建练习弹层的投影")
struct CreatePracticeProjectionTests {

    private func state(
        input: CreatePracticeInput = .sentence,
        draft: String = "",
        length: PracticeSessionLength = .standard,
        isSubmitting: Bool = false,
        errorMessage: String? = nil
    ) -> CreatePracticeState {
        CreatePracticeState(
            input: input,
            draft: draft,
            length: length,
            isSubmitting: isSubmitting,
            errorMessage: errorMessage
        )
    }

    /// 三种输入方式都在，且**默认停在「一句话描述」**（稿子：冷启动摩擦最低的路径）。
    @Test func 三种输入都在且默认停在一句话描述() {
        let model = CreatePracticeViewModel.make(from: state())

        #expect(
            model.inputs.map(\.id) == CreatePracticeInput.allCases.map(\.rawValue),
            "输入方式与 allCases 不一致（漏了或换序了）"
        )
        #expect(model.inputs.map(\.title) == ["一句话描述", "粘贴素材", "预置场景"])
        #expect(model.selectedInput == .sentence)
        #expect(model.inputs.filter(\.isSelected).count == 1, "同一时刻只能选中一种")
        #expect(model.inputs.first(where: \.isSelected)?.id == CreatePracticeInput.sentence.rawValue)
    }

    /// **隐私声明是常驻的，不是折叠起来的一次性弹窗**（稿子 A4）。
    ///
    /// 所以它在**每一种输入方式 × 每一个相位**下都得在 —— 包括提交中与出错时：
    /// 恰恰是「我看着这段话有点犹豫」的时候，它最该在那儿。
    @Test func 隐私声明在任何输入与任何相位下都在() {
        var models: [CreatePracticeViewModel] = []
        for input in CreatePracticeInput.allCases {
            models.append(CreatePracticeViewModel.make(from: state(input: input, draft: "我昨天把限流方案定了")))
            models.append(
                CreatePracticeViewModel.make(from: state(input: input, isSubmitting: true))
            )
            models.append(
                CreatePracticeViewModel.make(from: state(input: input, errorMessage: "网络开小差了"))
            )
        }

        #expect(models.allSatisfy { !$0.privacyNotice.isEmpty }, "有相位把隐私声明丢了")
        #expect(
            Set(models.map(\.privacyNotice)).count == 1,
            "同一条声明在不同相位下被写成了不同的话"
        )
        #expect(models[0].privacyNotice.contains("不用于训练"), "稿子 A4 的措辞是「素材与录音仅用于生成练习、不用于训练」")
    }

    /// 文本不够 10 字不能开始 —— **边界两侧各测一次**，否则「恒为 false」也能过。
    @Test func 文本不足十字时不能开始() {
        let nine = CreatePracticeViewModel.make(from: state(draft: String(repeating: "字", count: 9)))
        let ten = CreatePracticeViewModel.make(from: state(draft: String(repeating: "字", count: 10)))

        #expect(nine.canSubmit == false)
        #expect(ten.canSubmit, "正好 10 字就该能开始")
        #expect(nine.shortfallMessage?.contains("1") == true, "还差多少要说出来：\(nine.shortfallMessage ?? "nil")")
        #expect(ten.shortfallMessage == nil, "够了就不该再念叨")
    }

    /// 超过 2000 字不能开始，**并且不静默截断**：说出超了多少，让人自己删。
    ///
    /// 截断是更省事的做法，但粘贴 3000 字的人会以为全进去了 —— 那是一条看不见的丢数据。
    @Test func 超过上限时不静默截断而是说清超出多少() {
        let atLimit = CreatePracticeViewModel.make(
            from: state(input: .paste, draft: String(repeating: "字", count: 2000))
        )
        let over = CreatePracticeViewModel.make(
            from: state(input: .paste, draft: String(repeating: "字", count: 2003))
        )

        #expect(atLimit.canSubmit, "2000 字正好是上限")
        #expect(over.canSubmit == false)
        #expect(over.overLimitMessage?.contains("3") == true, "超出的字数要说出来：\(over.overLimitMessage ?? "nil")")
        #expect(atLimit.overLimitMessage == nil)
        #expect(over.characterCount == 2003, "字数照实报 —— 不截断")
    }

    /// 字数按**字符**算，不是字节：中文一个字是一个字符。
    ///
    /// 按字节算的话，`"字"` 一个就占 3，10 个中文会被判成超限或反过来算错下限 ——
    /// 而这一屏的两侧都是中文用户最常走的路径。
    @Test func 字数按字符算不按字节() {
        let model = CreatePracticeViewModel.make(from: state(draft: String(repeating: "限", count: 10)))

        #expect(model.characterCount == 10)
        #expect(model.canSubmit)
    }

    /// 两种时长**并列呈现、不做视觉降级**：两个选项都要有回合数与时长那一行。
    @Test func 两种时长并列且都不缺回合与时长() {
        let model = CreatePracticeViewModel.make(from: state())
        let standard = model.lengthOptions.first { $0.id == PracticeSessionLength.standard.rawValue }
        let mini = model.lengthOptions.first { $0.id == PracticeSessionLength.mini.rawValue }

        #expect(model.lengthOptions.count == 2, "稿子只有两个选项，多一个少一个都是形态变化")
        #expect(standard?.title == "标准")
        #expect(mini?.title == "迷你")
        #expect(standard?.detail.contains("回合") == true, "标准要写清回合数与时长")
        #expect(standard?.detail.contains("15") == true)
        #expect(mini?.detail.contains("回合") == true, "迷你同样要写清 —— 缺了它就成了「简化版」")
        #expect(mini?.detail.contains("2") == true)
        #expect(model.lengthOptions.filter(\.isSelected).count == 1)
    }

    /// 换一种输入方式，规则跟着换：预置场景不需要文字。
    @Test func 预置场景不需要文字而文本输入需要() {
        let preset = CreatePracticeViewModel.make(from: state(input: .preset))
        let sentence = CreatePracticeViewModel.make(from: state(input: .sentence))

        #expect(preset.showsDraftField == false)
        #expect(preset.canSubmit, "预置场景没有素材要写，直接能开始")
        #expect(preset.shortfallMessage == nil, "它不该显示「还差 N 字」")
        #expect(preset.presetSceneTitle == "Daily Standup", "MVP 只有这一个预置场景，名字要给人看")

        #expect(sentence.showsDraftField)
        #expect(sentence.canSubmit == false)
    }

    /// 在飞时不能再点：一次点击建一份素材，漏了这条会建出两份。
    @Test func 提交中不能再点() {
        let model = CreatePracticeViewModel.make(
            from: state(draft: String(repeating: "字", count: 20), isSubmitting: true)
        )

        #expect(model.canSubmit == false)
        #expect(model.isSubmitting)
    }

    /// 失败之后能再来一次，且原因是人话。
    @Test func 失败后能再来一次且说清原因() {
        let failed = CreatePracticeViewModel.make(
            from: state(draft: String(repeating: "字", count: 20), errorMessage: "素材没能提交，检查网络后重试。")
        )

        #expect(failed.errorMessage == "素材没能提交，检查网络后重试。")
        #expect(failed.canSubmit, "失败必须能重试 —— 否则这一屏就死在这一步了")

        let retrying = CreatePracticeViewModel.make(
            from: state(draft: String(repeating: "字", count: 20), isSubmitting: true)
        )
        #expect(retrying.errorMessage == nil, "再次提交时上一次的错要撤掉，否则屏幕上同时有两个说法")
    }

    /// **两种文本输入共用一份草稿**：切过去再切回来，写的东西还在。
    @Test func 切换输入方式不丢已经写下的内容() {
        let typed = state(draft: "我昨天把限流方案定了，今天想讲清下一步")
        let asPaste = CreatePracticeViewModel.make(from: state(input: .paste, draft: typed.draft))

        #expect(asPaste.characterCount == typed.characterCount)
        #expect(asPaste.canSubmit)
        #expect(asPaste.draftLabel != CreatePracticeViewModel.make(from: typed).draftLabel, "两种模式问法不同，但共用同一段字")
    }

    /// 提交按钮上的字在两种相位下不同 —— 它是屏幕上唯一说明「正在做什么」的地方。
    @Test func 提交中的按钮说的是正在做() {
        let idle = CreatePracticeViewModel.make(from: state(draft: String(repeating: "字", count: 20)))
        let busy = CreatePracticeViewModel.make(
            from: state(draft: String(repeating: "字", count: 20), isSubmitting: true)
        )

        #expect(idle.submitTitle == "开始练习")
        #expect(busy.submitTitle != idle.submitTitle)
    }
}
