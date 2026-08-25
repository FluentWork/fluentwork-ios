import Foundation

/// Decoded Opus audio frame with a server-monotonic sequence number.
public struct WSAudioFrame: Equatable, Sendable {
    public var sequence: UInt32
    public var opusPayload: Data

    public init(sequence: UInt32, opusPayload: Data) {
        self.sequence = sequence
        self.opusPayload = opusPayload
    }
}

public enum WSAudioFrameCodecError: Error, Equatable, Sendable {
    case truncatedHeader
}

/// Binary layout: `UInt32` big-endian sequence + Opus payload bytes.
public enum WSAudioFrameCodec: Sendable {
    public static let headerByteCount = 4

    public static func encode(_ frame: WSAudioFrame) -> Data {
        var data = Data()
        data.reserveCapacity(headerByteCount + frame.opusPayload.count)
        var sequence = frame.sequence.bigEndian
        withUnsafeBytes(of: &sequence) { data.append(contentsOf: $0) }
        data.append(frame.opusPayload)
        return data
    }

    public static func decode(_ data: Data) throws -> WSAudioFrame {
        guard data.count >= headerByteCount else {
            throw WSAudioFrameCodecError.truncatedHeader
        }

        let sequence = data.prefix(headerByteCount).withUnsafeBytes { buffer -> UInt32 in
            UInt32(bigEndian: buffer.load(as: UInt32.self))
        }
        let payload = data.dropFirst(headerByteCount)
        return WSAudioFrame(sequence: sequence, opusPayload: Data(payload))
    }
}
