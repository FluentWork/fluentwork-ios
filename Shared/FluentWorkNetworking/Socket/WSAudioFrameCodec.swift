import Foundation

/// A downstream audio frame with a server-monotonic sequence number.
///
/// The payload is whatever the active `ai.tts.start` codec says it is — Opus in
/// the gateway's current shape, already-PCM16 under `RawPCM16FrameDecoder`. The
/// field is named `payload`, not `opusPayload`, so the name stops claiming a
/// codec the decoder is the one to decide.
public struct WSAudioFrame: Equatable, Sendable {
    public var sequence: UInt32
    public var turnRef: UInt32?
    public var payload: Data

    public init(sequence: UInt32, turnRef: UInt32? = nil, payload: Data) {
        self.sequence = sequence
        self.turnRef = turnRef
        self.payload = payload
    }
    
    @available(*, deprecated, renamed: "payload")
    public var opusPayload: Data {
        get { payload }
        set { payload = newValue }
    }
}

public enum WSAudioFrameLayout: Sendable, Equatable {
    case h4
    case h8

    public var headerByteCount: Int {
        switch self {
        case .h4: return 4
        case .h8: return 8
        }
    }
}

public enum WSAudioFrameCodecError: Error, Equatable, Sendable {
    case truncatedHeader(byteCount: Int, requiredBytes: Int)
}

/// Binary layout: `UInt32` big-endian sequence + payload bytes, with a `UInt32`
/// big-endian `turn_ref` between them under `WSAudioFrameLayout.h8`.
public enum WSAudioFrameCodec: Sendable {
    public static let headerByteCount = WSAudioFrameLayout.h4.headerByteCount

    public static func encode(
        _ frame: WSAudioFrame,
        layout: WSAudioFrameLayout = .h4
    ) -> Data {
        var data = Data()
        data.reserveCapacity(layout.headerByteCount + frame.payload.count)
        var sequence = frame.sequence.bigEndian
        withUnsafeBytes(of: &sequence) { data.append(contentsOf: $0) }
        if layout == .h8 {
            var turnRef = (frame.turnRef ?? 0).bigEndian
            withUnsafeBytes(of: &turnRef) { data.append(contentsOf: $0) }
        }
        data.append(frame.payload)
        return data
    }

    public static func decode(
        _ data: Data,
        layout: WSAudioFrameLayout = .h4
    ) throws -> WSAudioFrame {
        let header = layout.headerByteCount
        guard data.count >= header else {
            throw WSAudioFrameCodecError.truncatedHeader(
                byteCount: data.count,
                requiredBytes: header
            )
        }

        let sequence = data.prefix(4).withUnsafeBytes { buffer -> UInt32 in
            UInt32(bigEndian: buffer.load(as: UInt32.self))
        }
        var turnRef: UInt32?
        if layout == .h8 {
            turnRef = data.dropFirst(4).prefix(4).withUnsafeBytes { buffer -> UInt32 in
                UInt32(bigEndian: buffer.load(as: UInt32.self))
            }
        }
        let payload = data.dropFirst(header)
        return WSAudioFrame(sequence: sequence, turnRef: turnRef, payload: Data(payload))
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
        case let .truncatedHeader(byteCount, requiredBytes):
            return "audio frame header is missing or truncated (received \(byteCount) bytes, header requires \(requiredBytes))"
        }
    }
}
