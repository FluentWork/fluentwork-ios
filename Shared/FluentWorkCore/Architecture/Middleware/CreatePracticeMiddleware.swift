import FactoryKit
import FluentWorkNetworking
import Foundation
import TGReduxKit

/// 创建练习（屏 11）的两件事：**建素材**，然后**把学员送进房间**。
///
/// 为什么两件事都在这儿而不是在视图里：视图回调只能派一个 action，
/// 而这里的顺序是实打实的（先有 `material_id` 才有会话可开），
/// 失败还要能回到那一屏上说出来。视图不该知道这个顺序。
public func createPracticeMiddleware(container: Container) -> Middleware<AppState, AppAction> {
    let materials = container.materialsClient()

    return { store, action, next in
        guard case .createPractice(let practiceAction) = action else {
            return next(action)
        }

        switch practiceAction {
        case .submitTapped:
            // 规则由 `state.canSubmit` 判过（reducer 里也再守一次）——
            // 这里只负责「把已经定下来的事做掉」，不再自己判断一遍合法性。
            guard store.state.createPractice.canSubmit else {
                return next(action)
            }
            let input = store.state.createPractice.input
            let kind = store.state.createPractice.materialKind
            let content = store.state.createPractice.draft
            let sceneType = store.state.createPractice.sceneType
            let length = store.state.createPractice.length

            return .merge(
                next(action),
                .task(id: AppTaskID.createPracticeSubmit) {
                    do {
                        // **预置场景不建素材**（`kind == nil`）：那一路练的是场景本身，
                        // 没有东西可提炼。为它建一份空素材会让语料库多出一笔无主记录。
                        var materialID: String?
                        if let kind {
                            materialID = try await materials.createMaterial(
                                kind: kind,
                                content: content
                            )
                        }
                        guard !Task.isCancelled else { return nil }
                        return .createPractice(
                            .created(
                                PracticeCreation(
                                    materialID: materialID,
                                    sceneType: sceneType,
                                    length: length
                                )
                            )
                        )
                    } catch is CancellationError {
                        return nil
                    } catch {
                        guard !Task.isCancelled else { return nil }
                        return .createPractice(.submissionFailed(createPracticeErrorMessage(error)))
                    }
                }
            )

        case .created:
            // 素材就位之后才动人 —— 先关弹层再进房间，不是反过来：
            // 反过来会有一帧是「房间盖在弹层上」，而弹层还在等一次已经没有意义的关闭。
            return .merge(
                next(action),
                next(.navigation(.workbench(.dismiss))),
                next(
                    .navigation(
                        .workbench(
                            .present(.speakingRoom(sessionID: nil), style: .fullScreenCover)
                        )
                    )
                )
            )

        case .inputChanged, .draftChanged, .lengthChanged, .submissionFailed:
            return next(action)
        }
    }
}

/// 失败时对学员说的话。
///
/// 只说**能做什么**：这一屏上学员唯一能做的就是再点一次，所以文案要指回那个按钮；
/// 把服务端的 `llm_timeout` / `invalid_argument` 摊在屏幕上既不准确也无从下手。
func createPracticeErrorMessage(_ error: Error) -> String {
    if case let APIError.backend(_, message) = error, !message.isEmpty {
        return message
    }
    return "素材没能提交，检查网络后重试。"
}
