import Foundation
@testable import Memory
import Testing

struct SensitivityCase: Decodable, Sendable {
    let id: String
    let value: String?
    let field: FieldSignals
    let expected: String
    let reason: SensitivityReason?
    let was: String?
    let gapClass: String?

    static let all: [Self] = {
        do {
            let url = Bundle.module.url(forResource: "sensitivity-cases", withExtension: "json")
            guard let url else { preconditionFailure("Missing sensitivity cases") }
            return try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
        } catch { preconditionFailure("Invalid sensitivity cases: \(error)") }
    }()
}

struct SensitivityClassifierTests {
    @Test(arguments: SensitivityCase.all)
    func sharedCases(item: SensitivityCase) {
        let verdict = SensitivityClassifier().classify(item.value, in: item.field)
        if item.expected == "gap" { return }
        #expect(verdict.sensitivity.rawValue == item.expected, "\(item.id)")
        if let reason = item.reason { #expect(verdict.reasons.contains(reason), "\(item.id)") }
        if item.was == "S", verdict.sensitivity == .ordinary {
            #expect([
                "reclassified-Key", "reclassified-Token", "reclassified-PIN",
                "reclassified-Token-one-digit", "reclassified-Token-two-digits", "reclassified-Token-quoted"
            ].contains(item.id))
        }
    }

    @Test func findings() {
        let text = "la password è Xy9#kq2!pL"
        let findings = SensitivityClassifier().findings(in: text, field: .init())
        #expect(findings.count == 1)
        #expect(findings.first.map { String(text[$0.range]) } == "Xy9#kq2!pL")
        #expect(SensitivityClassifier().findings(in: "A normal message", field: .init()).isEmpty)
    }
}
