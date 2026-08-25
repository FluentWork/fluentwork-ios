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
