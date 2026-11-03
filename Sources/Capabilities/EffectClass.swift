/// EffectClass describes how far a capability reaches outside its result.
public enum EffectClass: String, Sendable, Codable {
    case read, write, irreversible
}
