import Testing
@testable import FluentWorkCore

@Suite("ScenePhaseSessionHandler")
struct ScenePhaseSessionHandlerTests {
    @Test func backgroundRecordingEmitsForceClose() {
        let event = ScenePhaseSessionHandler.event(
            scenePhase: .background,
            sessionPhase: .recording
        )
        #expect(event == .forceClose)
    }

    @Test func backgroundIdleEmitsNothing() {
        let event = ScenePhaseSessionHandler.event(
            scenePhase: .background,
            sessionPhase: .idle
        )
        #expect(event == nil)
    }

    @Test func activeFailedEmitsReconnectTimedOut() {
        let event = ScenePhaseSessionHandler.event(
            scenePhase: .active,
            sessionPhase: .failed
        )
        #expect(event == .reconnectTimedOut)
    }

    @Test func activeRecordingEmitsNothing() {
        let event = ScenePhaseSessionHandler.event(
            scenePhase: .active,
            sessionPhase: .recording
        )
        #expect(event == nil)
    }
}
