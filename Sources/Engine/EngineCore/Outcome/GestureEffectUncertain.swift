/// GestureEffectUncertain carries a structural cause while retaining delivery details for logs.
public struct GestureEffectUncertain: Error, Sendable, CustomStringConvertible {
    public let cause: String
    public let description: String

    public init(cause: String, description: String) {
        self.cause = cause
        self.description = description
    }
}
