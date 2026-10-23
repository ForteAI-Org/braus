//
//  RecallBinding.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation

/// RecallBinding assigns current task values only when their complete normalized names or roles
/// identify a unique, type-compatible input. Explicit roles must agree with a name match. Lexical
/// similarity never supplies a value, and learned examples never constrain a new task value.
/// File components can bind by their derived role. Required units remain unresolved until task
/// values carry unit evidence; this binder performs no conversion. Missing or ambiguous inputs
/// are requirements for the caller to resolve before using the method.
public enum RecallBinding {

    /// Value is one candidate of the task: a value of its revision, or one derived from a file it names.
    public struct Value: Sendable, Equatable {
        public let name: String
        public let role: String?
        public let kind: TaskValueKind
        public let text: String?
        public let isDerived: Bool
        /// Complete identity keys; lexical words remain available for choice compatibility checks.
        let nameKey: String
        let roleKey: String?
        let words: Set<String>

        init(name: String, role: String?, kind: TaskValueKind, text: String?, isDerived: Bool) {
            self.name      = name
            self.role      = role
            self.kind      = kind
            self.text      = text
            self.isDerived = isDerived
            self.nameKey   = RecallBinding.identityKey(name)
            self.roleKey   = role.map(RecallBinding.identityKey)
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

    /// Binds one parameter only when identity, type and unit evidence permit assignment.
    public static func bind(_ parameter: RecallSource.Parameter, among candidates: [Value]) -> Outcome {
        // TaskValue has no unit field. A number or free-form role cannot prove its unit.
        if let unit = parameter.unit, !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .missing
        }
        let nameKey = identityKey(parameter.name)
        let roleKey = identityKey(parameter.role)
        let direct = candidates.filter { !$0.isDerived }
        let named = direct.filter { !nameKey.isEmpty && $0.nameKey == nameKey }
        if named.count > 1 { return ambiguity(named) }
        if let value = named.first {
            guard accepts(parameter.kind, value.kind),
                  roleKey.isEmpty || value.roleKey == nil || value.roleKey == "" || value.roleKey == roleKey
            else { return .missing }
            return .bound(value, match: .name)
        }
        guard !roleKey.isEmpty else { return .missing }
        let sameRole = direct.filter { $0.roleKey == roleKey }
        if sameRole.count > 1 { return ambiguity(sameRole) }
        if let value = sameRole.first {
            let sameName = direct.filter { $0.nameKey == value.nameKey }
            if sameName.count > 1 { return ambiguity(sameName) }
            guard accepts(parameter.kind, value.kind) else { return .missing }
            return .bound(value, match: .role)
        }
        let derived = candidates.filter { $0.isDerived && $0.roleKey == roleKey }
        if derived.count > 1 { return ambiguity(derived) }
        if let value = derived.first, accepts(parameter.kind, value.kind) {
            if let component = value.name.lastIndex(of: ".") {
                let sourceKey = identityKey(String(value.name[..<component]))
                let sources = direct.filter { $0.nameKey == sourceKey }
                if sources.count > 1 { return ambiguity(sources) }
            }
            return .bound(value, match: .derived)
        }
        return .missing
    }

    /// Whether this task explicitly supplies the parameter's identity, even with incompatible facts.
    /// Historical producer feeds must not overwrite an input rejected for its role or kind.
    package static func hasIdentityCandidate(_ parameter: RecallSource.Parameter, among candidates: [Value]) -> Bool {
        let name = identityKey(parameter.name)
        let role = identityKey(parameter.role)
        return candidates.contains {
            !$0.isDerived && ((!name.isEmpty && $0.nameKey == name) || (!role.isEmpty && $0.roleKey == role))
        }
    }

    /// Normalizes identity without the truncation or stop-word removal used for search relevance.
    private static func identityKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func ambiguity(_ candidates: [Value]) -> Outcome {
        .ambiguous(candidates.map(\.name).sorted())
    }

    /// Whether a parameter of one kind can take a value of another.
    static func accepts(_ parameter: TaskValueKind, _ value: TaskValueKind) -> Bool {
        switch parameter {
            case .text     : value == .text
            case .file     : [.file, .reference].contains(value)
            case .folder   : value == .folder
            case .number   : value == .number
            case .boolean  : value == .boolean
            case .reference: [.reference, .file, .folder].contains(value)
            case .missing  : false
        }
    }
}
