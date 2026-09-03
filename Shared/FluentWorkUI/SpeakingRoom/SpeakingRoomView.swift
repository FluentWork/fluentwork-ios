import SwiftUI
import FluentWorkCore

#if canImport(UIKit)
import UIKit
#endif

// MARK: - View Model

public struct SpeakingRoomTimelineHit: Equatable, Sendable, Identifiable {
    public let id: String
    public let badge: String

    public init(id: String, badge: String) {
        self.id = id
        self.badge = badge
    }
}

public struct SpeakingRoomTimelineRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let isUser: Bool
    public let text: String
    public let isListening: Bool
    public let hits: [SpeakingRoomTimelineHit]

    public init(
        id: String,
        isUser: Bool,
        text: String,
        isListening: Bool,
        hits: [SpeakingRoomTimelineHit]
    ) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.isListening = isListening
        self.hits = hits
    }
}

public struct SpeakingRoomViewModel: Equatable, Sendable {
    public var phase: SpeechSessionPhase
    public var liveTranscript: String
    public var lastBadge: String?
    public var badgeHits: Int
    public var failureReason: String?
    public var timeline: [SpeakingRoomTimelineRow]

    public init(
        phase: SpeechSessionPhase,
        liveTranscript: String = "",
        lastBadge: String? = nil,
        badgeHits: Int = 0,
        failureReason: String? = nil,
        timeline: [SpeakingRoomTimelineRow] = []
    ) {
        self.phase = phase
        self.liveTranscript = liveTranscript
        self.lastBadge = lastBadge
        self.badgeHits = badgeHits
        self.failureReason = failureReason
        self.timeline = timeline
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
                detail: "点击停止后会提交这一轮语音。",
                accent: .recording,
                showsProgress: false,
                primaryAction: .stop(title: "停止录音", systemImage: "stop.circle.fill")
            )
        case .waitingUser:
            return .init(
                title: "轮到你了",
                detail: "直接开口说话即可，系统会自动开始识别。",
                accent: .primary,
                showsProgress: false,
                primaryAction: nil
            )
        case .processing:
            return .init(
                title: "处理中",
                detail: "正在识别你的语音并等待回复。",
                accent: .neutral,
                showsProgress: true,
                primaryAction: nil
            )
        case .aiSpeaking:
            return .init(
                title: "AI 回应中",
                detail: "请先听完回复，下一轮可以继续开口。",
                accent: .secondary,
                showsProgress: false,
                primaryAction: nil
            )
        case .degradedText:
            return .init(
                title: "网络不稳定",
                detail: "语音链路已降级，当前会话需要恢复后再继续。",
                accent: .warning,
                showsProgress: false,
                primaryAction: nil
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
        self.requestMicrophonePermission = requestMicrophonePermission
        self.openSettingsAction = openSettingsAction
        self.onDebugBadgeInjected = onDebugBadgeInjected
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Recording button
            recordingButton
                .padding(.horizontal, 32)

            // Turn timeline (design 22) — fall back to the legacy single
            // transcript while a session has not produced timeline rows yet.
            if !model.timeline.isEmpty {
                timelineView
                    .frame(maxHeight: 260)
                    .padding(.horizontal, 8)
            } else if !model.liveTranscript.isEmpty {
                transcriptView
                    .padding(.horizontal, 24)
            }

            // Stats
            statsView
                .padding(.horizontal, 24)

            Spacer()

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
        .padding()
        .alert("需要麦克风权限", isPresented: $showPermissionDeniedAlert) {
            Button("去设置", role: .none) {
                openAppSettings()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("FluentWork 需要麦克风权限来进行英语口语练习。请在设置中允许访问麦克风。")
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

    private var recordingButton: some View {
        let controlState = model.controlState

        return VStack(spacing: 16) {
            if controlState.showsProgress {
                ProgressView()
                    .scaleEffect(1.25)
            } else {
                Image(systemName: symbolName(for: controlState))
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(accentColor(for: controlState.accent))
            }

            Text(controlState.title)
                .font(.headline)
                .foregroundStyle(accentColor(for: controlState.accent))

            if let detail = controlState.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let action = controlState.primaryAction {
                primaryActionButton(action)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .background(backgroundColor(for: controlState.accent))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func primaryActionButton(_ action: SpeakingRoomControlState.PrimaryAction) -> some View {
        switch action {
        case let .start(title, systemImage):
            Button {
                Task {
                    await requestStartWithPermission()
                }
            } label: {
                Label(title, systemImage: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.blue.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

        case let .stop(title, systemImage):
            Button {
                onStopTapped()
            } label: {
                Label(title, systemImage: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    // MARK: - Transcript View

    private var timelineView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.timeline) { row in
                        timelineRow(row)
                            .id(row.id)
                    }
                }
                .padding(.vertical, 4)
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

    @ViewBuilder
    private func timelineRow(_ row: SpeakingRoomTimelineRow) -> some View {
        HStack(spacing: 8) {
            if row.isUser {
                Spacer(minLength: 48)
            }

            VStack(alignment: row.isUser ? .trailing : .leading, spacing: 4) {
                Text(row.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(row.isUser ? .trailing : .leading)

                if row.isListening {
                    Text("正在听…")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !row.hits.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(row.hits) { hit in
                            Label(hit.badge, systemImage: "sparkles")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                row.isUser
                    ? AnyShapeStyle(Color.blue.opacity(0.12))
                    : AnyShapeStyle(Color.secondary.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 14)
            )

            if !row.isUser {
                Spacer(minLength: 48)
            }
        }
    }

    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("实时转写", systemImage: "waveform")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            Text(model.liveTranscript)
                .font(.body)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.blue.opacity(0.05))
                .cornerRadius(12)
        }
    }

    // MARK: - Stats View

    private var statsView: some View {
        HStack(spacing: 20) {
            if let badge = model.lastBadge {
                Label(badge, systemImage: "star.fill")
                    .font(.subheadline)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
            }

            if model.badgeHits > 0 {
                Label("\(model.badgeHits) Badge", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helper Methods

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

    private func accentColor(for accent: SpeakingRoomControlState.Accent) -> Color {
        switch accent {
        case .primary:
            return .blue
        case .secondary:
            return .indigo
        case .neutral:
            return .secondary
        case .recording:
            return .red
        case .warning:
            return .orange
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

    private func symbolName(for state: SpeakingRoomControlState) -> String {
        switch state.accent {
        case .primary:
            return "mic.circle.fill"
        case .secondary:
            return "message.circle.fill"
        case .neutral:
            return "waveform.circle"
        case .recording:
            return "record.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
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
#endif
