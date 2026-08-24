import TGReduxKit

public enum AuthMode: String, Equatable, Sendable {
    case anonymous
    case guest
    case registered
}

public struct AuthState: Equatable, Sendable {
    public var mode: AuthMode
    public var currentUserID: String?
    public var pendingMergeDeviceID: String?

    public init(
        mode: AuthMode = .anonymous,
        currentUserID: String? = nil,
        pendingMergeDeviceID: String? = nil
    ) {
        self.mode = mode
        self.currentUserID = currentUserID
        self.pendingMergeDeviceID = pendingMergeDeviceID
    }
}

public enum AuthAction: Equatable, Sendable {
    case signedInAsGuest(userID: String, deviceID: String)
    case mergedIntoRegistered(userID: String, deviceID: String?)
}

@MainActor
public let authReducer: Reducer<AuthState, AuthAction> = { state, action in
    switch action {
    case let .signedInAsGuest(userID, deviceID):
        state.mode = .guest
        state.currentUserID = userID
        state.pendingMergeDeviceID = deviceID

    case let .mergedIntoRegistered(userID, _):
        state.mode = .registered
        state.currentUserID = userID
        state.pendingMergeDeviceID = nil
    }
}
