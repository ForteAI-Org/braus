import Foundation

/// NativeControlFacts keeps raw accessibility facts distinct from an interpreted ControlState.
/// AXToggle, AXSelected=false, empty text and advertised actions never imply an off state here.
/// Attribute reads are sequential and may observe a changing control. Provenance names their
/// harvest and capture target; retained or decoded facts do not establish current state.
public struct NativeControlFacts: Sendable, Equatable, Codable {

    public let role: NativeAttributeReading
    public let subrole: NativeAttributeReading
    public let value: NativeAttributeReading
    public let selected: NativeAttributeReading
    /// The native node's reported process, distinct from the requested capture owner.
    public let ownerProcessID: Int32?
    public var observation: NativeControlObservation?

    public init(
        role: NativeAttributeReading,
        subrole: NativeAttributeReading,
        value: NativeAttributeReading,
        selected: NativeAttributeReading,
        ownerProcessID: Int32? = nil,
        observation: NativeControlObservation? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.value = value
        self.selected = selected
        self.ownerProcessID = ownerProcessID
        self.observation = observation
    }

    /// SemanticIdentity changes with raw evidence or capture target, never with the read UUID alone.
    public struct SemanticIdentity: Sendable, Equatable, Hashable {
        let role: NativeAttributeReading
        let subrole: NativeAttributeReading
        let value: NativeAttributeReading
        let selected: NativeAttributeReading
        let ownerProcessID: Int32?
        let target: NativeControlObservation.Scope?
    }

    public var semanticIdentity: SemanticIdentity {
        SemanticIdentity(role: role, subrole: subrole, value: value, selected: selected,
                         ownerProcessID: ownerProcessID, target: observation?.scope)
    }

    /// The token carries full raw evidence; display limits cannot conceal a semantic change.
    public var semanticKey: String {
        var parts = [role.semanticKey, subrole.semanticKey, value.semanticKey, selected.semanticKey,
                     ownerProcessID.map(String.init) ?? "unknown-owner"]
        if let target = observation?.scope {
            parts += [String(target.processID), target.windowNumber.map(String.init) ?? "unattested"]
            parts += target.frameBits.map { String($0, radix: 16) }
        } else {
            parts.append("unknown-target")
        }
        return parts.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Identifies the observation expected by a consumer without promoting any raw fact to state.
    public func belongs(to expected: NativeControlObservation) -> Bool {
        observation == expected && expected.windowNumber != nil && ownerProcessID == expected.processID
    }

    /// Renders raw evidence explicitly, including whether the capture recipient was attested.
    public var diagnosticText: String {
        let source: String
        if let observation {
            let window = observation.windowNumber.map(String.init) ?? "unattested"
            source = " pid=\(observation.processID) window=\(window) observation=\(observation.observationID.uuidString)"
        } else {
            source = " observation=unavailable"
        }
        let owner = ownerProcessID.map(String.init) ?? "unavailable"
        return " [native-raw owner=\(owner) role=\(role.diagnosticText) subrole=\(subrole.diagnosticText)"
            + " value=\(value.diagnosticText) selected=\(selected.diagnosticText)\(source)]"
    }
}
