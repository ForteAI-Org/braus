//
//  ClassifiedWithholdingTests.swift
//  Braus
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
import Testing

/// W1 typed secrets: a text the call classified before its first write, typed into a secure field or into a target
/// whose ordinary nature was not attested, is withheld from every record of the call with its own reason; an ordinary
/// text is kept, so the memory keeps learning it.
@Suite("Classified withholding (W1 typed secrets)")
struct ClassifiedWithholdingTests {

    static let typed = "typed-W1-4417"

    @Test("type_text into a secure field: the text is withheld with secure_field, the target kept")
    func secureField() {
        let minimization = ValueMinimization(classified: [Self.typed: .secureField])
        let (kept, gaps) = minimization.minimize(
            .typeText(target: "Accesso", text: Self.typed, section: nil, replace: false), eventID: "e1")
        guard case .typeText(let target, let text, _, _) = kept else { Issue.record("not type_text"); return }
        #expect(text == ValueMinimization.marker && target == "Accesso")
        #expect(gaps == [ValueRedaction(eventID: "e1", location: .argument(name: "text", position: 0), reason: .secureField)])
    }

    @Test("insert_text at an unattested focus: its text and expected value are withheld with unclassified_target")
    func unclassifiedInsert() {
        let minimization = ValueMinimization(classified: [Self.typed: .unclassifiedTarget])
        let (kept, gaps) = minimization.minimize(.insertText(text: Self.typed, expectedValue: Self.typed), eventID: "e2")
        guard case .insertText(let text, let expected) = kept else { Issue.record("not insert_text"); return }
        #expect(text == ValueMinimization.marker && expected == ValueMinimization.marker)
        #expect(Set(gaps) == [
            ValueRedaction(eventID: "e2", location: .argument(name: "text", position: 0), reason: .unclassifiedTarget),
            ValueRedaction(eventID: "e2", location: .argument(name: "expected_value", position: 0), reason: .unclassifiedTarget),
        ])
    }

    @Test("the classified text is withheld wherever the call's records hold it: result, error, effect, identity")
    func everywhereInTheCall() {
        let minimization = ValueMinimization(classified: [Self.typed: .unclassifiedTarget])
        let (result, gaps) = minimization.minimize(
            result: .outcome(.foundActed, message: "the field reads '\(Self.typed)'"), eventID: "e3")
        guard case .outcome(_, let message)? = result else { Issue.record("not an outcome"); return }
        #expect(message == "the field reads '\(ValueMinimization.marker)'")
        #expect(gaps == [ValueRedaction(eventID: "e3", location: .resultMessage, reason: .unclassifiedTarget)])
        let (error, _) = minimization.minimize(result: .error(message: "could not type \(Self.typed)"), eventID: "e3")
        guard case .error(let failure)? = error else { Issue.record("not an error"); return }
        #expect(failure == "could not type \(ValueMinimization.marker)")
        let (effect, why) = minimization.minimize(effect: .valueChanged(label: "Nome", value: Self.typed))
        #expect(effect == .valueChanged(label: "Nome", value: ValueMinimization.marker) && why == .unclassifiedTarget)
        let (text, reason) = minimization.minimize(text: "→ type_text {\"text\":\"\(Self.typed)\"}")
        #expect(!text.contains(Self.typed) && reason == .unclassifiedTarget)
    }

    @Test("the secrets withheld from earlier arguments are added without losing the classification")
    func addingKeepsTheClassification() {
        let minimization = ValueMinimization(classified: [Self.typed: .secureField]).adding(secrets: ["other-secret-1"])
        #expect(minimization.minimize(text: Self.typed) == (ValueMinimization.marker, .secureField))
        #expect(minimization.minimize(text: "other-secret-1").1 == .declaredSecret)
    }

    @Test("a classified fragment of a declared secret, or the reverse, never leaves a piece of either visible",
          arguments: [(["office-8842"], ["8842"]), (["8842"], ["office-8842"])])
    func overlapWithDeclared(declared: [String], classified: [String]) {
        let minimization = ValueMinimization(secrets: declared,
                                             classified: Dictionary(uniqueKeysWithValues: classified.map { ($0, .unclassifiedTarget) }))
        let (kept, reason) = minimization.minimize(text: "door office-8842 open")
        #expect(kept == "door \(ValueMinimization.marker) open", "\(kept)")
        #expect(reason == .unclassifiedTarget)
        let (identity, _) = minimization.minimize(identifier: "control|office8842", label: nil)
        #expect(!identity.contains("8842") && !identity.contains("office"), "\(identity)")
    }

    @Test("a classified fragment never breaks a credential's shape: the whole credential is withheld")
    func overlapWithCredential() {
        let credential = "sk-ant-abcdEFGH1234567890xyz"
        let minimization = ValueMinimization(classified: ["abcd": .unclassifiedTarget])
        let (kept, reason) = minimization.minimize(text: "key \(credential) end")
        #expect(kept == "key \(ValueMinimization.marker) end", "\(kept)")
        #expect(!kept.contains("EFGH1234567890") && !kept.contains("sk-ant-"))
        #expect(reason == .unclassifiedTarget)
        let generated = "aB3dE5fG7hI9jK1lmN2oP4qR6sT8uV0wX"
        let (token, _) = ValueMinimization(classified: ["fG7h": .unclassifiedTarget]).minimize(text: "token \(generated)")
        #expect(token == "token \(ValueMinimization.marker)", "\(token)")
    }

    @Test("the reason is the strongest of the original's matches, whichever is longer",
          arguments: [("pin 4417 x", WithholdingReason.unclassifiedTarget, "4417", WithholdingReason.secureField),
                      ("pin 4417 x", WithholdingReason.secureField, "4417", WithholdingReason.unclassifiedTarget)])
    func strongestOfTheOriginal(long: String, longReason: WithholdingReason, short: String, shortReason: WithholdingReason) {
        let minimization = ValueMinimization(classified: [long: longReason, short: shortReason])
        let (kept, reason) = minimization.minimize(text: "say \(long) now")
        #expect(kept == "say \(ValueMinimization.marker) now", "\(kept)")
        #expect(reason == .secureField)
    }

    @Test("a text secure and unclassified at once is withheld as secure; with no classification an ordinary text is kept")
    func precedenceAndOrdinary() {
        let both = ValueMinimization(classified: [Self.typed: .unclassifiedTarget, "pin \(Self.typed)": .secureField])
        #expect(both.minimize(text: "pin \(Self.typed)").1 == .secureField)
        let (kept, gaps) = ValueMinimization().minimize(
            .typeText(target: "Nome", text: "Ada Lovelace", section: nil, replace: true), eventID: "e4")
        guard case .typeText(_, let text, _, _) = kept else { Issue.record("not type_text"); return }
        #expect(text == "Ada Lovelace" && gaps.isEmpty)
    }
}
