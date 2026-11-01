/// SensitivityTable owns the destination policy for classified values.
public enum SensitivityTable {
    public static func arrival(_ sensitivity: SensitivityClass, at destination: PrivacyDestination) -> Arrival {
        switch destination {
        case .model, .digest, .humanStepDetails, .turnReports:
            sensitivity == .secret ? .placeholder : .value
        case .episode, .debugReplay:
            sensitivity == .ordinary ? .value : .never
        case .method: .parameterOnly
        case .index, .log: .never
        }
    }
}
