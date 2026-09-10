import Foundation

/// Pure interrupt drop-frame policy for AI audio frames.
///
/// After a local interrupt, keep the max observed sequence at interrupt time.
/// Later frames with `sequence <= interruptMaxSequence` are dropped so late TTS
/// chunks from before the interrupt never resume playback.
public enum AudioFrameDropPolicy: Sendable {
    /// Whether an inbound audio frame should be discarded.
    ///
    /// - `interruptMaxSequence == nil`: empty / no interrupt → never drop.
    /// - `frameSequence == interruptMaxSequence`: drop (inclusive boundary).
    /// - `frameSequence < interruptMaxSequence`: drop.
    /// - `frameSequence > interruptMaxSequence`: keep.
    /// - Wraparound is intentionally unsupported (server sequences are monotonic).
    public static func shouldDrop(
        frameSequence: UInt32,
        interruptMaxSequence: UInt32?
    ) -> Bool {
        guard let interruptMaxSequence else {
            return false
        }
        return frameSequence <= interruptMaxSequence
    }

    /// Tracks the highest sequence observed before / during playback.
    public static func updatedMaxObserved(
        current: UInt32?,
        observed: UInt32
    ) -> UInt32 {
        guard let current else {
            return observed
        }
        return max(current, observed)
    }
}

/// Tracks the barge-in drop runs a transport reports.
///
/// Extracted from `URLSessionSocketTransport` so the reporting rule is testable
/// without a live socket — the same reason ``AudioFrameDropPolicy`` was pulled
/// out of ``AudioFrameDropGate``. This type decides *what* to report; the
/// transport only decides where to send it.
///
/// A run is announced on its first drop and again when it closes, the closing
/// report carrying the count. A run that never closes still announces its
/// first drop — otherwise the worst case, a watermark that suppresses
/// everything after it, would be the one case that reports nothing.
public struct AudioDropReport: Equatable, Sendable {
    /// Frames discarded since the last reset.
    public private(set) var dropped = 0
    /// Watermark whose run has already been announced.
    public private(set) var reportedWatermark: UInt32?

    public init() {}

    /// Registers a discarded frame.
    ///
    /// - Returns: the opening report, or `nil` when this run is already open.
    public mutating func recordDrop(sequence: UInt32, watermark: UInt32) -> SocketTransportDiagnostic? {
        dropped += 1
        guard reportedWatermark != watermark else { return nil }
        reportedWatermark = watermark
        return .audioFrameDropped(sequence: sequence, watermark: watermark, dropped: dropped)
    }

    /// Closes an open run once a frame is delivered again.
    ///
    /// - Returns: the closing report with the size of the loss, or `nil` when
    ///   no run is open.
    public mutating func closeRun(watermark: UInt32?) -> SocketTransportDiagnostic? {
        guard dropped > 0 else { return nil }
        let report = SocketTransportDiagnostic.audioFrameDropped(
            sequence: 0,
            watermark: reportedWatermark ?? watermark ?? 0,
            dropped: dropped
        )
        reset()
        return report
    }

    public mutating func reset() {
        dropped = 0
        reportedWatermark = nil
    }
}

/// Mutable helper around ``AudioFrameDropPolicy`` for transport-side bookkeeping.
public struct AudioFrameDropGate: Equatable, Sendable {
    public private(set) var maxObservedSequence: UInt32?
    public private(set) var interruptMaxSequence: UInt32?

    public init(
        maxObservedSequence: UInt32? = nil,
        interruptMaxSequence: UInt32? = nil
    ) {
        self.maxObservedSequence = maxObservedSequence
        self.interruptMaxSequence = interruptMaxSequence
    }

    public mutating func observe(sequence: UInt32) {
        maxObservedSequence = AudioFrameDropPolicy.updatedMaxObserved(
            current: maxObservedSequence,
            observed: sequence
        )
    }

    /// Capture the current max as the interrupt watermark.
    public mutating func markInterrupted() {
        interruptMaxSequence = maxObservedSequence
    }

    public mutating func clearInterrupt() {
        interruptMaxSequence = nil
    }

    public func shouldDeliver(sequence: UInt32) -> Bool {
        !AudioFrameDropPolicy.shouldDrop(
            frameSequence: sequence,
            interruptMaxSequence: interruptMaxSequence
        )
    }
}
