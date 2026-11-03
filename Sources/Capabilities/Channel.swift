/// Channel identifies where a capability acts, independently of its provider.
public enum Channel: String, Sendable, Codable {
    case seat, native, web, adapter, connector, command, braus
}
