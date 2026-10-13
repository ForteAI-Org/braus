//
//  RecallConstraint.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation

/// RecallConstraint is one of the task's constraints as the selector reads it: the clauses it forbids, or nothing
/// the selector can check. Only a prohibition is checked, and only against what a step states: its label, its fixed
/// arguments and its application. A clause is forbidden when it carries a negation (`do not`, `don't`, `never`,
/// `without`, `avoid`, `non`, `senza`, `mai`, `evita`) or follows a forbidden one after `or`, `nor`, `o`, `né`.
///
/// - A forbidden clause that names an application and, besides it, at most a verb of opening or using it (`do not
///   open Mail`, `senza usare Mail`) forbids every step on that application.
/// - A forbidden clause that names the item a step fixes as its choice forbids that step (`never save it as JPEG`
///   forbids the step that chooses `JPEG`).
/// - Any other forbidden clause forbids a step whose own words hold all of the clause's content words (`do not share
///   the note` forbids `Share the note through Mail`, not `Create a new note`).
///
/// A clause that forbids nothing (a positive condition, a preference, a limit of time) is not checked: the selection
/// carries its constraint as a condition for the agent, never as satisfied. A step that a clause does not forbid is
/// not proved to respect the constraint: the check reads words, not effects.
public struct RecallConstraint: Sendable, Equatable {

    /// Clause is one forbidden clause: its content words, and the words that name an application.
    public struct Clause: Sendable, Equatable {
        public let words: Set<String>
    }

    public let position: Int
    public let text: String
    public let forbidden: [Clause]
    /// Whether the constraint also says something that forbids nothing, which the selector does not check.
    public let hasUnchecked: Bool

    /// The constraints of a request, in its order.
    public static func parse(_ texts: [String]) -> [RecallConstraint] {
        texts.enumerated().map { position, text in
            let (forbidden, unchecked) = clauses(of: text)
            return RecallConstraint(position: position, text: text, forbidden: forbidden, hasUnchecked: unchecked || forbidden.isEmpty)
        }
    }

    /// Whether a clause of the constraint forbids the step.
    public func forbids(_ step: RecallSource.Step) -> Bool {
        let words = step.words
        let application = step.bundleID.map { Set(RecallText.tokens(RecallDocument.applicationName($0))) } ?? []
        let choice: Set<String> = step.choiceArgument.flatMap { name in step.arguments.first { $0.name == name } }.flatMap {
            if case .literal(.text(let text)) = $0.value { Set(RecallText.tokens(text)) } else { nil }
        } ?? []
        for clause in forbidden {
            let named = clause.words.intersection(application)
            if !named.isEmpty, clause.words.subtracting(named).isSubset(of: Self.applicationVerbs) { return true }
            if !choice.isEmpty, choice.isSubset(of: clause.words) { return true }
            if !clause.words.isEmpty, clause.words.isSubset(of: words.union(application)) { return true }
        }
        return false
    }

    // MARK: Reading

    /// The words that make a clause a prohibition, as whole lowercased words.
    static let negations: Set<String> = ["not", "dont", "never", "without", "avoid", "no", "non", "senza", "mai", "evita", "evitare",
                                         "evitando", "neither"]
    /// The words that carry a prohibition on to the next clause.
    static let alternatives: Set<String> = ["or", "nor", "o", "oppure", "né"]
    /// The words that separate clauses.
    static let joins: Set<String> = Set(["and", "but", "e", "ma", "ed"]).union(alternatives)
    /// Verbs that say only how a clause acts on what it names: dropped from its content words.
    static let generic: Set<String> = Set(RecallText.tokens("do does did doing make made use using used fare fai usa usare usando utilizza utilizzare"))
    /// Verbs of opening or using an application: a clause of one of them and an application's name forbids that application.
    static let applicationVerbs: Set<String> = Set(RecallText.tokens(
        "open opening launch start switch go apri aprire aprendo avvia avviare passa passare vai andare entra entrare")).union(generic)

    /// The forbidden clauses of a text, and whether it has a clause with content that forbids nothing.
    static func clauses(of text: String) -> ([Clause], Bool) {
        // Words as written, lowercased, apostrophes kept inside a word so `don't` reads as one.
        var words: [String] = []
        var word = ""
        var separators: Set<Int> = []
        for character in text.lowercased() {
            if character.isLetter || character.isNumber { word.append(character); continue }
            if character == "'" || character == "’" { continue }
            if !word.isEmpty { words.append(word); word = "" }
            if ",;.:!?".contains(character) { separators.insert(words.count) }
        }
        if !word.isEmpty { words.append(word) }
        var clauses: [Clause] = []
        var unchecked = false
        var current: [String] = []
        var negated = false
        var carried = false
        func close() {
            defer { current = []; negated = false }
            let content = Set(RecallText.tokens(current.joined(separator: " "))).subtracting(generic)
            guard !content.isEmpty else { return }
            if negated || carried { clauses.append(Clause(words: content)) } else { unchecked = true }
        }
        for (index, word) in words.enumerated() {
            if separators.contains(index), !current.isEmpty {
                close()
                carried = false
            }
            if joins.contains(word) {
                let forbidden = negated || carried
                close()
                carried = forbidden && alternatives.contains(word)
                continue
            }
            if negations.contains(word) {
                negated = true
                continue
            }
            current.append(word)
        }
        close()
        return (clauses, unchecked)
    }
}
