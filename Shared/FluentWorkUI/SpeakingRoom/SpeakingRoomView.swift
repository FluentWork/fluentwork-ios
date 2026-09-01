import SwiftUI
import FluentWorkCore

#if canImport(UIKit)
import UIKit
#endif

// MARK: - View Model

public struct SpeakingRoomViewModel: Equatable, Sendable {
    public var phase: SpeechSessionPhase
    public var liveTranscript: String
    public var lastBadge: String?
    public var badgeHits: Int
    public var failureReason: String?

    public init(
        phase: SpeechSessionPhase,
        liveTranscript: String = "",
        lastBadge: String? = nil,
        badgeHits: Int = 0,
        failureReason: String? = nil
    ) {
        self.phase = phase
        self.liveTranscript = liveTranscript
        self.lastBadge = lastBadge
        self.badgeHits = badgeHits
        self.failureReason = failureReason
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
}

// MARK: - Root View

public struct SpeakingRoomView: View {
    let model: SpeakingRoomViewModel
    let onStartTapped: () -> Void
    let onStopTapped: () -> Void

    @State private var showPermissionDeniedAlert = false

    public init(
        model: SpeakingRoomViewModel,
        onStartTapped: @escaping () -> Void,
        onStopTapped: @escaping () -> Void
    ) {
        self.model = model
        self.onStartTapped = onStartTapped
        self.onStopTapped = onStopTapped
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Recording button
            recordingButton
                .padding(.horizontal, 32)

            // Live transcript
            if !model.liveTranscript.isEmpty {
                transcriptView
                    .padding(.horizontal, 24)
            }

            // Stats
            statsView
                .padding(.horizontal, 24)

            Spacer()
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

    // MARK: - Recording Button

    @ViewBuilder
    private var recordingButton: some View {
        switch model.phase {
        case .idle:
            Button {
                Task {
                    let granted = await MicrophonePermission.request()
                    if granted {
                        onStartTapped()
                    } else {
                        showPermissionDeniedAlert = true
                    }
                }
            } label: {
                VStack(spacing: 12) {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 80))
                    Text("点击开始录音")
                        .font(.title3.bold())
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .background(Color.blue.gradient)
                .cornerRadius(20)
            }

        case .connecting:
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("连接中...")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(20)

        case .recording:
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                    Text("录音中...")
                        .font(.headline)
                        .foregroundColor(.red)
                }

                Button {
                    onStopTapped()
                } label: {
                    Label("停止录音", systemImage: "stop.circle.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)
                        .background(Color.red)
                        .cornerRadius(12)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .background(Color.red.opacity(0.05))
            .cornerRadius(20)

        case .failed:
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)

                Text("录音失败")
                    .font(.headline)

                if let reason = model.failureReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("重试") {
                    onStartTapped()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .background(Color.orange.opacity(0.05))
            .cornerRadius(20)

        case .aiSpeaking, .waitingUser, .processing, .degradedText, .ended:
            // These phases don't show recording controls
            EmptyView()
        }
    }

    // MARK: - Transcript View

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
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
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
