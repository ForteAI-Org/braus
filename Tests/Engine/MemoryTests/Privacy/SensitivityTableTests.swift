import Memory
import Testing

struct SensitivityTableTests {
    @Test(arguments: SensitivityClass.allCases, PrivacyDestination.allCases)
    func everyDestination(sensitivity: SensitivityClass, destination: PrivacyDestination) {
        let expected: Arrival
        switch destination {
        case .model, .digest, .humanStepDetails, .turnReports:
            expected = sensitivity == .secret ? .placeholder : .value
        case .episode, .debugReplay:
            expected = sensitivity == .ordinary ? .value : .never
        case .method: expected = .parameterOnly
        case .index, .log: expected = .never
        }
        #expect(SensitivityTable.arrival(sensitivity, at: destination) == expected)
    }
}
