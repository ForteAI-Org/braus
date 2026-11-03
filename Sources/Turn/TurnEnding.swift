import Foundation

/// TurnEnding is the shared terminal vocabulary for application and command line hosts.
nonisolated public enum TurnEnding: Sendable, Equatable {
    case completed
    case failed(reason: String)
    case cancelled
    case handedToPerson

    public init(thrown: (any Error)?, handedOver: Bool, isHandedOver: Bool, reportedFailure: String?) {
        switch thrown {
        case .none where handedOver: self = .handedToPerson
        case is CancellationError: self = isHandedOver ? .handedToPerson : .cancelled
        case .some(let error): self = .failed(reason: reportedFailure ?? error.localizedDescription)
        case .none: self = reportedFailure.map { .failed(reason: $0) } ?? .completed
        }
    }
}
