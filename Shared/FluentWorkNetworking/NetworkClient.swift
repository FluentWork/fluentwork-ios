import Foundation
import Moya

public protocol FluentWorkTargetType: TargetType, Sendable {}

public protocol NetworkClientProtocol: Sendable {
    func requestData(for target: any FluentWorkTargetType) async throws -> Data
}

/// Normalized API / transport errors for FluentWork networking.
public enum APIError: Error, Equatable, Sendable, LocalizedError {
    case network(description: String)
    case decoding(description: String)
    case backend(code: String, message: String)
    case cancelled
    case unknown(description: String)

    /// User-facing copy placeholder (filled with C10 empty/error catalog).
    public var userFacingMessage: String? {
        nil
    }

    public var errorDescription: String? {
        switch self {
        case let .network(description), let .decoding(description), let .unknown(description):
            return description
        case let .backend(_, message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }
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
                        do {
                            continuation.resume(returning: try Self.validate(response))
                        } catch {
                            continuation.resume(throwing: error)
                        }

                    case let .failure(error):
                        continuation.resume(throwing: Self.mapMoyaError(error))
                    }
                }

                cancellationBox.set(cancellable)
            }
        } onCancel: {
            cancellationBox.cancel()
        }
    }

    private static func validate(_ response: Response) throws -> Data {
        guard (200..<300).contains(response.statusCode) else {
            throw mapHTTPError(response)
        }
        return response.data
    }

    public static func mapHTTPError(statusCode: Int, data: Data) -> APIError {
        if let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) {
            return .backend(code: body.code, message: body.message)
        }
        return .backend(
            code: "http_\(statusCode)",
            message: HTTPURLResponse.localizedString(forStatusCode: statusCode)
        )
    }

    private static func mapHTTPError(_ response: Response) -> APIError {
        mapHTTPError(statusCode: response.statusCode, data: response.data)
    }

    private static func mapMoyaError(_ error: MoyaError) -> APIError {
        switch error {
        case .underlying(let underlying, _):
            if underlying is CancellationError {
                return .cancelled
            }
            return .network(description: underlying.localizedDescription)

        case .objectMapping, .encodableMapping, .jsonMapping, .imageMapping, .stringMapping:
            return .decoding(description: error.localizedDescription)

        case .statusCode(let response):
            return mapHTTPError(response)

        default:
            return .unknown(description: error.localizedDescription)
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
