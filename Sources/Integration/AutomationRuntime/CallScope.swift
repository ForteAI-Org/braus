//
//  CallScope.swift
//  Braus
//

import Engine
import EngineCore
import Foundation
import Memory

/// CallScope is what one tool call decided before anything of it was written (W1): the texts it withholds
/// beyond the producer's secrets, with why (`withheld`), and the field each of its text steps is bound to, by
/// the step's position (`bindings`, 0 for a single call). It is bound for the whole call (`$current`), from its
/// classification to its last output, and every record, transcript line, answer and error of the call reads
/// it. A concurrent call runs in another task and does not see it; nothing of it outlives the call.
nonisolated public struct CallScope: Sendable, Equatable {
    public private(set) var withheld: [String: WithholdingReason] = [:]
    /// The texts the call's records and transcript withhold but its answers show (P1-06): the confidential content a
    /// call writes to a confidential surface, which the model wrote or read and may read again.
    public private(set) var recordWithheld: [String: WithholdingReason] = [:]
    public var bindings: [Int: TextTargetBinding] = [:]

    public init() {}

    /// Withholds `text` for `reason`, the stronger reason kept when it was withheld already. Its line breaks read as
    /// spaces in a sentence that quotes a value, so that form is withheld too.
    public mutating func withhold(_ text: String, _ reason: WithholdingReason) {
        guard !text.isEmpty else { return }
        for form in Self.forms(of: text) {
            withheld[form] = ValueMinimization.strongest([reason, withheld[form] ?? reason])
        }
    }

    /// Withholds `text` from the call's records and transcript only, in the same forms as `withhold`.
    public mutating func withholdFromRecords(_ text: String, _ reason: WithholdingReason) {
        guard !text.isEmpty else { return }
        for form in Self.forms(of: text) {
            recordWithheld[form] = ValueMinimization.strongest([reason, recordWithheld[form] ?? reason])
        }
    }

    /// Everything the call's records withhold: what it withholds everywhere and what it withholds from records only.
    public var recordClassified: [String: WithholdingReason] {
        withheld.merging(recordWithheld) { ValueMinimization.strongest([$0, $1]) ?? $0 }
    }

    /// A text as written, and as a sentence that quotes it reads it: its line breaks as spaces, and the engine's
    /// quoted forms of it (`ActionEngine.quotedForms`), a long text's first 59 characters among them. These are a
    /// second line of defence: the engine told the text is withheld quotes none of them.
    public static func forms(of text: String) -> [String] {
        let flat = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var forms = [text]
        for form in [flat] + ActionEngine.quotedForms(of: text) where !forms.contains(form) { forms.append(form) }
        return forms
    }

    /// How the text step at `position` is dispatched: bound to the field it was classified for, withheld when any of
    /// its texts is, nil when it types nothing or was classified ordinary without a binding.
    public func dispatch(of texts: [String], at position: Int) -> TextDispatch? {
        if let binding = bindings[position] { return .bound(binding) }
        return texts.contains { withheld[$0] != nil } ? .withheld : nil
    }

    @TaskLocal public static var current = CallScope()
}
