import FluentWorkNetworking
import Foundation

/// High-level wrapper around `DailyReadAPIClient` that handles access-token resolution
/// and translates transport failures into caller-friendly errors.
public protocol DailyReadClientProtocol: Sendable {
  func loadToday() async throws -> DailyReadTodayResponse
  func submitFollowRead(dailyReadID: String, audioURL: String?) async throws -> FollowReadResponse
}

public final class DefaultDailyReadClient: DailyReadClientProtocol, @unchecked Sendable {
  private let api: DailyReadAPIClientProtocol
  private let sessionAPI: SessionAPIClientProtocol
  private let tokens: AuthTokenStoreProtocol

  public init(
    api: DailyReadAPIClientProtocol,
    sessionAPI: SessionAPIClientProtocol,
    tokens: AuthTokenStoreProtocol
  ) {
    self.api = api
    self.sessionAPI = sessionAPI
    self.tokens = tokens
  }

  public func loadToday() async throws -> DailyReadTodayResponse {
    let accessToken = try await requireAccessToken()
    return try await api.getDailyReadToday(accessToken: accessToken)
  }

  public func submitFollowRead(dailyReadID: String, audioURL: String?) async throws
    -> FollowReadResponse
  {
    let accessToken = try await requireAccessToken()
    return try await api.postFollowRead(
      accessToken: accessToken,
      dailyReadID: dailyReadID,
      audioURL: audioURL
    )
  }

  private func ensureAccessToken(deviceID: String) async throws -> String {
    if let existing = try tokens.accessToken(), !existing.isEmpty {
      return existing
    }
    let issued = try await sessionAPI.issueGuest(deviceID: deviceID)
    try tokens.save(tokens: issued, deviceID: deviceID)
    return issued.accessToken
  }

  private func requireAccessToken() async throws -> String {
    let deviceID = try tokens.deviceID()
    return try await ensureAccessToken(deviceID: deviceID)
  }
}
