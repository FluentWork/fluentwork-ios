import SwiftUI
import FluentWorkCore

#if canImport(UIKit)
import UIKit
#endif

// MARK: - View Model

public struct SpeakingRoomTimelineHit: Equatable, Sendable, Identifiable {
    public let id: String
    public let badge: String
    public let phraseBlockID: String?

    public init(id: String, badge: String, phraseBlockID: String?) {
        self.id = id
        self.badge = badge
        self.phraseBlockID = phraseBlockID
    }
}

public struct SpeakingRoomTimelineRow: Equatable, Sendable, Identifiable {
    /// 卡壳点的标记文案（稿子 屏 03）。
    ///
    /// 放在类型上，好让「两个标记说了同一句话」这件事**能被判据钉住** ——
    /// 屏幕上一个灰签写着「卡壳点」、另一个也写着「卡壳点」，是那种在设计稿上看不出来、
    /// 在真机上要用眼睛撞见的错。
    public static let stallPointMarker = "卡壳点"
    /// 被打断的标记文案（稿子 屏 02 的「三条易错点」之二）。
    public static let interruptedMarker = "被打断"

    public let id: String
    public let isUser: Bool
    public let text: String
    public let isListening: Bool
    public let hits: [SpeakingRoomTimelineHit]
    /// 这一轮学员卡住了（屏 03）。**它是一条标记，不是一次删除** ——
    /// 那句截断的话照常留在时间线上、照常进炼化候选。
    public let isStallPoint: Bool
    /// AI 这句话没说完就被学员打断（屏 02）。
    public let wasInterrupted: Bool

    public init(
        id: String,
        isUser: Bool,
        text: String,
        isListening: Bool,
        hits: [SpeakingRoomTimelineHit],
        isStallPoint: Bool = false,
        wasInterrupted: Bool = false
    ) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.isListening = isListening
        self.hits = hits
        self.isStallPoint = isStallPoint
        self.wasInterrupted = wasInterrupted
    }
}

public struct SpeakingRoomViewModel: Equatable, Sendable {
    public var phase: SpeechSessionPhase
    /// Which backend pipeline step is running. Non-nil exactly while
    /// `phase == .processing`; the copy for that phase is chosen from here,
    /// because `.processing` alone cannot say whether to show "识别中" or
    /// "思考中".
    public var processingStage: ProcessingStage?
    public var liveTranscript: String
    public var lastBadge: String?
    public var badgeHits: Int
    public var failureReason: String?
    public var timeline: [SpeakingRoomTimelineRow]
    /// I20 Item 4: `false` is tap-to-talk (default). `true` keeps energy VAD.
    public var usesAutoVAD: Bool
    public var isRescueHintAvailable: Bool

    // MARK: 屏 02 / 03 的版式（09-26 稿）

    /// 顶部栏左边那个场景名（「Daily Standup」）。来自创建练习时定下的场景。
    public var sceneLabel: String?
    /// 「第 3 轮」。
    public var roundText: String?
    /// 「标准会话」/「迷你会话」。
    public var lengthText: String?
    /// 「用上 N 个」——本轮用上的新表达数。为 0 时是 `nil`。
    public var badgeHitText: String?
    /// 实时转录浮层的内容。**只在录音时非空**（稿子：仅录音时出现，话音落下后归位到气泡；
    /// 同一句话不同时出现在浮层与气泡里）。
    public var liveTranscriptFloat: String?
    /// 静默救援的头一句（「已经 3 秒没有听到你」）。仅救援就绪时非空。
    public var rescueHeadline: String?
    /// 救援的第二句（「慢一点没关系，这不算失败」）。
    public var rescueReassurance: String
    /// 救援按钮的文案。
    public var rescueButtonTitle: String

    public init(
        phase: SpeechSessionPhase,
        processingStage: ProcessingStage? = nil,
        liveTranscript: String = "",
        lastBadge: String? = nil,
        badgeHits: Int = 0,
        failureReason: String? = nil,
        timeline: [SpeakingRoomTimelineRow] = [],
        usesAutoVAD: Bool = false,
        isRescueHintAvailable: Bool = false,
        sceneLabel: String? = nil,
        roundText: String? = nil,
        lengthText: String? = nil,
        badgeHitText: String? = nil,
        liveTranscriptFloat: String? = nil,
        rescueHeadline: String? = nil,
        rescueReassurance: String = "",
        rescueButtonTitle: String = ""
    ) {
        self.phase = phase
        self.processingStage = processingStage
        self.liveTranscript = liveTranscript
        self.lastBadge = lastBadge
        self.badgeHits = badgeHits
        self.failureReason = failureReason
        self.timeline = timeline
        self.usesAutoVAD = usesAutoVAD
        self.isRescueHintAvailable = isRescueHintAvailable
        self.sceneLabel = sceneLabel
        self.roundText = roundText
        self.lengthText = lengthText
        self.badgeHitText = badgeHitText
        self.liveTranscriptFloat = liveTranscriptFloat
        self.rescueHeadline = rescueHeadline
        self.rescueReassurance = rescueReassurance
        self.rescueButtonTitle = rescueButtonTitle
    }

    public var isRecording: Bool {
        phase == .recording
    }

    public var isConnecting: Bool {
        phase == .connecting
    }

    public var isFailed: Bool {
        phase == .failed
    }

    /// 说话键上方那一行状态（稿子 屏 02 的 `[status-line]`）。
    ///
    /// 录音时用稿子的原话「轮到你了 · 我正在听」—— 它一句话说了两件事：**该你了**，
    /// 而且**我在听**。其余状态沿用既有的 `controlState.title`（那套中文在仓里已有判据与走查），
    /// 不再另写一套同义的文案。
    var statusLineText: String {
        phase == .recording ? "轮到你了 · 我正在听" : controlState.title
    }

    /// 说话键下方那一行小字（稿子 屏 02 的 `[hint]`）。
    ///
    /// 录音时是稿子的安抚句「说错了没关系，结束后我们一起看」—— 它替学员挡掉的是
    /// **当场自我纠正的冲动**（一纠正就卡壳，一卡壳这一轮就没了）。
    /// 其余状态用它原本的角色：说明这个按钮怎么用。没有可说的就不写（`nil`）。
    var dockHintText: String? {
        phase == .recording ? "说错了没关系，结束后我们一起看" : controlState.detail
    }

    public enum StartTapIntent: Equatable, Sendable {
        case startSession
        case beginTurn
        case none
    }

    public enum StopTapIntent: Equatable, Sendable {
        case endTurn
        case endSession
        case none
    }

    /// Idle / ended / failed start a session. Waiting and AI-speaking taps
    /// open a user turn when auto VAD is off.
    public var startTapIntent: StartTapIntent {
        switch phase {
        case .idle, .ended, .failed:
            return .startSession
        case .waitingUser, .aiSpeaking:
            return usesAutoVAD ? .none : .beginTurn
        case .processing:
            // Only the two wait stages accept a new turn. The pipeline stages
            // are still working on the current one, so a tap there must not
            // open a second turn on top of it.
            let accepting = processingStage == .evaluation || processingStage == .aiAnswer
            return (accepting && !usesAutoVAD) ? .beginTurn : .none
        default:
            return .none
        }
    }

    /// Recording stop submits the turn. Degraded text ends the session — ending
    /// is the only action that is always correct there. Session end elsewhere
    /// stays on the close button.
    public var stopTapIntent: StopTapIntent {
        switch phase {
        case .recording:
            return .endTurn
        case .degradedText:
            return .endSession
        default:
            return .none
        }
    }

    var controlState: SpeakingRoomControlState {
        switch phase {
        case .idle:
            return .init(
                title: "点击开始录音",
                detail: "进入实时口语练习后，系统会自动识别你的语音并给出反馈。",
                accent: .primary,
                showsProgress: false,
                primaryAction: .start(title: "开始录音", systemImage: "mic.circle.fill")
            )
        case .connecting:
            return .init(
                title: "连接中...",
                detail: "正在建立语音会话，请稍候。",
                accent: .neutral,
                showsProgress: true,
                primaryAction: nil
            )
        case .recording:
            return .init(
                title: "录音中...",
                detail: "停顿一下就会自动提交这一轮，也可以点「说完了」提前结束。",
                accent: .recording,
                showsProgress: false,
                primaryAction: .stop(title: "说完了", systemImage: "checkmark.circle.fill")
            )
        case .waitingUser:
            if usesAutoVAD {
                return .init(
                    title: "轮到你了",
                    detail: "直接开口说话即可，系统会自动开始识别。",
                    accent: .primary,
                    showsProgress: false,
                    primaryAction: nil
                )
            }
            return .init(
                title: "轮到你了",
                detail: "点一次开始说话，说完停顿一下会自动提交。",
                accent: .primary,
                showsProgress: false,
                primaryAction: .start(title: "开始说话", systemImage: "mic.circle.fill")
            )
        case .processing:
            // One phase, five stages. The pipeline stages are "busy"; the two
            // wait stages are not — the machine lets the user open the next
            // turn from them, so a spinner there said both "busy" and "go".
            switch processingStage {
            case .asr:
                return .init(
                    title: "识别中",
                    detail: "正在识别你的语音。",
                    accent: .neutral,
                    showsProgress: true,
                    primaryAction: nil
                )
            case .llm:
                return .init(
                    title: "思考中",
                    detail: "正在生成回复。",
                    accent: .neutral,
                    showsProgress: true,
                    primaryAction: nil
                )
            case .review:
                return .init(
                    title: "生成评价中",
                    detail: "正在生成这一轮的评价。",
                    accent: .neutral,
                    showsProgress: true,
                    primaryAction: nil
                )
            case .evaluation:
                if usesAutoVAD {
                    return .init(
                        title: "可以继续",
                        detail: "这一轮的评价还在生成，也可以直接开口开始下一轮。",
                        accent: .neutral,
                        showsProgress: false,
                        primaryAction: nil
                    )
                }
                return .init(
                    title: "可以继续",
                    detail: "这一轮的评价还在生成，你也可以直接开始下一轮。",
                    accent: .neutral,
                    showsProgress: false,
                    primaryAction: .start(title: "开始说话", systemImage: "mic.circle.fill")
                )
            case .aiAnswer:
                // I21: the recording was aborted and its answer is still on the
                // way, so this reads as "that turn timed out" rather than as
                // "the system is working".
                if usesAutoVAD {
                    return .init(
                        title: "本轮已超时",
                        detail: "直接开口开始下一轮。",
                        accent: .warning,
                        showsProgress: false,
                        primaryAction: nil
                    )
                }
                return .init(
                    title: "本轮已超时",
                    detail: "录音超时已取消这一轮，点击开始说话继续。",
                    accent: .warning,
                    showsProgress: false,
                    primaryAction: .start(title: "开始说话", systemImage: "mic.circle.fill")
                )
            case nil:
                // Phase and stage drifted apart. Say nothing specific rather
                // than pick a copy and be wrong about what is happening.
                return .init(
                    title: "处理中",
                    detail: "正在处理这一轮。",
                    accent: .neutral,
                    showsProgress: true,
                    primaryAction: nil
                )
            }
        case .aiSpeaking:
            if usesAutoVAD {
                return .init(
                    title: "AI 回应中",
                    detail: "请先听完回复，下一轮可以继续开口。",
                    accent: .secondary,
                    showsProgress: false,
                    primaryAction: nil
                )
            }
            return .init(
                title: "AI 回应中",
                detail: "点击开始说话会打断当前回复。",
                accent: .secondary,
                showsProgress: false,
                primaryAction: .start(title: "开始说话", systemImage: "mic.circle.fill")
            )
        case .degradedText:
            return .init(
                title: "网络不稳定",
                detail: "语音链路已降级，当前会话无法恢复。结束这次练习后重新开始，会接上这一段。",
                accent: .warning,
                showsProgress: false,
                primaryAction: .stop(title: "结束这次练习", systemImage: "xmark.circle.fill")
            )
        case .ended:
            return .init(
                title: "本轮已结束",
                detail: "可以重新开始下一轮练习。",
                accent: .secondary,
                showsProgress: false,
                primaryAction: .start(title: "重新开始", systemImage: "arrow.clockwise.circle.fill")
            )
        case .failed:
            return .init(
                title: "录音失败",
                detail: failureReason ?? "会话启动失败，请重试。",
                accent: .warning,
                showsProgress: false,
                primaryAction: .start(title: "重试", systemImage: "arrow.clockwise.circle.fill")
            )
        }
    }
}

struct SpeakingRoomControlState: Equatable, Sendable {
    enum Accent: Equatable, Sendable {
        case primary
        case secondary
        case neutral
        case recording
        case warning
    }

    enum PrimaryAction: Equatable, Sendable {
        case start(title: String, systemImage: String)
        case stop(title: String, systemImage: String)
    }

    let title: String
    let detail: String?
    let accent: Accent
    let showsProgress: Bool
    let primaryAction: PrimaryAction?
}

struct SpeakingRoomPermissionGate: Sendable {
    let requestMicrophonePermission: @Sendable () async -> Bool

    func canStart() async -> Bool {
        await requestMicrophonePermission()
    }
}

// MARK: - Root View

public struct SpeakingRoomView: View {
    let model: SpeakingRoomViewModel
    let onStartTapped: () -> Void
    let onStopTapped: () -> Void
    /// 顶部栏左边的返回（稿子 屏 02 的 `[app-icon-btn]`）。
    let onClose: () -> Void
    let onRescueHintTapped: () -> Void
    let onHitTapped: (SpeakingRoomTimelineHit) -> Void
    let requestMicrophonePermission: @Sendable () async -> Bool
    let openSettingsAction: @Sendable () -> Void
    /// DEBUG-only — wired by `HostRootView` to dispatch a `.speakingRoom(.badgeHit(...))`
    /// action so the I11 overlay can be visually verified without needing a real
    /// B12 corpus match. Production builds leave this `nil` and the debug footer
    /// is hidden.
    let onDebugBadgeInjected: ((BadgeFeedEntry.Tier, Int) -> Void)?

    @State private var showPermissionDeniedAlert = false
    #if DEBUG
    /// 0 = unknown, 1 = badgeOnly, 2 = nextTurnConfirm, 3 = sameTurnConfirm.
    /// Cycles on every inject tap so the developer can compare all four visual
    /// weights without leaving DEBUG.
    @State private var debugBadgeTierIndex: Int = 0
    @State private var debugBadgeHitCount: Int = 0
    #endif

    public init(
        model: SpeakingRoomViewModel,
        onStartTapped: @escaping () -> Void,
        onStopTapped: @escaping () -> Void,
        onClose: @escaping () -> Void = {},
        onRescueHintTapped: @escaping () -> Void = {},
        onHitTapped: @escaping (SpeakingRoomTimelineHit) -> Void = { _ in },
        requestMicrophonePermission: @escaping @Sendable () async -> Bool = {
            await MicrophonePermission.request()
        },
        openSettingsAction: @escaping @Sendable () -> Void = {
            #if canImport(UIKit)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            #endif
        },
        onDebugBadgeInjected: ((BadgeFeedEntry.Tier, Int) -> Void)? = nil
    ) {
        self.model = model
        self.onStartTapped = onStartTapped
        self.onStopTapped = onStopTapped
        self.onClose = onClose
        self.onRescueHintTapped = onRescueHintTapped
        self.onHitTapped = onHitTapped
        self.requestMicrophonePermission = requestMicrophonePermission
        self.openSettingsAction = openSettingsAction
        self.onDebugBadgeInjected = onDebugBadgeInjected
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar

            timelineScroll

            Spacer(minLength: DesignTokens.Spacing.s2)

            rescueSection

            dock

            #if DEBUG
            // B12 / I11 debug surface. Hidden in release. The footer cycles
            // through all four badge tiers (unknown / soft / highlight /
            // celebrate) on every tap so the developer can confirm the
            // overlay visually renders each visual weight without depending
            // on real B12 corpus hits. Wired in `HostRootView` to dispatch
            // `.speakingRoom(.badgeHit(...))` — i.e. the same action the
            // backend `feedback.badge` frame lands in.
            if let onDebugBadgeInjected {
                debugBadgeFooter(onTap: onDebugBadgeInjected)
            }
            #endif
        }
        .background(DesignTokens.Color.background)
        .alert("需要麦克风权限", isPresented: $showPermissionDeniedAlert) {
            Button("去设置", role: .none) {
                openAppSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("FluentWork 需要麦克风权限来进行英语口语练习。请在设置中允许访问麦克风。")
        }
    }

    // MARK: - 顶部栏（稿子 [room-top]：返回 / 场景与轮次 / 结束本轮）

    private var topBar: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.s3) {
            Button(action: onClose) {
                DesignTokens.Icon.chevronLeft.image
                    .font(.system(size: DesignTokens.Component.iconPointSize * 0.8, weight: .medium))
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .frame(
                        width: DesignTokens.Component.minHitTarget,
                        height: DesignTokens.Component.minHitTarget,
                        alignment: .leading
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")
            .accessibilityIdentifier("room.back")

            VStack(alignment: .leading, spacing: 1) {
                if let scene = model.sceneLabel {
                    Text(scene)
                        .font(DesignTokens.Typography.cardTitle)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                }
                // 「第 3 轮 · 标准会话」——两个事实各可能没有，**没有就不写那一段**，
                // 不拿一个空的中隔点占位。
                if let subtitle = topBarSubtitle {
                    Text(subtitle)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.s2)

            Button {
                onStopTapped()
            } label: {
                Text("结束本轮")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .padding(.horizontal, DesignTokens.Spacing.s3)
                    .padding(.vertical, DesignTokens.Spacing.s1)
                    .background(DesignTokens.Color.backgroundElevated, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("room.endTurn")
        }
        .padding(.horizontal, DesignTokens.Spacing.pageMargin)
        .padding(.vertical, DesignTokens.Spacing.s2)
    }

    private var topBarSubtitle: String? {
        switch (model.roundText, model.lengthText) {
        case let (round?, length?):
            return "\(round) · \(length)"
        case let (round?, nil):
            return round
        case let (nil, length?):
            return length
        case (nil, nil):
            return nil
        }
    }

    // MARK: - 时间线

    private var timelineScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignTokens.Spacing.s3) {
                    ForEach(model.timeline) { row in
                        timelineRow(row)
                            .id(row.id)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.pageMargin)
                .padding(.vertical, DesignTokens.Spacing.s2)
            }
            .onChange(of: model.timeline.count) { _, _ in
                if let lastID = model.timeline.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// 一条气泡：AI 靠左、学员靠右；命中标记挂在学员那条上；两个标记各自有出处。
    @ViewBuilder
    private func timelineRow(_ row: SpeakingRoomTimelineRow) -> some View {
        HStack(spacing: DesignTokens.Spacing.s2) {
            if row.isUser {
                Spacer(minLength: DesignTokens.Spacing.s6)
            }

            VStack(alignment: row.isUser ? .trailing : .leading, spacing: DesignTokens.Spacing.s1) {
                if !row.hits.isEmpty {
                    HStack(spacing: DesignTokens.Spacing.s2) {
                        ForEach(row.hits) { hit in
                            Button {
                                onHitTapped(hit)
                            } label: {
                                Label(hit.badge, systemImage: "sparkles")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundStyle(DesignTokens.Color.accent)
                                    .padding(.horizontal, DesignTokens.Spacing.s2)
                                    .padding(.vertical, 3)
                                    .background(DesignTokens.Color.accent.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("收藏命中表达 \(hit.badge)")
                        }
                    }
                }

                bubble(row)

                // 说话人 + 两个标记。**「重播 / 可回听」先不画**：那要音频通道
                // （重播要这一段的时间戳，回听要录音），画一个点了没反应的按钮
                // 比不画更糟。见走查清单的「没做的」一节。
                HStack(spacing: DesignTokens.Spacing.s2) {
                    Text(row.isUser ? "你说" : "AI")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Color.textSecondary)

                    if row.isStallPoint {
                        marker(SpeakingRoomTimelineRow.stallPointMarker, color: DesignTokens.Color.training)
                    }
                    if row.wasInterrupted {
                        marker(SpeakingRoomTimelineRow.interruptedMarker, color: DesignTokens.Color.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: row.isUser ? .trailing : .leading)

            if !row.isUser {
                Spacer(minLength: DesignTokens.Spacing.s6)
            }
        }
    }

    /// 气泡本体。**被打断的截断标记画在尾部**（稿子：AI 气泡尾部加灰色截断标记）——
    /// 断在半句的地方就是读者会去找答案的地方。
    @ViewBuilder
    private func bubble(_ row: SpeakingRoomTimelineRow) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: DesignTokens.Spacing.s1) {
            Text(row.text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.textPrimary)
                .multilineTextAlignment(row.isUser ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)

            if row.isListening {
                Text("正在转写…")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }

            if row.wasInterrupted {
                Text("…")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .accessibilityLabel(SpeakingRoomTimelineRow.interruptedMarker)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.s3)
        .padding(.vertical, DesignTokens.Spacing.s2)
        .background(
            row.isUser ? DesignTokens.Color.wash : DesignTokens.Color.backgroundElevated,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
    }

    private func marker(_ title: String, color: SwiftUI.Color) -> some View {
        Text(title)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(color)
            .padding(.horizontal, DesignTokens.Spacing.s2)
            .padding(.vertical, 2)
            .background(DesignTokens.Color.wash, in: Capsule())
    }

    // MARK: - 底部 dock（状态行 / 浮层 / 说话键 / 安抚句）

    private var dock: some View {
        VStack(spacing: DesignTokens.Spacing.s2) {
            Text(model.statusLineText)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Color.textSecondary)
                .accessibilityIdentifier("room.statusLine")

            if let text = model.liveTranscriptFloat {
                liveTranscriptFloat(text)
            }

            talkButton

            if let hint = model.dockHintText {
                Text(hint)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("room.dockHint")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.Spacing.pageMargin)
        .padding(.top, DesignTokens.Spacing.s2)
        .background(DesignTokens.Color.backgroundElevated)
    }

    /// 实时转录浮层：**只在录音时存在**（稿子：仅录音时出现，话音落下后归位到气泡）。
    ///
    /// 「同一句话不出现在两处」这条规则住在投影里（`liveTranscriptFloat`），
    /// 视图只负责把它画出来 —— 所以这里读不到值就是真的没有。
    private func liveTranscriptFloat(_ text: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.s2) {
            DesignTokens.Icon.wave.image
                .font(.system(size: DesignTokens.Component.iconPointSize * 0.7))
                .foregroundStyle(DesignTokens.Color.accent)
                .symbolEffect(.variableColor.iterative, options: .repeating)

            Text(text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Color.textPrimary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Spacing.s3)
        .padding(.vertical, DesignTokens.Spacing.s2)
        .background(
            DesignTokens.Color.background,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .accessibilityIdentifier("room.liveTranscript")
    }

    /// **72pt 胶囊三态**（稿子 屏 02 的「说话键」）。
    ///
    /// - 等待说话：静态，3 秒周期 3% 幅度的呼吸缩放（不是闪烁 —— 闪烁在催人，呼吸在等人）；
    /// - 录音中：胶囊换成录音色，浮层在它上方滚动；
    /// - 处理中：环形进度 ＋ 三点动效，**不显示百分比**（进度百分比在这一屏没有意义：
    ///   学员既不知道它算到哪，也不能做任何事）。
    @ViewBuilder
    private var talkButton: some View {
        let control = model.controlState

        Button {
            switch control.primaryAction {
            case .start:
                Task { await requestStartWithPermission() }
            case .stop:
                onStopTapped()
            case nil:
                break
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(talkButtonFill(control.accent))
                    .frame(height: 72)

                if model.phase == .processing {
                    HStack(spacing: DesignTokens.Spacing.s3) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(DesignTokens.Color.textPrimary)
                        ThreeDotsIndicator()
                    }
                } else {
                    HStack(spacing: DesignTokens.Spacing.s2) {
                        Image(systemName: model.isRecording ? "checkmark" : "mic.fill")
                            .font(.system(size: DesignTokens.Component.iconPointSize, weight: .semibold))
                        Text(primaryActionTitle(control.primaryAction))
                            .font(DesignTokens.Typography.cardTitle)
                    }
                    .foregroundStyle(DesignTokens.Color.textPrimary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(control.primaryAction == nil)
        .modifier(BreathingCapsule(isActive: model.phase == .waitingUser))
        .accessibilityIdentifier("room.talkButton")
    }

    private func primaryActionTitle(_ action: SpeakingRoomControlState.PrimaryAction?) -> String {
        switch action {
        case let .start(title, _), let .stop(title, _):
            return title
        case nil:
            // 不可点的时候（自动 VAD 的等待态、处理中）按钮上写的是**状态**，不是动作 ——
            // 一个写着「开始说话」却按不动的按钮，是在骗人去点。
            return model.isRecording ? "我正在听" : "等待中"
        }
    }

    private func talkButtonFill(_ accent: SpeakingRoomControlState.Accent) -> LinearGradient {
        LinearGradient(
            colors: [backgroundColor(for: accent), backgroundColor(for: accent).opacity(0.72)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 救援：三句一组（稿子 屏 03 的 `[status-line]` ＋ `[hint]` ＋ 按钮）。
    @ViewBuilder
    private var rescueSection: some View {
        if let headline = model.rescueHeadline {
            VStack(spacing: DesignTokens.Spacing.s2) {
                Text(headline)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)

                Button {
                    onRescueHintTapped()
                } label: {
                    Label(model.rescueButtonTitle, systemImage: "lightbulb")
                        .font(DesignTokens.Typography.cardTitle)
                        .foregroundStyle(DesignTokens.Color.textPrimary)
                        .padding(.horizontal, DesignTokens.Spacing.s4)
                        .frame(minHeight: DesignTokens.Component.minHitTarget)
                        .background(DesignTokens.Color.brandStrong, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("room.rescueHint")

                Text(model.rescueReassurance)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Color.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DesignTokens.Spacing.pageMargin)
            .padding(.bottom, DesignTokens.Spacing.s2)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.24), value: model.isRescueHintAvailable)
            .accessibilityIdentifier("room.rescue")
        }
    }


    #if DEBUG
    private func debugBadgeFooter(
        onTap: @escaping (BadgeFeedEntry.Tier, Int) -> Void
    ) -> some View {
        let tier: BadgeFeedEntry.Tier
        switch debugBadgeTierIndex {
        case 1: tier = .badgeOnly
        case 2: tier = .nextTurnConfirm
        case 3: tier = .sameTurnConfirm
        default: tier = .unknown
        }
        return VStack(spacing: 4) {
            Divider().opacity(0.3)
            HStack {
                Image(systemName: "ladybug.fill")
                    .foregroundStyle(.orange)
                Text("DEBUG · 注入徽章 (\(tierName(tier)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("× \(debugBadgeHitCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .contentShape(Rectangle())
            .onTapGesture {
                debugBadgeTierIndex = (debugBadgeTierIndex + 1) % 4
                debugBadgeHitCount += 1
                onTap(tier, debugBadgeHitCount)
            }
        }
    }

    private func tierName(_ tier: BadgeFeedEntry.Tier) -> String {
        switch tier {
        case .unknown: return "unknown"
        case .badgeOnly: return "soft"
        case .nextTurnConfirm: return "highlight"
        case .sameTurnConfirm: return "celebrate"
        }
    }
    #endif

    // MARK: - Recording Button

    private func openAppSettings() {
        openSettingsAction()
    }

    private func requestStartWithPermission() async {
        let gate = SpeakingRoomPermissionGate(
            requestMicrophonePermission: requestMicrophonePermission
        )
        if await gate.canStart() {
            onStartTapped()
        } else {
            showPermissionDeniedAlert = true
        }
    }


    private func backgroundColor(for accent: SpeakingRoomControlState.Accent) -> Color {
        switch accent {
        case .primary:
            return Color.blue.opacity(0.06)
        case .secondary:
            return Color.indigo.opacity(0.06)
        case .neutral:
            return Color.gray.opacity(0.08)
        case .recording:
            return Color.red.opacity(0.06)
        case .warning:
            return Color.orange.opacity(0.06)
        }
    }

}

// MARK: - 说话键上的两个小动效

/// 等待说话时的**呼吸**：3 秒一个周期、幅度 3%（稿子 屏 02 的语音状态机表）。
///
/// 呼吸与闪烁的区别不是审美：闪烁在**催**人（它有一种「快点」的意味），
/// 而这一屏恰恰要等一个刚开口的人。所以周期长、幅度小、不停顿。
private struct BreathingCapsule: ViewModifier {
    let isActive: Bool

    @State private var isExpanded = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isExpanded ? 1.03 : 1.0)
            .onAppear { updateAnimation() }
            .onChange(of: isActive) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        guard isActive else {
            withAnimation(.easeOut(duration: 0.2)) { isExpanded = false }
            return
        }
        // 1.5s 单程 + 自动往返 = 3s 一个周期。
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            isExpanded = true
        }
    }
}

/// 处理中的三个点。**不显示百分比**：学员既不知道它算到哪，也不能做任何事 ——
/// 一个数字只会让他盯着它。
private struct ThreeDotsIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(DesignTokens.Color.textPrimary)
                    .frame(
                        width: DesignTokens.Component.statusDotDiameter * 0.7,
                        height: DesignTokens.Component.statusDotDiameter * 0.7
                    )
                    .opacity(phase == index ? 1 : 0.35)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
extension SpeakingRoomViewModel {
    public static let previewIdle = SpeakingRoomViewModel(
        phase: .idle
    )

    public static let previewConnecting = SpeakingRoomViewModel(
        phase: .connecting
    )

    public static let previewRecording = SpeakingRoomViewModel(
        phase: .recording,
        liveTranscript: "Hello, how are you doing today?",
        lastBadge: "表达自然",
        badgeHits: 3
    )

    public static let previewFailed = SpeakingRoomViewModel(
        phase: .failed,
        failureReason: "麦克风权限被拒绝"
    )

    public static let previewRescueHint = SpeakingRoomViewModel(
        phase: .waitingUser,
        isRescueHintAvailable: true
    )
}

#Preview("Idle") {
    NavigationStack {
        SpeakingRoomView(
            model: .previewIdle,
            onStartTapped: {},
            onStopTapped: {}
        )
        .navigationTitle("说的房间")
    }
}

#Preview("Connecting") {
    NavigationStack {
        SpeakingRoomView(
            model: .previewConnecting,
            onStartTapped: {},
            onStopTapped: {}
        )
        .navigationTitle("说的房间")
    }
}

#Preview("Recording") {
    NavigationStack {
        SpeakingRoomView(
            model: .previewRecording,
            onStartTapped: {},
            onStopTapped: {}
        )
        .navigationTitle("说的房间")
    }
}

#Preview("Failed") {
    NavigationStack {
        SpeakingRoomView(
            model: .previewFailed,
            onStartTapped: {},
            onStopTapped: {}
        )
        .navigationTitle("说的房间")
    }
}

#Preview("Rescue hint") {
    NavigationStack {
        SpeakingRoomView(
            model: .previewRescueHint,
            onStartTapped: {},
            onStopTapped: {}
        )
        .navigationTitle("说的房间")
    }
}
#endif
