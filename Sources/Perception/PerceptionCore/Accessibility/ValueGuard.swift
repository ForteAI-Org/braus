/// ValueGuard supplies privacy decisions before and after a native value read.
public struct ValueGuard: Sendable {
    public let refusesLabel: @Sendable (String) -> Bool
    public let withholdsValue: @Sendable (_ value: String, _ labels: [String]) -> Bool

    public init(
        refusesLabel: @escaping @Sendable (String) -> Bool,
        withholdsValue: @escaping @Sendable (String, [String]) -> Bool
    ) {
        self.refusesLabel = refusesLabel
        self.withholdsValue = withholdsValue
    }
}
