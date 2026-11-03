import Memory
import PerceptionCore
import Testing

struct PostalExceptionBoundaryTests {
    @Test(arguments: [
        ("ZIP codebook code", SensitivityClass.secret),
        ("Postal codebook code", .secret),
        ("Codice postales codice", .secret),
        ("Shipping ZIP code", .ordinary),
        ("Shipping postal-code", .ordinary),
        ("Indirizzo: codice postale", .ordinary)
    ])
    func postalExceptionsRequireWholeWords(_ label: String, _ expected: SensitivityClass) {
        let classifier = SensitivityClassifier()
        let value = "20121"
        let field = FieldSignals(labels: [label])
        #expect(classifier.classify(value, in: field).sensitivity == expected)
        #expect(classifier.valueGuard.withholdsValue(value, [label]) == (expected == .secret))
        #expect(ValueMinimization().minimize(text: value, typedInto: label).0
            == (expected == .secret ? "[withheld]" : value))
    }
}
