import FluentWorkNetworking
import Foundation

/// 把 `WSAudioFrameDecoder`（codec 层）接成 `AudioFrameDecoder`（轮次层的 seam）。
///
/// ## 为什么是一个适配器，而不是第二个解码器
///
/// 审计（`docs/70_tts_wss_refactor/01`）把「双解码器」列为病根之一：两条并行播放
/// 路径各有一个 decoder，于是「payload 到底是什么」这件事有两个答案。这里刻意
/// 只保留实现：legacy 路径由引擎内部用 `wsAudioFrameDecoder` 解码，带轮次归属的
/// 路径由本适配器用**同一个工厂实例**解码 —— 一个 codec 实现，两个调用点。
///
/// ## 为什么 payload 就是 PCM
///
/// 网关今天发的是重采样后的裸 PCM16（`meta 83_` §4.1：`codec` 应当填 `pcm`，
/// 而不是 `opus`），生产绑定因此是 `RawPCM16FrameDecoder`。等 B13 把 Opus 上主线，
/// 换的是那个工厂的绑定，本适配器与协调器都不动。
public struct WSAudioFrameDecoderAdapter: AudioFrameDecoder {
    private let decoder: any WSAudioFrameDecoder

    public init(decoder: any WSAudioFrameDecoder) {
        self.decoder = decoder
    }

    public func decode(_ frame: TurnKeyedAudioFrame) async throws -> Data {
        try await decoder.decode(
            WSAudioFrame(sequence: frame.sequence, payload: frame.payload)
        )
    }
}
