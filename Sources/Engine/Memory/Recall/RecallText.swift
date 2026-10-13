//
//  RecallText.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation

/// RecallText reduces a text to the content words the lexical channel and the binding of parameters compare:
/// lowercased, diacritics folded, cut at anything that is not a letter or a digit (so `<output_name>` gives
/// `output` and `name`), Italian and English function words dropped, and each word cut to its first six
/// characters, a light stemming that makes `esporta`, `esportare` and `esportazione` one word. It knows no
/// vocabulary of tasks and no synonym: that is the point of the lexical baseline.
public enum RecallText {

    /// The length a word is cut to.
    public static let stemLength = 6

    /// The content words of a text, in order, repeated as they repeat.
    public static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var tokens: [String] = []
        var word = ""
        func flush() {
            defer { word = "" }
            guard !word.isEmpty, !stopwords.contains(word) else { return }
            tokens.append(String(word.prefix(stemLength)))
        }
        for character in folded {
            if character.isLetter || character.isNumber { word.append(character) } else { flush() }
        }
        flush()
        return tokens
    }

    /// The words of a text that state an operation, not its data: the content words left once every placeholder
    /// (`<output_name>`, as labels name their parameters and a masked need names the task's values) is removed. Data are
    /// bound by the binding; which step a request asks for is said by the rest.
    public static func operationTokens(_ text: String) -> [String] {
        tokens(text.replacingOccurrences(of: "<[^<>]*>", with: " ", options: .regularExpression))
    }

    /// The clauses of a text, each as its operation words: the text cut at the punctuation that ends a sentence or
    /// a clause and at the coordinating conjunctions of Italian and English, so `Find it, rotate it and export it` gives
    /// three clauses. Empty clauses are dropped.
    public static func clauses(_ text: String) -> [Set<String>] {
        let marked = text.replacingOccurrences(of: "[,;:.!?]", with: " | ", options: .regularExpression)
        var clauses: [Set<String>] = []
        var current: [String] = []
        for word in marked.split(whereSeparator: \.isWhitespace).map(String.init) {
            let folded = word.lowercased()
            if word == "|" || conjunctions.contains(folded) {
                let words = Set(operationTokens(current.joined(separator: " ")))
                if !words.isEmpty { clauses.append(words) }
                current = []
            } else {
                current.append(word)
            }
        }
        let words = Set(operationTokens(current.joined(separator: " ")))
        if !words.isEmpty { clauses.append(words) }
        return clauses
    }

    /// The first content word of each clause, as written (lower case), in order: what states the clause's work in an
    /// imperative request ("Turn …", "Esporta …"). Words cut and dropped as `clauses(_:)` does; a clause without a content
    /// word gives none. Placeholders (`<name>`) are no word.
    public static func clauseLeads(_ text: String) -> [String] {
        let marked = text.replacingOccurrences(of: "<[^<>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[,;:.!?]", with: " | ", options: .regularExpression)
        var leads: [String] = []
        var found = false
        for word in marked.split(whereSeparator: \.isWhitespace).map(String.init) {
            let folded = word.lowercased()
            if word == "|" || conjunctions.contains(folded) { found = false; continue }
            guard !found else { continue }
            for piece in folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) where !tokens(piece).isEmpty {
                leads.append(piece)
                found = true
                break
            }
        }
        return leads
    }

    /// The names of the task's values a text mentions, as `masked(_:values:)` finds them (a whole word, case aside, a
    /// file's name without its extension too), and a number of any length (a slide `2`) as a whole number: only a text that
    /// one value alone has, so two values written alike (an extension `png` and a format `PNG`) leave the mention to neither.
    public static func mentions(_ text: String, values: [TaskValue]) -> Set<String> {
        var owners: [String: Set<String>] = [:]
        for candidate in RecallBinding.candidates(values) where !candidate.isDerived || candidate.name.hasSuffix(".name") {
            guard let value = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  value.count >= 3 || (!value.isEmpty && value.allSatisfy(\.isNumber)) else { continue }
            let name = candidate.isDerived ? String(candidate.name.dropLast(".name".count)) : candidate.name
            owners[value.lowercased(), default: []].insert(name)
        }
        var mentioned: Set<String> = []
        for (value, names) in owners where names.count == 1 {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: value) + "(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
            mentioned.formUnion(names)
        }
        return mentioned
    }

    /// The coordinating conjunctions a request joins its clauses with.
    static let conjunctions: Set<String> = ["and", "then", "e", "ed", "poi", "quindi"]

    /// The text a need is searched with: every occurrence of one of the task's values, as a whole word, replaced by
    /// the value's name in angle brackets, as the labels of the learned parts name their parameters. A value is bound
    /// by name and role, never searched with: `report_q3.pdf to luca@example.com` is searched as `<file_name> to
    /// <recipient>`, so the episode's values neither pull nor push a part, and the placeholders meet the parts'
    /// own. The longest value goes first; a file's name without its extension is a value too; values shorter than
    /// three characters, withheld or missing are left in place.
    public static func masked(_ text: String, values: [TaskValue]) -> String {
        var replacements: [(text: String, name: String)] = []
        for candidate in RecallBinding.candidates(values) where !candidate.isDerived || candidate.name.hasSuffix(".name") {
            guard let value = candidate.text?.trimmingCharacters(in: .whitespacesAndNewlines), value.count >= 3 else { continue }
            let name = candidate.isDerived ? String(candidate.name.dropLast(".name".count)) : candidate.name
            replacements.append((value, name))
        }
        var masked = text
        for replacement in replacements.sorted(by: { $0.text.count > $1.text.count }) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: replacement.text) + "(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(masked.startIndex..., in: masked)
            masked = expression.stringByReplacingMatches(in: masked, range: range,
                                                         withTemplate: NSRegularExpression.escapedTemplate(for: "<\(replacement.name)>"))
        }
        return masked
    }

    /// Function words of Italian and English that say nothing about a task.
    static let stopwords: Set<String> = [
        "a", "ad", "al", "alla", "alle", "agli", "ai", "allo", "an", "and", "are", "as", "at", "be", "by", "che",
        "col", "con", "da", "dal", "dalla", "dalle", "dai", "dagli", "dallo", "de", "dei", "del", "della", "delle",
        "degli", "dello", "di", "e", "ed", "for", "from", "gli", "i", "il", "in", "into", "is", "it", "its", "l",
        "la", "le", "lo", "nel", "nella", "nelle", "nei", "negli", "nello", "o", "od", "of", "on", "or", "per", "su",
        "sul", "sulla", "sulle", "sui", "sugli", "sullo", "the", "to", "tra", "fra", "un", "una", "uno", "with", "s",
        "d", "this", "that", "questo", "questa", "quel", "quella", "their", "mio", "my",
    ]
}

/// LexicalIndex scores documents by how much of a query's content they hold, from 0 to 1, read as an absolute measure
/// so the same thresholds can say that nothing matches. How each query word weighs is the index's `Weighting`:
///
/// - `uniform`: every content word of the query weighs the same, so a part's score is the share of the query's words
///   its document holds. It depends on the query and the document only: the same part scores the same in an archive of
///   one procedure and in one of thousands (review F01).
/// - `version`: a word weighs its inverse document frequency among the documents of the part's own version, so a word
///   every part of the method holds (its application's name, its object) weighs less than the one that tells its steps
///   apart. It depends on the query and the part's version only: like `uniform`, the same part scores the same whatever
///   else the archive holds. The caller keeps one index per version.
/// - `collection`: a word weighs its inverse document frequency in the indexed documents, rare words more. The score of
///   a part then moves with the rest of the archive: a word no document holds lowers every score, and the weights of
///   the words a part holds grow with the number of documents, so a small archive scores the same request lower. Kept
///   for the comparison that showed it (`recall-calibration-v1`), not as a default.
public struct LexicalIndex: Sendable {

    public enum Weighting: String, Sendable, Equatable, Codable, CaseIterable {
        case uniform, version, collection
    }

    private let frequencies: [String: Int]
    private let count: Int
    public let weighting: Weighting

    /// An index over the documents' texts.
    public init(documents: [String], weighting: Weighting = .uniform) {
        var frequencies: [String: Int] = [:]
        for text in documents {
            for token in Set(RecallText.tokens(text)) { frequencies[token, default: 0] += 1 }
        }
        self.frequencies = frequencies
        self.count       = documents.count
        self.weighting   = weighting
    }

    /// An index from document frequencies already counted, for a reader that keeps them.
    public init(frequencies: [String: Int], count: Int, weighting: Weighting = .uniform) {
        self.frequencies = frequencies
        self.count       = count
        self.weighting   = weighting
    }

    /// The weight of a query word.
    public func weight(_ token: String) -> Double {
        switch weighting {
            case .uniform             : 1
            case .version, .collection: log(1 + Double(count + 1) / Double((frequencies[token] ?? 0) + 1))
        }
    }

    /// The share of the query's weighted content the document holds, from 0 to 1. The weights are summed in the words'
    /// order, so the same query and document give the same score to the last bit.
    public func score(query: Set<String>, document: Set<String>) -> Double {
        score(sorted: query.sorted(), document: document)
    }

    /// The same, for a query whose words the caller sorted once for many documents.
    public func score(sorted query: [String], document: Set<String>) -> Double {
        var total = 0.0, held = 0.0
        for word in query {
            let weight = weight(word)
            total += weight
            if document.contains(word) { held += weight }
        }
        return total > 0 ? held / total : 0
    }
}
