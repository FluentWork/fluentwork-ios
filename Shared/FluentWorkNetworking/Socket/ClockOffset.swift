import Foundation

/// One estimate of how far the gateway's clock sits from the phone's.
///
/// The gap is what makes `server_ts_ms` unusable on its own: the field is a
/// plain epoch-millisecond stamp from the gateway, and subtracting it from
/// `Date()` on the phone measures the clock skew as much as the latency. This
/// value is the correction term.
public struct ClockOffset: Equatable, Sendable {
    /// How far the gateway's clock runs ahead of the phone's, in milliseconds.
    ///
    /// Positive means the gateway is fast. It is `server - local`, so putting a
    /// gateway timestamp onto the local clock means **subtracting** it — see
    /// ``serverToLocalMs(_:)``. Adding is the sign error this value invites, and
    /// it produces a plausible-looking latency that is wrong by twice the skew.
    public let milliseconds: Int64
    /// Half the round trip this sample came from.
    ///
    /// Not decoration: the true offset lies within ±this of ``milliseconds``,
    /// because the gateway handled the ping somewhere inside the round trip.
    /// A 400 ms round trip gives a ±200 ms error bar, which is wider than the
    /// first-response improvement the offset exists to measure — so the
    /// interval, not the offset alone, is what decides whether a number is
    /// worth quoting.
    public let uncertaintyMs: Int64
    /// The round trip the estimate came from, kept for logging.
    public let roundTripMs: Int64

    public init(milliseconds: Int64, uncertaintyMs: Int64, roundTripMs: Int64) {
        self.milliseconds = milliseconds
        self.uncertaintyMs = uncertaintyMs
        self.roundTripMs = roundTripMs
    }

    /// Puts a gateway timestamp onto the local clock.
    ///
    /// Subtracts: a gateway running 5 s fast stamps `now + 5_000`, so the local
    /// instant behind that stamp is 5 s earlier, not 5 s later.
    public func serverToLocalMs(_ serverMs: Int64) -> Int64 {
        serverMs - milliseconds
    }

    /// One-way gateway→phone latency for a stamped frame.
    ///
    /// Carries ``uncertaintyMs`` of slop, which is why callers that quote this
    /// number should quote the interval with it: a 200 ms error bar is larger
    /// than the first-response improvement it is being used to demonstrate.
    public func oneWayLatencyMs(serverMs: Int64, localReceiveMs: Int64) -> Int64 {
        localReceiveMs - serverToLocalMs(serverMs)
    }
}

/// The wire convention that makes a clock estimate possible at all.
public enum ClockProbe {
    /// Rewrites an outgoing ping so the gateway answers with **its own** clock.
    ///
    /// `voicegateway/handler.go` replies to a ping with a pong carrying the
    /// ping's `ts` straight back, and substitutes `h.now()` only when that `ts`
    /// is 0. A client-stamped ping therefore buys an echo — and an echo is the
    /// dangerous kind of wrong: fed to ``ClockOffsetEstimator`` it yields an
    /// offset of roughly `-roundTrip/2`, which reads as a plausible
    /// few-millisecond skew rather than as a failure.
    ///
    /// Normalising in one place, rather than trusting every caller to remember,
    /// is what keeps that mistake unrepresentable.
    public static func outgoing(_ frame: WSControlFrame) -> WSControlFrame {
        guard case .ping = frame else { return frame }
        return .ping(ts: 0)
    }
}

/// Accumulates ping/pong round trips into the best clock-offset estimate seen.
///
/// Pure and mutable-by-value on purpose: ``URLSessionSocketTransport`` holds one
/// as actor state, the same shape as ``AudioFrameDropGate`` — the *rule* lives
/// here so it is testable without a socket, and the transport only decides
/// where the samples come from.
public struct ClockOffsetEstimator: Equatable, Sendable {
    /// Lowest-round-trip sample so far, or `nil` before the first usable one.
    public private(set) var best: ClockOffset?

    public init() {}

    /// Feeds one completed ping/pong round trip.
    ///
    /// - Parameters:
    ///   - localSendMs: phone clock, when the ping left.
    ///   - localReceiveMs: phone clock, when the pong arrived.
    ///   - serverMs: gateway clock from the pong. The gateway only puts its own
    ///     clock there when the ping's `ts` is 0 — `voicegateway/handler.go`
    ///     substitutes `h.now()` for a zero `ts` and echoes anything else.
    public mutating func record(
        localSendMs: Int64,
        localReceiveMs: Int64,
        serverMs: Int64
    ) {
        // Catches only the *blatant* echo: a gateway that ignores the zero-`ts`
        // convention and sends our 0 straight back. Taking it would yield an
        // offset of roughly minus the current epoch.
        //
        // It does **not** catch the dangerous case — an echo of a real client
        // stamp, which lands near `localSendMs` and so produces a
        // plausible-looking `-roundTrip/2` rather than an obvious failure. That
        // one is prevented upstream, by ``ClockProbe/outgoing(_:)`` making a
        // stamped ping impossible to send. Guarding it here as well would mean
        // guessing at a threshold, and a guess is what this guard exists to
        // avoid.
        guard serverMs > 0 else { return }
        let roundTrip = localReceiveMs - localSendMs
        // Negative means the local clock stepped backwards mid-probe (or the
        // caller handed us swapped instants). Either way the midpoint is not a
        // time the gateway could have been at.
        guard roundTrip >= 0 else { return }

        // The gateway handled the ping somewhere in [send, receive]; the
        // midpoint is the least-wrong single answer, and the half-trip is how
        // wrong it can be.
        let midpointMs = localSendMs + roundTrip / 2
        let candidate = ClockOffset(
            milliseconds: serverMs - midpointMs,
            uncertaintyMs: roundTrip / 2,
            roundTripMs: roundTrip
        )

        // Keep the tightest window, not the newest: the true offset lies inside
        // every sample's interval, so the smallest interval pins it best. A
        // fresh sample only wins by being faster, never by being later.
        if let best, best.roundTripMs <= roundTrip { return }
        self.best = candidate
    }

    /// Drops the estimate. Called when the socket goes away: a reconnect lands
    /// on a different gateway process, and an offset measured against the old
    /// one is worse than no offset at all.
    public mutating func reset() {
        best = nil
    }
}
