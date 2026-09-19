import Foundation

/// A downstream audio frame with a server-monotonic sequence number.
///
/// The payload is whatever the active `ai.tts.start` codec says it is — Opus in
/// the gateway's current shape, already-PCM16 under `RawPCM16FrameDecoder`. The
/// field is named `payload`, not `opusPayload`, so the name stops claiming a
/// codec the decoder is the one to decide.
public struct WSAudioFrame: Equatable, Sendable {
    public var sequence: UInt32
    public var payload: Data

    public init(sequence: UInt32, payload: Data) {
        self.sequence = sequence
        self.payload = payload
    }
    
    @available(*, deprecated, renamed: "payload")
    public var opusPayload: Data {
        get { payload }
        set { payload = newValue }
    }
}

public enum WSAudioFrameCodecError: Error, Equatable, Sendable {
    case truncatedHeader(byteCount: Int)
}

/// Binary layout: `UInt32` big-endian sequence + Opus payload bytes.
public enum WSAudioFrameCodec: Sendable {
    public static let headerByteCount = 4

    public static func encode(_ frame: WSAudioFrame) -> Data {
        var data = Data()
        data.reserveCapacity(headerByteCount + frame.payload.count)
        var sequence = frame.sequence.bigEndian
        withUnsafeBytes(of: &sequence) { data.append(contentsOf: $0) }
        data.append(frame.payload)
        return data
    }

    public static func decode(_ data: Data) throws -> WSAudioFrame {
        guard data.count >= headerByteCount else {
            throw WSAudioFrameCodecError.truncatedHeader(byteCount: data.count)
        }

        let sequence = data.prefix(headerByteCount).withUnsafeBytes { buffer -> UInt32 in
            UInt32(bigEndian: buffer.load(as: UInt32.self))
        }
        let payload = data.dropFirst(headerByteCount)
        return WSAudioFrame(sequence: sequence, payload: Data(payload))
    }
}

extension WSAudioFrameCodecError: LocalizedError {
    /// Stable, human-readable detail for the receiving side. The default
    /// Swift→NSError bridge would render this as
    /// `"the operation couldn't be completed. (FluentWorkNetworking.WSAudioFrameCodecError error 0.)"`,
    /// which is what the iOS console currently shows as `framecodingerror error 0`.
    /// Adding `LocalizedError` makes the iOS surface readable and lets the
    /// `SocketTransportError.decodingFailed` carry the byte count alongside
    /// the error case so the source is identifiable in logs.
    public var errorDescription: String? {
        switch self {
        case let .truncatedHeader(byteCount):
            return "audio frame header is missing or truncated (received \(byteCount) bytes, header requires \(WSAudioFrameCodec.headerByteCount))"
        }
    }
}
