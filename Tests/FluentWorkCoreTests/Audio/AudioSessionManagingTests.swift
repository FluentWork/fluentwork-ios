import Testing
@testable import FluentWorkCore

#if os(macOS)
@Test func defaultAudioSessionManagerTracksLifecycleOnPlatformsWithoutAVAudioSession() async throws {
    let manager = DefaultAudioSessionManager()

    #expect(await manager.isActive == false)

    try manager.configure(for: .fullDuplex)
    #expect(await manager.isActive == true)

    try manager.pause()
    #expect(await manager.isActive == false)

    try manager.resume()
    #expect(await manager.isActive == true)
}
#endif
