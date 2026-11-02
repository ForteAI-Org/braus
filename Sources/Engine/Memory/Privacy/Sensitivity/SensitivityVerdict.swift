/// SensitivityVerdict carries the deterministic score and the signals that contributed to it.
public struct SensitivityVerdict: Sendable, Equatable {
    public let sensitivity: SensitivityClass
    public let score: Int
    public let reasons: [SensitivityReason]
}

/// SensitivityReason identifies a contribution without exposing the classified value.
public enum SensitivityReason: String, Sendable, Codable {
    case secureRole, secureMarkup, unreadableSubrole, declared, strongShape, checksum
    case decisiveLabel, weakLabel, randomShape, contentSurface, appPolicy
}
