import Foundation

/// HumanInterventionStrings interns typed operands, leaving punctuation and prose untouched.
/// Reference definitions are collected from tokens, never by scanning user-provided text for section signs.
nonisolated struct HumanInterventionStrings: Sendable {
    enum Token: Sendable, Equatable {
        case literal(String)
        case operand(String)

        var text: String {
            switch self {
            case .literal(let text), .operand(let text): return text
            }
        }
    }

    let entries: [String]

    init(tokens: [[Token]]) {
        var counts: [String: Int] = [:]
        for token in tokens.flatMap({ $0 }) {
            if case .operand(let value) = token { counts[value, default: 0] += 1 }
        }
        entries = counts.keys.filter {
            let count = counts[$0, default: 0]
            return $0.count > 8 && $0.utf8.count <= 180 && count > 1
                && (count - 1) * $0.utf8.count > count * 4 + String(reflecting: $0).utf8.count - $0.utf8.count + 8
        }.sorted()
    }

    init(lines: [String], candidates: [String]) {
        self.init(tokens: lines.map { [.literal($0)] })
    }

    /// Resolves one complete operand. Callers must not pass composed prose here.
    func reference(_ operand: String) -> String {
        guard let index = entries.firstIndex(of: operand) else { return operand }
        return "§\(index + 1)"
    }

    func value(_ reference: String) -> String? {
        guard reference.hasPrefix("§"), let index = Int(reference.dropFirst()), index > 0,
              entries.indices.contains(index - 1) else { return nil }
        return entries[index - 1]
    }

    func render(_ tokens: [[Token]]) -> String {
        var used = Set<Int>()
        let body = tokens.map { line in
            line.map { token in
                guard case .operand(let value) = token, let index = entries.firstIndex(of: value) else {
                    return token.text
                }
                used.insert(index)
                return "§\(index + 1)"
            }.joined()
        }
        let definitions = used.sorted().map { "§\($0 + 1)=\(String(reflecting: entries[$0]))" }
        return (definitions + body).joined(separator: "\n")
    }

    func render(_ lines: [String]) -> String {
        render(lines.map { [.literal($0)] })
    }
}
