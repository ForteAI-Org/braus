import Foundation
import Memory
import PerceptionCore
import Testing

struct PrivacyReviewRegressionTests {
    @Test(arguments: [
        ("API token", "0123456789abcdef0123456789abcdef", SensitivityClass.secret),
        ("API token", "01234567-89ab-cdef-0123-456789abcdef", .secret),
        ("PIN", "123", .secret),
        ("PIN", "1234", .secret),
        ("PIN", "12345678", .secret),
        ("PIN", "12", .ordinary),
        ("PIN", "123456789", .ordinary),
        ("PIN", "Off", .ordinary),
        ("ZIP code", "20121", .ordinary),
        ("Postal code", "20121", .ordinary),
        ("Codice postale", "20121", .ordinary),
        ("Key", "C major", .ordinary),
        ("Token", "abc", .ordinary),
        ("Code", "123", .ordinary),
        ("Code", "1234", .secret)
    ])
    func fieldClassificationAndMinimization(_ label: String, _ value: String, _ expected: SensitivityClass) {
        let classifier = SensitivityClassifier()
        let field = FieldSignals(labels: [label])
        #expect(classifier.classify(value, in: field).sensitivity == expected)
        #expect(classifier.valueGuard.withholdsValue(value, [label]) == (expected == .secret))
        let kept = ValueMinimization().minimize(text: value, typedInto: label).0
        #expect(kept == (expected == .secret ? "[withheld]" : value))
        let findings = classifier.findings(in: value, field: field)
        #expect(findings.isEmpty == (expected != .secret))
    }

    @Test func postalContextNeverOverridesOtherSecretEvidence() {
        let classifier = SensitivityClassifier()
        let labels = ["ZIP code"]
        for field in [
            FieldSignals(role: "AXSecureTextField", labels: labels),
            FieldSignals(labels: labels, declaredSecret: true),
            FieldSignals(labels: labels, markupDeclaresSecret: true),
            FieldSignals(labels: labels + ["Password"]),
            FieldSignals(labels: labels + ["Token"]),
            FieldSignals(labels: ["ZIP code token"])
        ] {
            #expect(classifier.classify("20121", in: field).sensitivity == .secret)
        }
        #expect(classifier.classify("4111111111111111", in: .init(labels: labels)).sensitivity == .secret)
    }

    @Test func explicitTokenLabelProtectsBeforeReadingAndInDeclarations() {
        let classifier = SensitivityClassifier()
        #expect(classifier.valueGuard.refusesLabel("API token"))
        #expect(!classifier.valueGuard.refusesLabel("Token"))
        #expect(!classifier.valueGuard.refusesLabel("PIN"))
        let text = "API token: synthetic-value"
        #expect(classifier.findings(in: text, field: .init()).map { String(text[$0.range]) } == ["synthetic-value"])
    }

    @Test func originalRuleDocumentsKeepTheirNumericPolicy() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SensitivityRules.bundled))
            as? [String: Any])
        object["version"] = 1
        object.removeValue(forKey: "weakLabelExceptions")
        object.removeValue(forKey: "shortCodeMinimumDigits")
        object["decisiveLabels"] = (try #require(object["decisiveLabels"] as? [String])).filter { $0 != "api token" }
        let rules = try JSONDecoder().decode(SensitivityRules.self,
            from: JSONSerialization.data(withJSONObject: object))
        let classifier = SensitivityClassifier(rules: rules)
        #expect(classifier.classify("123", in: .init(labels: ["PIN"])).sensitivity == .ordinary)
        #expect(classifier.classify("20121", in: .init(labels: ["ZIP code"])).sensitivity == .secret)
    }
}
