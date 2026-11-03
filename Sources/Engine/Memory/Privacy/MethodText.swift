import Foundation
import PerceptionCore

/// MethodText decides whether a label may describe a reusable method or names an instance.
/// Admission generalizes whole labels; Recall masking preserves its existing free-text contract.
public enum MethodText {

    /// InstanceReason identifies why a label must be represented by its role.
    public enum InstanceReason: String, Sendable, Equatable, CaseIterable {
        case taskValue, fileName, collectionMember, dateOrNumber, ordinal
    }

    /// Admission keeps normalized method text or replaces an instance with its placeholder.
    public enum Admission: Sendable, Equatable {
        case method(String)
        case instance(placeholder: String, InstanceReason)
    }

    /// Context supplies the task's values and the structural origin of a label.
    public struct Context: Sendable, Equatable {
        public let values: [TaskValue]
        public let isUnderCollection: Bool
        public let role: String?

        public init(
            values: [TaskValue] = [],
            isUnderCollection: Bool = false,
            role: String? = nil
        ) {
            self.values = values
            self.isUnderCollection = isUnderCollection
            self.role = role
        }
    }

    /// Judges a whole label, applying task values before file shapes, collections and numeric forms.
    public static func admit(_ text: String, in context: Context) -> Admission {
        let label = normalized(text)
        for candidate in admissionCandidates(context.values) {
            let matches = candidate.text.count < 3
                ? label.compare(candidate.text, options: .caseInsensitive) == .orderedSame
                : contains(token(candidate.text), in: label)
            if matches {
                let name = contains(#"\A[A-Za-z_][A-Za-z0-9_]*\z"#, in: candidate.owner, options: [])
                    ? candidate.owner : "value"
                return .instance(placeholder: "<\(name)>", .taskValue)
            }
        }
        if isFileName(label) { return .instance(placeholder: "<file_name>", .fileName) }
        if context.isUnderCollection {
            let placeholder = switch context.role {
                case "AXRow": "<row>"
                case "AXCell": "<cell>"
                default: "<item>"
            }
            return .instance(placeholder: placeholder, .collectionMember)
        }
        for (pattern, placeholder) in numericForms where contains(pattern, in: label) {
            return .instance(placeholder: placeholder, .dateOrNumber)
        }
        if contains(#"\A\p{L}+(?: +\p{L}+)* +[0-9]{1,2}\z"#, in: label) {
            let words = label.split(separator: " ").dropLast().joined(separator: " ").lowercased()
            let placeholder = switch words {
                case "track", "traccia": "<track>"
                case "row", "riga": "<row>"
                case "column", "colonna": "<column>"
                default: "<item>"
            }
            return .instance(placeholder: placeholder, .ordinal)
        }
        return .method(LabelText.normalize(label))
    }

    /// Replaces task values using Recall's original candidate order and length threshold.
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

    /// Returns the unambiguous owners mentioned by Recall's original candidates.
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

    /// Recognizes the file shape used by scene captions, without changing its original pattern.
    static func isFileName(_ text: String) -> Bool {
        fileName.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let fileName: NSRegularExpression = {
        do {
            return try NSRegularExpression(
                pattern: #"(?<![\w.])[^\s/\\:]*[\p{L}\p{N}]\.\p{L}[\p{L}\p{N}]{0,4}(?![\w])"#
            )
        } catch {
            preconditionFailure("Invalid MethodText file expression: \(error)")
        }
    }()

    private struct Candidate {
        let text: String
        let owner: String
        let isDerived: Bool
    }

    private static func admissionCandidates(_ values: [TaskValue]) -> [Candidate] {
        var candidates: [Candidate] = []
        func append(_ text: String, owner: String, isDerived: Bool) {
            let text = normalized(text)
            guard !text.isEmpty else { return }
            candidates.append(Candidate(text: text, owner: owner, isDerived: isDerived))
        }
        for value in RecallBinding.candidates(values) where !value.isDerived {
            guard let text = value.text else { continue }
            append(text, owner: value.name, isDerived: false)
            guard value.kind == .file else { continue }
            let path = normalized(text) as NSString
            let file = path.lastPathComponent
            append(file, owner: value.name, isDerived: true)
            append((file as NSString).deletingPathExtension, owner: value.name, isDerived: true)
            append(path.deletingLastPathComponent, owner: value.name, isDerived: true)
        }
        let sorted = candidates.sorted {
            if $0.text.count != $1.text.count { return $0.text.count > $1.text.count }
            if $0.isDerived != $1.isDerived { return !$0.isDerived }
            return $0.owner.utf8.lexicographicallyPrecedes($1.owner.utf8)
        }
        var seen: [String: Set<String>] = [:]
        return sorted.filter { seen[$0.text, default: []].insert($0.owner).inserted }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private static func token(_ text: String) -> String {
        #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: text) + #"(?![\p{L}\p{N}])"#
    }

    private static func contains(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> Bool {
        do {
            let expression = try NSRegularExpression(pattern: pattern, options: options)
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        } catch {
            preconditionFailure("Invalid MethodText expression: \(error)")
        }
    }

    private static let numericForms: [(String, String)] = [
        (#"(?<![\p{L}\p{N}])(?:[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])|(?:0?[1-9]|[12][0-9]|3[01])([/.-])(?:0?[1-9]|1[0-2])\1[0-9]{4})(?![\p{L}\p{N}])"#, "<date>"),
        (#"(?<![\p{L}\p{N}])(?:[01]?[0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9])?(?![\p{L}\p{N}])"#, "<time>"),
        (#"(?<![\p{L}\p{N}])(?:[€$£]\s*[+-]?[0-9]+(?:[.,][0-9]{2})?|[+-]?[0-9]+(?:[.,][0-9]{2})?\s*[€$£])(?![\p{L}\p{N}])"#, "<amount>"),
        (#"(?<![\p{L}\p{N}])[0-9]{3,}(?![\p{L}\p{N}])"#, "<number>"),
    ]


}
