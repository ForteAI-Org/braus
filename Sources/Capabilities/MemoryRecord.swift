/// MemoryRecord identifies the single recording path for a capability.
public enum MemoryRecord: Sendable, Equatable {
    case agentCall(tool: String)
    case capabilityStep
    case notRecorded(reason: String)
}
