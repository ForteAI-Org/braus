/// PrivacyDestination identifies a consumer of a classified value.
public enum PrivacyDestination: String, Sendable, CaseIterable {
    case model, episode, method, index, log, digest, humanStepDetails, turnReports, debugReplay
}

/// Arrival specifies the representation allowed at a destination.
public enum Arrival: Sendable, Equatable {
    case value, placeholder, parameterOnly, never
}
