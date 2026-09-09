import Foundation
import Testing
@testable import FluentWorkCore

@Suite("AudioInterruptionObserver")
struct AudioInterruptionObserverTests {
    @Test func beganNotificationEmitsBegan() async {
        let center = NotificationCenter()
        let observer = AudioInterruptionObserver(center: center)
        let collector = InterruptionEventCollector()

        observer.start { kind in
            await collector.append(kind)
        }

        center.post(
            name: AudioInterruptionObserver.interruptionNotification,
            object: nil,
            userInfo: [
                AudioInterruptionObserver.interruptionTypeKey: AudioInterruptionObserver.interruptionBeganRaw
            ]
        )

        let events = await collector.wait(forCount: 1)
        #expect(events == [.began])
        observer.stop()
    }

    @Test func endedNotificationWithShouldResumeEmitsEndedTrue() async {
        let center = NotificationCenter()
        let observer = AudioInterruptionObserver(center: center)
        let collector = InterruptionEventCollector()

        observer.start { kind in
            await collector.append(kind)
        }

        center.post(
            name: AudioInterruptionObserver.interruptionNotification,
            object: nil,
            userInfo: [
                AudioInterruptionObserver.interruptionTypeKey: AudioInterruptionObserver.interruptionEndedRaw,
                AudioInterruptionObserver.interruptionOptionKey: AudioInterruptionObserver.shouldResumeOptionRaw
            ]
        )

        let events = await collector.wait(forCount: 1)
        #expect(events == [.ended(shouldResume: true)])
        observer.stop()
    }

    @Test func oldDeviceUnavailableRouteEmitsRouteChanged() async {
        let center = NotificationCenter()
        let observer = AudioInterruptionObserver(center: center)
        let collector = InterruptionEventCollector()

        observer.start { kind in
            await collector.append(kind)
        }

        center.post(
            name: AudioInterruptionObserver.routeChangeNotification,
            object: nil,
            userInfo: [
                AudioInterruptionObserver.routeChangeReasonKey: AudioInterruptionObserver.routeOldDeviceUnavailableRaw
            ]
        )

        let events = await collector.wait(forCount: 1)
        #expect(events == [.routeChanged(reason: "oldDeviceUnavailable")])
        observer.stop()
    }

    @Test func categoryChangeRouteEmitsNothing() async {
        let center = NotificationCenter()
        let observer = AudioInterruptionObserver(center: center)
        let collector = InterruptionEventCollector()

        observer.start { kind in
            await collector.append(kind)
        }

        center.post(
            name: AudioInterruptionObserver.routeChangeNotification,
            object: nil,
            userInfo: [
                AudioInterruptionObserver.routeChangeReasonKey: AudioInterruptionObserver.routeCategoryChangeRaw
            ]
        )

        let events = await collector.wait(forCount: 1, timeout: .milliseconds(150))
        #expect(events.isEmpty)
        observer.stop()
    }

    @Test func stopThenPostDoesNotEmitAdditionalEvents() async {
        let center = NotificationCenter()
        let observer = AudioInterruptionObserver(center: center)
        let collector = InterruptionEventCollector()

        observer.start { kind in
            await collector.append(kind)
        }

        center.post(
            name: AudioInterruptionObserver.interruptionNotification,
            object: nil,
            userInfo: [
                AudioInterruptionObserver.interruptionTypeKey: AudioInterruptionObserver.interruptionBeganRaw
            ]
        )

        let first = await collector.wait(forCount: 1)
        #expect(first == [.began])

        observer.stop()

        center.post(
            name: AudioInterruptionObserver.interruptionNotification,
            object: nil,
            userInfo: [
                AudioInterruptionObserver.interruptionTypeKey: AudioInterruptionObserver.interruptionEndedRaw,
                AudioInterruptionObserver.interruptionOptionKey: AudioInterruptionObserver.shouldResumeOptionRaw
            ]
        )
        center.post(
            name: AudioInterruptionObserver.routeChangeNotification,
            object: nil,
            userInfo: [
                AudioInterruptionObserver.routeChangeReasonKey: AudioInterruptionObserver.routeOldDeviceUnavailableRaw
            ]
        )

        let afterStop = await collector.wait(forCount: 2, timeout: .milliseconds(150))
        #expect(afterStop.count == 1)
        #expect(afterStop == [.began])
    }
}

actor InterruptionEventCollector {
    private(set) var events: [AudioInterruptionKind] = []

    func append(_ event: AudioInterruptionKind) {
        events.append(event)
    }

    func wait(forCount count: Int, timeout: Duration = .seconds(1)) async -> [AudioInterruptionKind] {
        let deadline = ContinuousClock.now + timeout
        while events.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return events
    }
}
