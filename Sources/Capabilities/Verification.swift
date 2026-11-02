/// Verification is the single check promised by a capability.
public enum Verification: Sendable, Equatable {
    case engineVerdict
    case readBack(description: String)
    case resultCheck
    case none(reason: String)
}
