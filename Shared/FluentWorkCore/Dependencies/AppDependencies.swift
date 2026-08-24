import FactoryKit
import FluentWorkNetworking
import FluentWorkPluginSupport
import Foundation

public protocol BootstrapClientProtocol: Sendable {
    func loadBootstrap() async throws -> BootstrapSnapshot
}

public protocol SocketTransportProtocol: Sendable {
    func connect(sessionID: String, ticket: String) async throws
    func disconnect() async
}

public protocol AudioEngineProtocol: Sendable {
    func startCapture() async throws
    func stopCapture() async
    func interruptNow() async
}

public protocol SpeechSessionClientProtocol: Sendable {
    func startSession() async throws
    func submitTranscript(_ text: String) async
}

public protocol NetworkPluginFactoryProtocol: Sendable {
    func makeNetworkClient() -> NetworkClientProtocol
}

public struct StaticBootstrapClient: BootstrapClientProtocol {
    public let snapshot: BootstrapSnapshot

    public init(snapshot: BootstrapSnapshot = .preview) {
        self.snapshot = snapshot
    }

    public func loadBootstrap() async throws -> BootstrapSnapshot {
        snapshot
    }
}

public struct DefaultNetworkPluginFactory: NetworkPluginFactoryProtocol {
    public init() {}

    public func makeNetworkClient() -> NetworkClientProtocol {
        MoyaNetworkClient()
    }
}

public final class PlaceholderSocketTransport: SocketTransportProtocol, Sendable {
    public init() {}

    public func connect(sessionID: String, ticket: String) async throws {}

    public func disconnect() async {}
}

public final class PlaceholderAudioEngine: AudioEngineProtocol, Sendable {
    public init() {}

    public func startCapture() async throws {}

    public func stopCapture() async {}

    public func interruptNow() async {}
}

public final class PlaceholderSpeechSessionClient: SpeechSessionClientProtocol, Sendable {
    public init() {}

    public func startSession() async throws {}

    public func submitTranscript(_ text: String) async {}
}

public extension Container {
    var bootstrapClient: Factory<BootstrapClientProtocol> {
        self { StaticBootstrapClient() }.singleton
    }

    var socketTransport: Factory<SocketTransportProtocol> {
        self { PlaceholderSocketTransport() }.singleton
    }

    var networkPluginFactory: Factory<NetworkPluginFactoryProtocol> {
        self { DefaultNetworkPluginFactory() }.singleton
    }

    var networkClient: Factory<NetworkClientProtocol> {
        self { self.networkPluginFactory().makeNetworkClient() }.singleton
    }

    var audioEngine: Factory<AudioEngineProtocol> {
        self { PlaceholderAudioEngine() }.shared
    }

    var speechSessionClient: Factory<SpeechSessionClientProtocol> {
        self { PlaceholderSpeechSessionClient() }.shared
    }

    var featurePluginRegistry: Factory<FeaturePluginRegistryProtocol> {
        self { StaticFeaturePluginRegistry() }.singleton
    }
}
