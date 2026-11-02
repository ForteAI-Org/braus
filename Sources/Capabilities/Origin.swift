/// Origin identifies the core, open adapter or registered family providing a capability.
public enum Origin: Sendable, Equatable, Codable {
    case core
    case adapter(String)
    case registered(provider: String)
}
