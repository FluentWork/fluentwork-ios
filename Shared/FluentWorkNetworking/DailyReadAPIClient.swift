import Foundation
import Moya

/// Protocol for daily-reads API surface (I10, B11 wiring).
public protocol DailyReadAPIClientProtocol: Sendable {
  /// `GET /daily-reads/today`
  func getDailyReadToday(accessToken: String) async throws -> DailyReadTodayResponse
  /// `POST /daily-reads/:id/follow-read` — records a follow-read attempt (V1: no scoring).
  func postFollowRead(
    accessToken: String,
    dailyReadID: String,
    audioURL: String?
  ) async throws -> FollowReadResponse
}

public final class DailyReadAPIClient: DailyReadAPIClientProtocol, @unchecked Sendable {
  private let network: NetworkClientProtocol
  private let baseURL: URL

  public init(network: NetworkClientProtocol, baseURL: URL) {
    self.network = network
    self.baseURL = baseURL
  }

  public func getDailyReadToday(accessToken: String) async throws -> DailyReadTodayResponse {
    try await decode(
      DailyReadTodayResponse.self,
      .getDailyReadToday(accessToken: accessToken)
    )
  }

  public func postFollowRead(
    accessToken: String,
    dailyReadID: String,
    audioURL: String?
  ) async throws -> FollowReadResponse {
    try await decode(
      FollowReadResponse.self,
      .postDailyReadFollowRead(
        accessToken: accessToken,
        dailyReadID: dailyReadID,
        audioURL: audioURL
      )
    )
  }

  private func decode<T: Decodable>(_ type: T.Type, _ api: FluentWorkAPI) async throws -> T {
    let data = try await network.requestData(
      for: AbsoluteFluentWorkTarget(baseURL: baseURL, api: api)
    )
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw APIError.decoding(description: error.localizedDescription)
    }
  }
}
