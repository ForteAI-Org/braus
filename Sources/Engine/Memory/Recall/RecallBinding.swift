//
//  RecallBinding.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation

/// RecallBinding assigns the current task's values to the parameters a selection reads, never a value of the
/// episode it was learned from. A parameter takes the task's value of the same name; else the one of the same
/// role; else a value derived from a file of the same role; else the one whose name and role share most of the
/// parameter's content words, when it is the only good one; a value the task names as a file also offers its name,
/// extension and folder as derived values, so a
/// method that types `<name>.<extension>` binds to a file the task names whole. Types must agree. Nothing else is
/// guessed: no value is a `missing` parameter the agent resolves (from the request, an observation of the
/// application, or the person); two equally good values are `ambiguous`. A binding says which task value it took,
/// by name, and how: the value itself stays in the task.
public enum RecallBinding {

    /// Value is one candidate of the task: a value of its revision, or one derived from a file it names.
    public struct Value: Sendable, Equatable {
        public let name: String
        public let role: String?
        public let kind: TaskValueKind
        public let text: String?
        public let isDerived: Bool
        /// The content words of the name and of the role, as `bind` compares them: computed once.
        let nameKey: String
        let roleKey: String?
        let words: Set<String>

        init(name: String, role: String?, kind: TaskValueKind, text: String?, isDerived: Bool) {
            self.name      = name
            self.role      = role
            self.kind      = kind
            self.text      = text
            self.isDerived = isDerived
            self.nameKey   = RecallText.tokens(name).joined(separator: " ")
            self.roleKey   = role.map { RecallText.tokens($0).joined(separator: " ") }
            self.words     = Set(RecallText.tokens(name + " " + (role ?? "")))
        }
    }

    /// Outcome is a parameter's binding.
    public enum Outcome: Sendable, Equatable {
        case bound(Value, match: RecallRequirement.BindingMatch)
        case missing
        case ambiguous([String])
    }

    /// The task's values a binding may take: those it holds (not those it still misses), and for a file with a
    /// path or name, its name without extension, its extension and its folder.
    public static func candidates(_ values: [TaskValue]) -> [Value] {
        var candidates: [Value] = []
        for value in values where value.kind != .missing {
            let text: String? = if case .text(let text) = value.content { text } else { nil }
            candidates.append(Value(name: value.name, role: value.role, kind: value.kind, text: text, isDerived: false))
            guard value.kind == .file, let text, !text.isEmpty else { continue }
            let path = text as NSString
            let file = path.lastPathComponent
            let base = (file as NSString).deletingPathExtension
            let ext  = (file as NSString).pathExtension
            let what = value.role ?? value.name
            if !base.isEmpty {
                candidates.append(Value(name: "\(value.name).name", role: "name of \(what) without extension", kind: .text,
                                        text: base, isDerived: true))
            }
            if !ext.isEmpty {
                candidates.append(Value(name: "\(value.name).extension", role: "extension of \(what)", kind: .text, text: ext,
                                        isDerived: true))
            }
            let folder = path.deletingLastPathComponent
            if !folder.isEmpty, folder != text {
                candidates.append(Value(name: "\(value.name).folder", role: "folder of \(what)", kind: .folder, text: folder,
                                        isDerived: true))
            }
        }
        return candidates
    }

    /// The binding of one parameter among the candidates.
    public static func bind(_ parameter: RecallSource.Parameter, among candidates: [Value]) -> Outcome {
        let compatible = candidates.filter { accepts(parameter.kind, $0.kind) }
        if !parameter.nameKey.isEmpty, let same = compatible.first(where: { !$0.isDerived && $0.nameKey == parameter.nameKey }) {
            return .bound(same, match: .name)
        }
        let roleKey = parameter.roleKey
        if !roleKey.isEmpty {
            let sameRole = compatible.filter { !$0.isDerived && $0.roleKey == roleKey }
            if sameRole.count == 1 { return .bound(sameRole[0], match: .role) }
            if sameRole.count > 1 { return .ambiguous(sameRole.map(\.name)) }
            // A value derived from a file the task names, whose role says exactly the parameter's.
            let derivedRole = compatible.filter { $0.isDerived && $0.roleKey == roleKey }
            if derivedRole.count == 1 { return .bound(derivedRole[0], match: .derived) }
        }
        let wanted = parameter.words
        guard !wanted.isEmpty else { return .missing }
        let scored = compatible.map { value -> (Value, Double) in
            (value, Double(wanted.intersection(value.words).count) / Double(wanted.count))
        }.filter { $0.1 >= 0.5 }.sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return .missing }
        if scored.count > 1, best.1 - scored[1].1 < 0.25 { return .ambiguous(scored.prefix(4).map(\.0.name)) }
        return .bound(best.0, match: best.0.isDerived ? .derived : .role)
    }

    /// Whether a parameter of one kind can take a value of another.
    static func accepts(_ parameter: TaskValueKind, _ value: TaskValueKind) -> Bool {
        switch parameter {
            case .text     : [.text, .reference, .number].contains(value)
            case .file     : [.file, .reference].contains(value)
            case .folder   : value == .folder
            case .number   : value == .number
            case .boolean  : value == .boolean
            case .reference: [.reference, .file, .folder].contains(value)
            case .missing  : false
        }
    }
}
