import Capabilities

/// RegisteredProviders is the composition seam a build replaces to supply its capability families.
/// The open build registers none; construction is independent of actor isolation.
public nonisolated enum RegisteredProviders {
    public static func make() -> [any CapabilityProviding] { [] }
}
