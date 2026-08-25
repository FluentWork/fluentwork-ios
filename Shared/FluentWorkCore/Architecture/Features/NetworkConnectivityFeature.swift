import FluentWorkNetworking
import TGReduxKit

public struct NetworkConnectivityState: Equatable, Sendable, State {
    public var isConnected: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool

    public init(
        isConnected: Bool = true,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.isConnected = isConnected
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public init(snapshot: NetworkPathSnapshot) {
        self.isConnected = snapshot.isConnected
        self.isExpensive = snapshot.isExpensive
        self.isConstrained = snapshot.isConstrained
    }
}

public enum NetworkConnectivityAction: Equatable, Sendable, Action {
    case connectivityChanged(NetworkPathSnapshot)
}

public let networkConnectivityReducer: Reducer<NetworkConnectivityState, NetworkConnectivityAction> = { state, action in
    switch action {
    case let .connectivityChanged(snapshot):
        state.isConnected = snapshot.isConnected
        state.isExpensive = snapshot.isExpensive
        state.isConstrained = snapshot.isConstrained
    }
}
