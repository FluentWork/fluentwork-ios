import FactoryKit
import FluentWorkNetworking
import Foundation
import Testing
import TGReduxKit
import os
@testable import FluentWorkCore

/// 记下每次调用 —— 这一组判据里最要紧的几条问的是**有没有调**、**用哪种 kind 调**，
/// 而一个只返回数据的替身分不出这两件事。
private final class StubMaterialsClient: MaterialsClientProtocol, @unchecked Sendable {
    typealias Responder = @Sendable (MaterialKind, String) throws -> String

    private let responder: Responder
    private let storage = OSAllocatedUnfairLock<[(MaterialKind, String)]>(initialState: [])

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    var calls: [(MaterialKind, String)] {
        storage.withLock { $0 }
    }

    func createMaterial(kind: MaterialKind, content: String) async throws -> String {
        storage.withLock { $0.append((kind, content)) }
        return try responder(kind, content)
    }
}

private struct CreatePracticeStubFailure: Error, LocalizedError {
    var errorDescription: String? { "离线" }
}

@MainActor
private func makeStore(
    client: StubMaterialsClient,
    state: CreatePracticeState = CreatePracticeState()
) -> (Store<AppState, AppAction>, StubMaterialsClient) {
    let container = Container()
    container.reset()
    container.materialsClient.register { client }
    var initialState = AppState.initial
    initialState.createPractice = state
    return (
        AppStoreFactory.make(container: container, initialState: initialState),
        client
    )
}

/// 一份够长的草稿（超过 10 字下限）。
private let enoughDraft = "我昨天把限流方案定了，今天想讲清下一步计划"

// MARK: - 规则住在 state 上，不在按钮的 enabled 上

/// 屏幕会把按钮置灰，但**规则不能只活在按钮上**：一次误触、一次自动化点击都会绕过它。
@Suite("创建练习的状态层")
struct CreatePracticeStateTests {

    @Test func 不能提交时点了也不进在飞态() {
        var state = CreatePracticeState(input: .sentence, draft: "三个字")
        createPracticeReducer(&state, .submitTapped)

        #expect(state.isSubmitting == false, "文本不够时提交被 reducer 挡下")
        #expect(state.pendingCreation == nil)
    }

    @Test func 可以提交时点击进入在飞态() {
        var state = CreatePracticeState(input: .sentence, draft: enoughDraft)
        createPracticeReducer(&state, .submitTapped)

        #expect(state.isSubmitting)
        #expect(state.errorMessage == nil)
    }

    /// 两种文本输入各建各的素材，预置场景**一份都不建**。
    ///
    /// 为预置场景建一份空素材会让语料库多出一笔无主记录 —— 那是看不见的脏数据。
    @Test func 素材种类由输入方式决定而预置场景不建素材() {
        #expect(CreatePracticeState(input: .sentence).materialKind == .sentence)
        #expect(CreatePracticeState(input: .paste).materialKind == .paste)
        #expect(CreatePracticeState(input: .preset).materialKind == nil)
    }

    /// **文本两路不替服务端定场景**：稿子说「一句话描述」由 AI 补全场景设定，
    /// 客户端硬塞一个 `standup` 会把那句话变成假的。只有预置场景由客户端指定。
    @Test func 只有预置场景由客户端指定场景() {
        #expect(CreatePracticeState(input: .preset).sceneType == "standup")
        #expect(CreatePracticeState(input: .sentence).sceneType == nil)
        #expect(CreatePracticeState(input: .paste).sceneType == nil)
    }

    @Test func 失败后清掉在飞态并留下原因() {
        var state = CreatePracticeState(input: .sentence, draft: enoughDraft, isSubmitting: true)
        createPracticeReducer(&state, .submissionFailed("素材没能提交"))

        #expect(state.isSubmitting == false)
        #expect(state.errorMessage == "素材没能提交")
    }
}

// MARK: - 中间件：建素材，然后把学员送进房间

@MainActor
@Suite("创建练习的中间件")
struct CreatePracticeMiddlewareTests {

    @Test func 一句话描述先建素材再进房间() async throws {
        let client = StubMaterialsClient { kind, content in
            #expect(kind == .sentence)
            #expect(content == enoughDraft)
            return "mat-1"
        }
        let (store, _) = makeStore(
            client: client,
            state: CreatePracticeState(input: .sentence, draft: enoughDraft, length: .mini)
        )

        store.dispatch(.createPractice(.submitTapped))

        try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            store.state.createPractice.pendingCreation != nil
        }
        #expect(store.state.createPractice.pendingCreation?.materialID == "mat-1")
        #expect(store.state.createPractice.pendingCreation?.length == .mini)
        #expect(client.calls.count == 1)
    }

    /// 素材就位之后才动人：先关弹层、再进房间。
    ///
    /// 断言的是**落到导航状态上的结果**，不是「派了哪几个 action」——
    /// 后者在中间件里换个顺序照样过。
    @Test func 素材就位后弹层关掉且房间被推上来() async throws {
        let client = StubMaterialsClient { _, _ in "mat-2" }
        let (store, _) = makeStore(
            client: client,
            state: CreatePracticeState(input: .paste, draft: enoughDraft)
        )

        store.dispatch(.createPractice(.submitTapped))
        try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            store.state.navigation.workbench.presentedRoute != nil
        }

        #expect(
            store.state.navigation.workbench.presentedRoute == .speakingRoom(sessionID: nil),
            "应当进房间：\(String(describing: store.state.navigation.workbench.presentedRoute))"
        )
        #expect(store.state.navigation.workbench.presentationStyle == .fullScreenCover)
    }

    /// 预置场景**不调素材接口**。
    @Test func 预置场景不建素材直接进房间() async throws {
        let client = StubMaterialsClient { _, _ in
            Issue.record("预置场景不该建素材")
            return "nope"
        }
        let (store, _) = makeStore(
            client: client,
            state: CreatePracticeState(input: .preset, length: .standard)
        )

        store.dispatch(.createPractice(.submitTapped))
        try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            store.state.navigation.workbench.presentedRoute != nil
        }

        #expect(client.calls.isEmpty)
        #expect(store.state.createPractice.pendingCreation?.materialID == nil)
        #expect(store.state.createPractice.pendingCreation?.sceneType == "standup")
    }

    /// 建素材失败：留在那一屏上说出来，**不把人送进一场没有素材的房间**。
    @Test func 建素材失败时不进房间而是留在原地() async throws {
        let client = StubMaterialsClient { _, _ in throw CreatePracticeStubFailure() }
        let (store, _) = makeStore(
            client: client,
            state: CreatePracticeState(input: .paste, draft: enoughDraft)
        )

        store.dispatch(.createPractice(.submitTapped))
        try await waitUntil(timeoutNanoseconds: 5_000_000_000) {
            store.state.createPractice.errorMessage != nil
        }

        #expect(store.state.createPractice.isSubmitting == false)
        #expect(store.state.createPractice.pendingCreation == nil)
        #expect(
            store.state.navigation.workbench.presentedRoute == nil,
            "失败了还进房间，学员会在里面发现这次练习没有素材，而且不知道是谁的错"
        )
    }

    /// 被挡住的那次点击**连接口都不该碰**。
    @Test func 判据说不能提交时一个请求都不发() async throws {
        let client = StubMaterialsClient { _, _ in
            Issue.record("不该发出请求")
            return "nope"
        }
        let (store, _) = makeStore(
            client: client,
            state: CreatePracticeState(input: .sentence, draft: "太短")
        )

        store.dispatch(.createPractice(.submitTapped))
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(client.calls.isEmpty)
        #expect(store.state.createPractice.isSubmitting == false)
    }
}
