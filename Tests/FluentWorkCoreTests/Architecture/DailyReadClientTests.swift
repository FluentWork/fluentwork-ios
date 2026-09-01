import FluentWorkNetworking
import Foundation
import Testing

@testable import FluentWorkCore

@MainActor
@Test func defaultDailyReadClientLoadTodayReturnsAPIResponse() async throws {
  let expected = DailyReadTodayResponse(
    genDate: "2026-09-01",
    status: .ready,
    dailyRead: makeDailyRead()
  )

  let api = StubDailyReadAPIClient(
    loadHandler: { accessToken in
      #expect(accessToken == "guest-token")
      return expected
    },
    followReadHandler: { _, _ in
      throw APIError.backend(code: "unused", message: "unused")
    }
  )
  let session = StubSessionAPIClient(
    guestTokenHandler: { _ in
      TokenResponse(
        userID: "guest-1",
        isGuest: true,
        status: "active",
        accessToken: "guest-token",
        refreshToken: "refresh",
        expiresIn: 3600
      )
    }
  )
  let tokens = InMemoryAuthTokenStore(
    seedAccessToken: "guest-token",
    seedDeviceID: "device-1"
  )

  let client = DefaultDailyReadClient(api: api, sessionAPI: session, tokens: tokens)

  let response = try await client.loadToday()
  #expect(response == expected)
  #expect(response.dailyRead?.id == "dr-001")
}

@MainActor
@Test func defaultDailyReadClientIssuesGuestWhenNoToken() async throws {
  let expected = DailyReadTodayResponse(
    genDate: "2026-09-01",
    status: .pending
  )
  let api = StubDailyReadAPIClient(
    loadHandler: { accessToken in
      #expect(accessToken == "issued-token")
      return expected
    },
    followReadHandler: { _, _ in
      throw APIError.backend(code: "unused", message: "unused")
    }
  )
  let session = StubSessionAPIClient(
    guestTokenHandler: { _ in
      TokenResponse(
        userID: "guest-2",
        isGuest: true,
        status: "active",
        accessToken: "issued-token",
        refreshToken: "refresh",
        expiresIn: 3600
      )
    }
  )
  let tokens = InMemoryAuthTokenStore(seedAccessToken: nil, seedDeviceID: "device-2")

  let client = DefaultDailyReadClient(api: api, sessionAPI: session, tokens: tokens)
  _ = try await client.loadToday()

  let saved = try tokens.accessToken()
  #expect(saved == "issued-token")
}

@MainActor
@Test func defaultDailyReadClientSubmitFollowReadUsesExistingToken() async throws {
  let api = StubDailyReadAPIClient(
    loadHandler: { _ in
      throw APIError.backend(code: "unused", message: "unused")
    },
    followReadHandler: { accessToken, dailyReadID in
      #expect(accessToken == "registered-token")
      #expect(dailyReadID == "dr-001")
      return FollowReadResponse(
        dailyReadID: dailyReadID,
        recorded: true,
        readScore: nil,
        generator: "volc-ark"
      )
    }
  )
  let session = StubSessionAPIClient(
    guestTokenHandler: { _ in
      throw IssueMismatch()
    }
  )
  let tokens = InMemoryAuthTokenStore(
    seedAccessToken: "registered-token",
    seedDeviceID: "device-3"
  )

  let client = DefaultDailyReadClient(api: api, sessionAPI: session, tokens: tokens)
  let response = try await client.submitFollowRead(dailyReadID: "dr-001", audioURL: nil as String?)
  #expect(response.recorded == true)
  #expect(response.readScore == nil)
}

// MARK: - Stubs

private final class StubDailyReadAPIClient: DailyReadAPIClientProtocol, @unchecked Sendable {
  private let loadHandler: @Sendable (String) async throws -> DailyReadTodayResponse
  private let followReadHandler: @Sendable (String, String) async throws -> FollowReadResponse

  init(
    loadHandler: @escaping @Sendable (String) async throws -> DailyReadTodayResponse,
    followReadHandler: @escaping @Sendable (String, String) async throws -> FollowReadResponse
  ) {
    self.loadHandler = loadHandler
    self.followReadHandler = followReadHandler
  }

  func getDailyReadToday(accessToken: String) async throws -> DailyReadTodayResponse {
    try await loadHandler(accessToken)
  }

  func postFollowRead(
    accessToken: String,
    dailyReadID: String,
    audioURL: String?
  ) async throws -> FollowReadResponse {
    try await followReadHandler(accessToken, dailyReadID)
  }
}

private final class StubSessionAPIClient: SessionAPIClientProtocol, @unchecked Sendable {
  private let guestTokenHandler: @Sendable (String) async throws -> TokenResponse

  init(guestTokenHandler: @escaping @Sendable (String) async throws -> TokenResponse) {
    self.guestTokenHandler = guestTokenHandler
  }

  func issueGuest(deviceID: String) async throws -> TokenResponse {
    try await guestTokenHandler(deviceID)
  }

  func mergeGuestAccount(deviceID: String, accessToken: String) async throws -> MergeResponse {
    throw IssueMismatch()
  }

  func createSession(
    accessToken: String,
    materialID: String?,
    sceneType: String?
  ) async throws -> CreateSessionResponse {
    throw IssueMismatch()
  }

  func getSessionReview(sessionID: String, accessToken: String) async throws -> ReviewPollResponse {
    throw IssueMismatch()
  }

  func sendSessionMessage(
    sessionID: String,
    accessToken: String,
    text: String,
    channel: String
  ) async throws -> PostMessageResponse {
    throw IssueMismatch()
  }
}

private final class InMemoryAuthTokenStore: AuthTokenStoreProtocol, @unchecked Sendable {
  private let lock = NSLock()
  private var accessTokenValue: String?
  private var deviceIDValue: String
  private var userIDValue: String?
  private var isGuestValue: Bool = true

  init(seedAccessToken: String?, seedDeviceID: String) {
    self.accessTokenValue = seedAccessToken
    self.deviceIDValue = seedDeviceID
  }

  func deviceID() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    return deviceIDValue
  }

  func accessToken() throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return accessTokenValue
  }

  func save(tokens: TokenResponse, deviceID: String) throws {
    lock.lock()
    defer { lock.unlock() }
    accessTokenValue = tokens.accessToken
    deviceIDValue = deviceID
    userIDValue = tokens.userID
    isGuestValue = tokens.isGuest
  }

  func clear() throws {
    lock.lock()
    defer { lock.unlock() }
    accessTokenValue = nil
    userIDValue = nil
    isGuestValue = true
  }

  func userID() throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return userIDValue
  }

  func isGuest() throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isGuestValue
  }
}

private struct IssueMismatch: Error {}

private func makeDailyRead() -> DailyRead {
  DailyRead(
    id: "dr-001",
    title: "Daily Read Sample",
    body: "Today's short passage for practice.",
    audioURL: "https://example.com/audio.mp3",
    generator: "volc-ark",
    usedBlockIDs: ["b-1", "b-2"],
    sourceRefs: [:],
    readScore: nil
  )
}
