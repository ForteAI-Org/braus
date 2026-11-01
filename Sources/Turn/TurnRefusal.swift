import Foundation

/// TurnRefusal rejects an operation before it changes runner state.
nonisolated public enum TurnRefusal: LocalizedError, Sendable, Equatable {
    case personHasControl
    case turnRunning
    case previousEpisodeReleasing
    case previousTurnStopping
    case staleEpisode
    case suspensionUnavailable

    public var errorDescription: String? {
        switch self {
        case .personHasControl: "The person is controlling this session. Wait for the intervention review."
        case .turnRunning: "This worker is still responding. Wait for it to finish or stop the response."
        case .previousEpisodeReleasing: "The previous human intervention is still releasing its session."
        case .previousTurnStopping: "The previous turn is stopping. Wait for its session cleanup."
        case .staleEpisode: "This human intervention is stale or its previous turn is still draining."
        case .suspensionUnavailable: "Human suspension is unavailable in this host."
        }
    }
}
