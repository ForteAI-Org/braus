import Capabilities
import LocalMCP

func demoContract(
    _ name: String,
    effect: EffectClass = .read,
    interruption: InterruptionClass = .readOnly,
    parallelSafe: Bool = false,
    origin: Origin = .registered(provider: "demo")
) -> CapabilityContract {
    CapabilityContract(
        id: CapabilityID(rawValue: name),
        group: "demo",
        description: "Demo capability",
        inputSchema: .object(["type": .string("object")]),
        effect: effect,
        interruption: interruption,
        verification: .none(reason: "Result only"),
        channel: .braus,
        origin: origin,
        memory: .capabilityStep,
        takesSession: false,
        parallelSafe: parallelSafe
    )
}

