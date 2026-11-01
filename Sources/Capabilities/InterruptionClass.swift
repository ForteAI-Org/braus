/// InterruptionClass decides whether a call is cancelled, protected while opening, or left to finish.
public enum InterruptionClass: String, Sendable, Codable {
    case readOnly, openingScene, mutating
}
