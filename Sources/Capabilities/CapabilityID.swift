/// CapabilityID is the name a caller uses for one core, adapter or registered capability.
public struct CapabilityID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
}
