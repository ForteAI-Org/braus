/// CallRecoveryError describes a rejected person acknowledgement without changing the call's history.
public enum CallRecoveryError: Error, Sendable, Equatable {
    case differentProducer
    case notUnresolved
    case stillRunning
}
