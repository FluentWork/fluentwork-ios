import Foundation
import Testing
@testable import FluentWorkNetworking

// MARK: - ClockProbe

/// The one rule that makes a clock estimate possible: the gateway discloses its
/// own clock only for a zero `ts`, and echoes anything else.
@Test func clockProbeBlanksTheTimestampSoTheGatewayRevealsItsOwnClock() {
    #expect(ClockProbe.outgoing(.ping(ts: 1_728_000_000_000)) == .ping(ts: 0))
    #expect(ClockProbe.outgoing(.ping(ts: nil)) == .ping(ts: 0))
}

@Test func clockProbeLeavesEveryOtherFrameAlone() {
    let frames: [WSControlFrame] = [
        .userSpeechStart,
        .userSpeechEnd(text: "hi", turnID: "turn-1"),
        .aiTurnEnd(turnID: "turn-1", outcome: .ok, logID: nil),
        .aiTextDelta(text: "hello", turnID: "turn-1", serverTsMs: 42),
        .interrupt,
        .pong(ts: 42),
        .sessionEnd(reason: nil),
    ]
    for frame in frames {
        #expect(ClockProbe.outgoing(frame) == frame)
    }
}

// MARK: - ClockOffset

/// Every consumer of `server_ts_ms` is one sign error away from a number that
/// looks fine. This is the guard.
@Test func clockOffsetPutsAGatewayStampOnTheLocalClock() {
    // Gateway running 5 s fast: at our local T it stamps T + 5_000.
    let offset = ClockOffset(milliseconds: 5_000, uncertaintyMs: 50, roundTripMs: 100)

    #expect(offset.serverToLocalMs(1_005_000) == 1_000_000)

    // It stamped at our local 1_000_000; we read the frame at local 1_000_050.
    #expect(offset.oneWayLatencyMs(serverMs: 1_005_000, localReceiveMs: 1_000_050) == 50)
}

/// Why the type exists at all: the raw difference is dominated by the skew.
@Test func clockOffsetShowsWhyTheRawDifferenceIsNotALatency() {
    // Gateway 5 s fast. Frame stamped when our clock read 1_000_000, read by us
    // 50 ms later. The naive `localNow - server_ts_ms` reports **-4_950 ms** of
    // "latency" — the clock skew, wearing a latency's clothes.
    let serverMs: Int64 = 1_005_000
    let localReceiveMs: Int64 = 1_000_050
    #expect(localReceiveMs - serverMs == -4_950)

    let offset = ClockOffset(milliseconds: 5_000, uncertaintyMs: 50, roundTripMs: 100)
    #expect(offset.oneWayLatencyMs(serverMs: serverMs, localReceiveMs: localReceiveMs) == 50)
}

// MARK: - ClockOffsetEstimator

@Test func clockOffsetEstimatorRecoversAKnownSkew() {
    var estimator = ClockOffsetEstimator()
    // Phone at 1_000_000, gateway 5 s ahead, 100 ms round trip: the gateway
    // handles the ping at the midpoint, where its clock reads 1_005_050.
    estimator.record(localSendMs: 1_000_000, localReceiveMs: 1_000_100, serverMs: 1_005_050)

    #expect(estimator.best?.milliseconds == 5_000)
    #expect(estimator.best?.uncertaintyMs == 50)
    #expect(estimator.best?.roundTripMs == 100)
}

/// The estimate keeps a **window**, not a value: the gateway handled the ping
/// somewhere inside the round trip, and half of it is how wrong we can be.
@Test func clockOffsetEstimatorCarriesHalfTheRoundTripAsItsErrorBar() {
    var estimator = ClockOffsetEstimator()
    estimator.record(localSendMs: 1_000_000, localReceiveMs: 1_000_800, serverMs: 1_000_400)

    #expect(estimator.best?.uncertaintyMs == 400)
    #expect(estimator.best?.roundTripMs == 800)
}

/// Lowest round trip wins, not the newest — the true offset lies inside every
/// sample's interval, so the narrowest interval pins it best. A slower sample
/// would widen the error bar for nothing.
@Test func clockOffsetEstimatorKeepsTheTightestRoundTripNotTheNewest() {
    var estimator = ClockOffsetEstimator()
    estimator.record(localSendMs: 1_000_000, localReceiveMs: 1_000_040, serverMs: 1_000_020)
    let tight = estimator.best
    #expect(tight?.roundTripMs == 40)

    estimator.record(localSendMs: 2_000_000, localReceiveMs: 2_000_400, serverMs: 2_000_200)

    #expect(estimator.best == tight)
    #expect(estimator.best?.uncertaintyMs == 20)
}

@Test func clockOffsetEstimatorAdoptsAFasterRoundTrip() {
    var estimator = ClockOffsetEstimator()
    estimator.record(localSendMs: 1_000_000, localReceiveMs: 1_000_400, serverMs: 1_000_200)
    #expect(estimator.best?.roundTripMs == 400)

    estimator.record(localSendMs: 2_000_000, localReceiveMs: 2_000_040, serverMs: 2_000_020)

    #expect(estimator.best?.roundTripMs == 40)
    #expect(estimator.best?.milliseconds == 0)
}

/// The blatant echo: a gateway that ignores the zero-`ts` convention sends our 0
/// straight back. Folding it in would put the offset at roughly minus the epoch.
///
/// NOTE: this guard does **not** cover an echo of a real client stamp — that one
/// lands near `localSendMs` and reads as a plausible `-roundTrip/2`. Preventing
/// it is `ClockProbe.outgoing`'s job, and
/// `clockProbeBlanksTheTimestampSoTheGatewayRevealsItsOwnClock` is its guard.
@Test func clockOffsetEstimatorRejectsAnEchoedZeroTimestamp() {
    var estimator = ClockOffsetEstimator()
    estimator.record(
        localSendMs: 1_728_000_000_000,
        localReceiveMs: 1_728_000_000_100,
        serverMs: 0
    )

    #expect(estimator.best == nil)
}

@Test func clockOffsetEstimatorRejectsATimeThatWentBackwards() {
    var estimator = ClockOffsetEstimator()
    // The local clock stepped mid-probe, or the caller swapped the instants.
    // Either way the midpoint is not a time the gateway could have been at.
    estimator.record(localSendMs: 1_000_100, localReceiveMs: 1_000_000, serverMs: 1_000_050)

    #expect(estimator.best == nil)
}

/// A reconnect lands on a different gateway process. Keeping the old offset
/// would keep stamping latencies with a stale skew and never look wrong.
@Test func clockOffsetEstimatorResetForgetsTheEstimate() {
    var estimator = ClockOffsetEstimator()
    estimator.record(localSendMs: 1_000_000, localReceiveMs: 1_000_100, serverMs: 1_005_050)
    #expect(estimator.best != nil)

    estimator.reset()

    #expect(estimator.best == nil)
}
