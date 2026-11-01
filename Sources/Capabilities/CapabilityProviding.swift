import LocalMCP

/// CapabilityProviding supplies one immutable family and executes its calls.
/// Providers are retained by the facade, outside the registry. They hop to an actor inside `call` if needed.
/// The dispatcher owns recording, including failure; providers must not record the same call again.
public protocol CapabilityProviding: Sendable {
    var family: String { get }
    var contracts: [CapabilityContract] { get }
    func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue
}
