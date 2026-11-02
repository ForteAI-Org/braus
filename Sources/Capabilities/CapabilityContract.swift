import LocalMCP

/// CapabilityContract describes one served capability, its effect, check and recording path.
/// Interruption is mandatory. Parallel execution requires an explicit promise that no shared state is touched.
public struct CapabilityContract: Sendable, Equatable {
    public let id: CapabilityID
    public let group: String
    public let description: String
    public let inputSchema: JSONValue
    public let effect: EffectClass
    public let interruption: InterruptionClass
    public let verification: Verification
    public let channel: Channel
    public let origin: Origin
    public let memory: MemoryRecord
    public let takesSession: Bool
    public let parallelSafe: Bool

    public init(
        id: CapabilityID,
        group: String,
        description: String,
        inputSchema: JSONValue,
        effect: EffectClass,
        interruption: InterruptionClass,
        verification: Verification,
        channel: Channel,
        origin: Origin,
        memory: MemoryRecord,
        takesSession: Bool,
        parallelSafe: Bool = false
    ) {
        self.id = id
        self.group = group
        self.description = description
        self.inputSchema = inputSchema
        self.effect = effect
        self.interruption = interruption
        self.verification = verification
        self.channel = channel
        self.origin = origin
        self.memory = memory
        self.takesSession = takesSession
        self.parallelSafe = parallelSafe
    }
}
