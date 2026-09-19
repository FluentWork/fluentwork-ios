import Foundation

/// 唯一的音频解码 seam：把下行音频帧解码成 16k mono PCM16。
///
/// ## 为什么在这里
///
/// `TTSPlaybackCoordinator` 只负责「播/丢」的决策；payload 到底是 Opus 还是
/// 已经是 PCM16，是实现细节，藏在 seam 后面。这样 Stage 3 后端把二进制帧
/// 切成 Opus 时，coordinator 的决策逻辑不动，只换 decoder。
///
/// 与 `WSAudioFrameDecoder`（`AppDependencies.swift`）并存是有意的：
/// - 本协议服务于 **带 `turn_id` 的新路径**，输入是 `TurnKeyedAudioFrame`；
/// - `WSAudioFrameDecoder` 服务于 **legacy 路径**（`EngineAudioSink.play(legacy:)`），
///   输入是 `WSAudioFrame`。
///
/// 两者在 Stage 4 收敛为单一 seam。
public protocol AudioFrameDecoder: Sendable {
    func decode(_ frame: TurnKeyedAudioFrame) async throws -> Data
}
