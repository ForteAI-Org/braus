import LocalMCP

/// CapabilityRecording observes a registered call once before execution and once after success or failure.
/// A failed `began` prevents execution. A failed `ended` never replays the provider or the observer.
/// A nil verification means no independent verification result is available.
public protocol CapabilityRecording: Sendable {
    func began(_ id: CapabilityID, arguments: JSONValue) async throws
    func ended(_ id: CapabilityID, result: JSONValue?, failure: String?, verified: Bool?) async throws
}
