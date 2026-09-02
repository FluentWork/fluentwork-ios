import FluentWorkNetworking
import Foundation
import os
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

  let saved = try await tokens.accessToken()
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
  
  func refreshToken(_ accessToken: String) async throws -> AuthToken {
    throw IssueMismatch()
  }
}

/// Test stub: in-memory implementation of `AuthTokenStoreProtocol`.
///
/// Uses Apple `OSAllocatedUnfairLock` (iOS 16+) instead of `NSLock`. All
/// five stored fields live in a single `State` struct, so writes are
/// atomic across the board — no more `lock` / `defer { unlock }`
/// boilerplate, no more risk of forgetting to hold the lock on every
/// read or every write.
private final class InMemoryAuthTokenStore: AuthTokenStoreProtocol, @unchecked Sendable {
  private struct State {
    var accessToken: String?
    var deviceID: String
    var userID: String?
    var isGuest: Bool = true
  }

  private let storage: OSAllocatedUnfairLock<State>

  init(seedAccessToken: String?, seedDeviceID: String) {
    self.storage = OSAllocatedUnfairLock(
      uncheckedState: State(accessToken: seedAccessToken, deviceID: seedDeviceID)
    )
  }

  func deviceID() async throws -> String {
    storage.withLock { $0.deviceID }
  }

  func accessToken() async throws -> String? {
    storage.withLock { $0.accessToken }
  }

  func save(tokens: TokenResponse, deviceID: String) async throws {
    storage.withLock { state in
      state.accessToken = tokens.accessToken
      state.deviceID = deviceID
      state.userID = tokens.userID
      state.isGuest = tokens.isGuest
    }
  }

  func clear() async throws {
    storage.withLock { state in
      state.accessToken = nil
      state.userID = nil
      state.isGuest = true
    }
  }

  func userID() async throws -> String? {
    storage.withLock { $0.userID }
  }

  func isGuest() async throws -> Bool {
    storage.withLock { $0.isGuest }
  }

  func loadAccessToken() async throws -> AuthToken? {
    storage.withLock { state in
      guard let token = state.accessToken else { return nil }
      return AuthToken(
        value: token,
        expiresAt: Date().addingTimeInterval(3600) // 1 hour from now
      )
    }
  }

  func saveAccessToken(_ token: AuthToken) async throws {
    storage.withLock { $0.accessToken = token.value }
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
