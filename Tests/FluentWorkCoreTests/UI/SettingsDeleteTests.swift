import FluentWorkCore
import FluentWorkFeatureFlags
import FluentWorkNetworking
import Foundation
import Testing

@testable import FluentWorkUI

/// 屏 12「删除我的全部素材」那条不可逆链路的规则。
///
/// 这一组判据盯的是**不可逆操作的三条底线**：按下不等于确认、确认之前不发请求、
/// 说清代价（不能少报）。
@Suite("设置 · 删除我的全部素材")
struct SettingsDeleteTests {

    private func response(
        cascaded: [String: Int] = ["phrase_blocks": 12, "practice_sessions": 5],
        alreadyDeleted: Bool = false
    ) -> DeleteAccountDataResponse {
        let json = """
            {
              "cascaded": {\(cascaded.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ","))},
              "backup_purge_at": "2026-10-31T00:00:00Z",
              "already_deleted": \(alreadyDeleted)
            }
            """
        return try! JSONDecoder().decode(DeleteAccountDataResponse.self, from: Data(json.utf8))
    }

    private func model(_ state: AccountDataState) -> SettingsViewModel {
        SettingsViewModel.make(
            from: FeatureFlagsState(snapshot: FeatureFlagSnapshot(enabledFlags: [])),
            appVersion: "1.0",
            accountData: state
        )
    }

    private func flow(_ state: AccountDataState) -> SettingsDeleteFlow {
        model(state).sceneRows!.deleteFlow
    }

    // MARK: - 按下 ≠ 确认

    /// **按下那一行只是把确认摆出来，不删任何东西。**
    @Test func 按下只是摆出确认不开始删() {
        var state = AccountDataState()
        accountDataReducer(&state, .deleteTapped)

        #expect(state.phase == .confirming)
        #expect(state.phase != .deleting, "按下就开始删，等于没有二次确认")
    }

    /// **没走过确认就不许开始删。** 这条挡的是「确认被漏掉」：
    /// 视图上的手滑、或者将来有人把「按下」直接接到请求上。
    @Test func 没有确认过就不许开始删() {
        var fresh = AccountDataState()
        accountDataReducer(&fresh, .confirmed)
        #expect(fresh.phase == .idle, "没摆过确认却进入了删除相位")

        var deleted = AccountDataState()
        accountDataReducer(&deleted, .deleteSucceeded(response()))
        accountDataReducer(&deleted, .confirmed)
        #expect(deleted.phase == .deleted, "删过之后又被一次「确定」拉回了删除相位")
    }

    /// 确认之后才进 `.deleting`（请求在飞）。
    @Test func 确认之后进入删除中() {
        var state = AccountDataState()
        accountDataReducer(&state, .deleteTapped)
        accountDataReducer(&state, .confirmed)

        #expect(state.phase == .deleting)
    }

    /// 取消回到可以重新开始的状态，而且**不留半截数据**。
    @Test func 取消之后回到起点() {
        var state = AccountDataState()
        accountDataReducer(&state, .deleteTapped)
        accountDataReducer(&state, .confirmationCancelled)

        #expect(state.phase == .idle)
        #expect(state.cascadeCounts.isEmpty)
    }

    // MARK: - 回执说人话

    /// 删完之后用**服务端数出来的真实计数**说话。
    @Test func 回执用真实的级联计数() {
        var state = AccountDataState()
        accountDataReducer(&state, .deleteSucceeded(response()))

        let message = flow(state).resultMessage ?? ""
        #expect(message.contains("话术块 12 条"), "实际：\(message)")
        #expect(message.contains("练习记录 5 条"), "实际：\(message)")
    }

    /// **不认得的表名不编中文名，也不把表名端到屏幕上。**
    @Test func 认不出的表不出现在回执里() {
        var state = AccountDataState()
        accountDataReducer(
            &state,
            .deleteSucceeded(response(cascaded: ["phrase_blocks": 3, "ai_cost_logs": 99]))
        )

        let message = flow(state).resultMessage ?? ""
        #expect(message.contains("话术块 3 条"))
        #expect(message.contains("ai_cost_logs") == false, "把内部表名端给了学员：\(message)")
        #expect(message.contains("99") == false, "不认识的表的数字也不该出现：\(message)")
    }

    /// 幂等：第二次调用时服务端说「本来就没有」，屏幕上说「已经不在了」，**不报错**。
    @Test func 已经删过时说已经不在了() {
        var state = AccountDataState()
        accountDataReducer(&state, .deleteSucceeded(response(cascaded: [:], alreadyDeleted: true)))

        let flow = flow(state)
        #expect(flow.resultMessage?.contains("已经不在了") == true)
        #expect(flow.errorMessage == nil, "幂等回包不是错误")
    }

    /// 计数全为零（或者服务端给了空表）时仍有一句话，**不是空字符串**。
    @Test func 没有可报的计数时也有一句话() {
        var state = AccountDataState()
        accountDataReducer(&state, .deleteSucceeded(response(cascaded: [:])))

        let message = flow(state).resultMessage ?? ""
        #expect(!message.isEmpty)
    }

    // MARK: - 说清代价

    /// 确认文案要写出**不能撤销**，并且**点名话术块也会一起没了** ——
    /// 只写「删除素材」会让人以为库里的表达还在。
    @Test func 确认文案说清不可恢复与级联() {
        let confirmation = flow(AccountDataState()).confirmationMessage

        #expect(confirmation.contains("不可恢复"), "没写「不能撤销」：\(confirmation)")
        #expect(confirmation.contains("话术块"), "没点名话术块也会一起删：\(confirmation)")
    }

    /// 确认文案里**没有数字** —— 因为删之前拿不到这个 N（见投影里的长注释）。
    /// 这条判据把它钉住：将来有人「顺手」加一个数，会先红在这里，而不是悄悄少报损失。
    @Test func 确认文案里不出现数字() {
        let confirmation = flow(AccountDataState()).confirmationMessage
        let digits = confirmation.filter(\.isNumber)

        #expect(
            digits.isEmpty,
            "确认文案里出现了数字「\(digits)」—— 删之前客户端数不出这个 N，写上去就是猜"
        )
    }

    // MARK: - 行图标（稿子 `[sr-ico]`）

    /// 稿子 屏 12 的每一行都带行首图标，而且**全是已有的图标令牌**。
    ///
    /// 第一版漏了这一处（把 `[sr-ico]` 当成了装饰没提取），所以这条判据是按
    /// 「稿子的行 ↔ 稿子的图标」逐个对上的 —— 它挡的是「少了一个图标」这种
    /// 只有对着稿子才会发现的差。
    @Test func 每一行都带稿子指定的图标() {
        let rows = SettingsViewModel.sceneRows(from: AccountDataState())

        let expected: [(String, DesignTokens.Icon)] = [
            ("account.phone", .talk),
            ("voice.timbre", .mic),
            ("privacy.purpose", .shield),
            ("privacy.delete", .trash),
        ]
        for (id, icon) in expected {
            let row = ([rows.account] + rows.voice + rows.privacy).first { $0.id == id }
            #expect(row?.icon == icon, "\(id) 的行首图标不是稿子指定的那一个")
        }
    }

    /// 请求在飞时那一行不可点（重复发两次会让幂等回包看起来像没生效）。
    @Test func 删除中不可再点() {
        var state = AccountDataState()
        accountDataReducer(&state, .deleteTapped)
        accountDataReducer(&state, .confirmed)

        #expect(flow(state).canDelete == false)
        #expect(flow(state).isDeleting)
    }

    /// 失败之后可以重试，而且失败**不会**把相位卡在删除中。
    @Test func 失败之后可以重试() {
        var state = AccountDataState()
        accountDataReducer(&state, .deleteTapped)
        accountDataReducer(&state, .confirmed)
        accountDataReducer(&state, .deleteFailed("网络没通。"))

        let flow = flow(state)
        #expect(flow.canDelete, "失败之后那一行点不动了 —— 学员没有办法再试一次")
        #expect(flow.errorMessage == "网络没通。")
        #expect(flow.resultMessage == nil, "没删成功却报了回执")
    }
}
