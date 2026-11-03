import Foundation

/// BatchConfigurationError rejects incompatible batch switches before batch admission.
nonisolated public enum BatchConfigurationError: LocalizedError, Sendable, Equatable {
    case taskCycleV2Required

    public var errorDescription: String? {
        switch self {
        case .taskCycleV2Required: "batch=v2 requires task_cycle=v2."
        }
    }
}
