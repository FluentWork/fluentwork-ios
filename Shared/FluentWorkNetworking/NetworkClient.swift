import Foundation
import Moya

public protocol FluentWorkTargetType: TargetType, Sendable {}

public protocol NetworkClientProtocol: Sendable {
    func requestData(for target: any FluentWorkTargetType) async throws -> Data
}

public enum NetworkClientError: Error, Equatable, Sendable {
    case requestFailed(String)
}

public final class MoyaNetworkClient: @unchecked Sendable, NetworkClientProtocol {
    private let provider: MoyaProvider<MultiTarget>

    public init(provider: MoyaProvider<MultiTarget> = MoyaProvider<MultiTarget>()) {
        self.provider = provider
    }

    public func requestData(for target: any FluentWorkTargetType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.request(MultiTarget(target)) { result in
                switch result {
                case let .success(response):
                    continuation.resume(returning: response.data)

                case let .failure(error):
                    continuation.resume(
                        throwing: NetworkClientError.requestFailed(error.localizedDescription)
                    )
                }
            }
        }
    }
}

public struct StubNetworkClient: NetworkClientProtocol {
    public let handler: @Sendable (any FluentWorkTargetType) async throws -> Data

    public init(
        handler: @escaping @Sendable (any FluentWorkTargetType) async throws -> Data
    ) {
        self.handler = handler
    }

    public func requestData(for target: any FluentWorkTargetType) async throws -> Data {
        try await handler(target)
    }
}
