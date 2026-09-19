import FluentWorkNetworking
import Foundation

/// 把 `WSAudioFrameDecoder`（codec 层）接成 `AudioFrameDecoder`（轮次层的 seam）。
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
