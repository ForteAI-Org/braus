@testable import Memory
import Testing

struct SensitivityFindingsTests {
    @Test(arguments: ["password:fake-value", "password = fake-value", "la password è fake-value"])
    func declarations(text: String) {
        let found = SensitivityClassifier().findings(in: text, field: .init())
        #expect(found.count == 1)
        #expect(found.first.map { String(text[$0.range]) } == "fake-value")
    }

    @Test func rangesAndPrecedence() {
        let text = "🧪 card 4111 1111 1111 1111; password: sk-aaaaaaaaaaaaaaaa"
        let found = SensitivityClassifier().findings(in: text, field: .init())
        #expect(found.map { String(text[$0.range]) } == ["4111 1111 1111 1111", "sk-aaaaaaaaaaaaaaaa"])
        #expect(SensitivityClassifier().classify("4111111111111111", in: .init(isContent: true))
            .sensitivity == .secret)
        let personal = SensitivityClassifier().findings(in: "Personal body", field: .init(isContent: true))
        #expect(personal.first?.verdict.sensitivity == .personal)
    }

    @Test func contextualSpans() {
        let classifier = SensitivityClassifier()
        let code = classifier.findings(in: "1234", field: .init(labels: ["PIN"]))
        #expect(code.first?.verdict.sensitivity == .secret)
        let text = "Body 4111 1111 1111 1111 end"
        let findings = classifier.findings(in: text, field: .init(isContent: true))
        #expect(findings.map(\.verdict.sensitivity) == [.personal, .secret, .personal])
    }

    @Test(arguments: ["Pay GB82 WEST 1234 5698 7654 32 today", "Pay DE89370400440532013000 TODAY"])
    func accountInSentence(text: String) {
        let findings = SensitivityClassifier().findings(in: text, field: .init())
        #expect(findings.count == 1)
        #expect(findings.first.map { String(text[$0.range]) } == (text.contains("GB82")
            ? "GB82 WEST 1234 5698 7654 32" : "DE89370400440532013000"))
    }

    @Test(arguments: SensitivityRules.bundled.decisiveLabels)
    func declaredValueUsesTheWholeLabel(label: String) {
        let text = label + ": fake-value"
        let found = SensitivityClassifier().findings(in: text, field: .init())
        #expect(found.map { String(text[$0.range]) } == ["fake-value"])
    }

    @Test func adjacentDeclarationsRemainSensitive() {
        let text = "password: secret: fake-value"
        let found = SensitivityClassifier().findings(in: text, field: .init())
        #expect(found.map { String(text[$0.range]) } == ["secret:", "fake-value"])
        let unicode = "préface\u{00A0}sk-aaaaaaaaaaaaaaaa\u{2003}end"
        let token = SensitivityClassifier().findings(in: unicode, field: .init())
        #expect(token.map { String(unicode[$0.range]) } == ["sk-aaaaaaaaaaaaaaaa"])
    }

    @Test func measurements() {
        let classifier = SensitivityClassifier()
        let cases = SensitivityCase.all
        var truePositive = 0, falsePositive = 0, falseNegative = 0
        for item in cases where item.expected != "gap" {
            let secret = classifier.classify(item.value, in: item.field).sensitivity == .secret
            if secret && item.expected == "S" { truePositive += 1 }
            if secret && item.expected != "S" { falsePositive += 1 }
            if !secret && item.expected == "S" { falseNegative += 1 }
        }
        print("Sensitivity cases: \(cases.count), gaps: \(cases.filter { $0.expected == "gap" }.count), "
            + "TP: \(truePositive), FP: \(falsePositive), FN: \(falseNegative)")
        #expect(falsePositive == 0 && falseNegative == 0)
        let personalCases = cases.filter { $0.expected == "P" || $0.gapClass == "P" }
        print("Sensitivity personal gaps: \(personalCases.filter { $0.expected == "gap" }.count)/\(personalCases.count)")

    }
    @Test func ordinaryWordsAreNotDeclarations() {
        let classifier = SensitivityClassifier()
        for word in ["secret", "otp", "mfa"] {
            #expect(classifier.findings(in: "The \(word) settings are available", field: .init()).isEmpty)
            #expect(classifier.findings(in: "\(word): fake-value", field: .init()).count == 1)
            #expect(classifier.findings(in: "\(word) is fake-value", field: .init()).count == 1)
            #expect(classifier.classify("fake-value", in: .init(labels: [word])).sensitivity == .secret)
        }
        #expect(classifier.classify("Open", in: .init(labels: ["4111 1111 1111 1111"])).sensitivity == .ordinary)
        #expect(classifier.classify("Open", in: .init(labels: ["GB82 WEST 1234 5698 7654 32"])).sensitivity == .ordinary)
        #expect(classifier.classify("Open", in: .init(labels: ["sk-aaaaaaaaaaaaaaaa"])).sensitivity == .secret)
    }

    @Test func prefilterPreservesSensitiveCandidates() {
        let classifier = SensitivityClassifier()
        #expect(!classifier.mayContainSensitiveText(String(repeating: "A normal message with ordinary words. ", count: 32)))
        for item in SensitivityCase.all where item.expected == "S" {
            guard let text = item.value, !text.isEmpty else { continue }
            let found = classifier.findings(in: text, field: item.field)
            #expect(!found.isEmpty, "\(item.id)")
        }
        for text in ["sk-aaaaaaaaaaaaaaaa", "password: fake-value", "secret: fake-value",
                     "4111 1111 1111 1111", "GB82 WEST 1234 5698 7654 32",
                     "eyJaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc", "-----BEGIN PRIVATE KEY-----fake"] {
            #expect(classifier.mayContainSensitiveText(text))
            #expect(!classifier.findings(in: text, field: .init()).isEmpty)
            #expect(ValueMinimization().minimize(text: text).0.contains("[withheld]"))
        }
    }

}
