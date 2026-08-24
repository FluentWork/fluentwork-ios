import Foundation
import Moya

public protocol FluentWorkTargetType: TargetType, Sendable {}

public protocol NetworkClientProtocol: Sendable {
    func requestData(for target: any FluentWorkTargetType) async throws -> Data
}

public enum NetworkClientError: Error, Equatable, Sendable {
    case requestFailed(String)
}

private final class RequestCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellable: Cancellable?

    func set(_ cancellable: Cancellable) {
        lock.lock()
        self.cancellable = cancellable
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let cancellable = self.cancellable
        lock.unlock()
        cancellable?.cancel()
    }
}

public final class MoyaNetworkClient: @unchecked Sendable, NetworkClientProtocol {
    private let provider: MoyaProvider<MultiTarget>

    public init(provider: MoyaProvider<MultiTarget> = MoyaProvider<MultiTarget>()) {
        self.provider = provider
    }

    public func requestData(for target: any FluentWorkTargetType) async throws -> Data {
        let cancellationBox = RequestCancellationBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancellable = provider.request(MultiTarget(target)) { result in
                    switch result {
                    case let .success(response):
                        continuation.resume(returning: response.data)

                    case let .failure(error):
                        continuation.resume(
                            throwing: NetworkClientError.requestFailed(error.localizedDescription)
                        )
                    }
                }

                cancellationBox.set(cancellable)
            }
        } onCancel: {
            cancellationBox.cancel()
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
