/// SensitivityClass is the privacy class of a value.
public enum SensitivityClass: String, Sendable, CaseIterable {
    case secret = "S"
    case personal = "P"
    case ordinary = "O"
}
