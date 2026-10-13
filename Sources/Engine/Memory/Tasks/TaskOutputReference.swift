//
//  TaskOutputReference.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import Foundation

/// TaskOutputReference is a value's structural reference to an output of a task, `<task id>/<output name>`: the
/// `source_ref` the task contract documents for a previous output. The task id is the UUID the store drew, in its
/// canonical upper-case form, which the generic credential rule (a long word mixing case and digits) would withhold
/// whole. Recognizing the shape admits nothing. A reference is kept only on the path that knows its role, where the
/// task and its outputs can be read (`admitting`); one that does not resolve is minimized as any text is, and a
/// reference already withheld stays withheld. The output's name is the only free text, and it is minimized on its own.
public struct TaskOutputReference: Sendable, Equatable, Hashable {
    public let taskID: String
    public let output: String

    /// The longest output name a reference may carry, in UTF-8 bytes.
    public static let maximumNameBytes = 256

    public init?(_ text: String) {
        guard let slash = text.firstIndex(of: "/") else { return nil }
        let id = String(text[..<slash]), name = String(text[text.index(after: slash)...])
        guard Self.isTaskID(id), !name.isEmpty, name.utf8.count <= Self.maximumNameBytes,
              name.unicodeScalars.allSatisfy({ $0 != "/" && !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.taskID = id
        self.output = name
    }

    public var text: String { taskID + "/" + output }

    /// Whether a text is a task id as the store draws it: a UUID in its canonical upper-case form.
    public static func isTaskID(_ text: String) -> Bool {
        UUID(uuidString: text)?.uuidString == text
    }

    /// The `source_ref` of a value as the contract keeps it. A text with a reference's shape is kept as given when neither
    /// the whole nor its output name holds anything to withhold, and is then admitted or minimized where its task can be
    /// read. Any other text is minimized as a value's describing text.
    public static func kept(_ text: String, by minimization: ValueMinimization) -> String {
        if let reference = TaskOutputReference(text), minimization.minimize(text: reference.output).1 == nil,
           !minimization.withholdingDeclared(text).1 {
            return text
        }
        return minimization.minimize(text: text).0
    }

    /// The `source_version` of a value as the contract keeps it: beside a reference's shape, an attempt's id (a UUID) or a
    /// revision number is kept as given, to be checked with the reference; any other text is minimized.
    public static func keptVersion(_ text: String, reference: String?, by minimization: ValueMinimization) -> String {
        if reference.flatMap(TaskOutputReference.init) != nil, isTaskID(text) || isRevision(text),
           !minimization.withholdingDeclared(text).1 {
            return text
        }
        return minimization.minimize(text: text).0
    }

    static func isRevision(_ text: String) -> Bool {
        guard let number = Int(text), number >= 1 else { return false }
        return String(number) == text
    }

    /// Admitted is what a reference is checked against: the task it names belongs to the producer that states it and declared
    /// that output, in a checkpoint, an end or the very statement being written; and the version, when one is given, is an
    /// attempt of that task or one of its revisions.
    public struct Target: Sendable {
        public let outputs: Set<String>
        public let attempts: Set<String>
        public let revisions: Int

        public init(outputs: Set<String>, attempts: Set<String>, revisions: Int) {
            self.outputs   = outputs
            self.attempts  = attempts
            self.revisions = revisions
        }

        func admits(_ reference: TaskOutputReference, version: String?) -> Bool {
            guard outputs.contains(reference.output) else { return false }
            guard let version else { return true }
            if attempts.contains(version) { return true }
            return isRevision(version) && (Int(version) ?? 0) <= revisions
        }
    }

    /// The references of `values` to look up: the task ids their structural references name.
    public static func tasks(in references: [(String?, String?)]) -> Set<String> {
        Set(references.compactMap { $0.0.flatMap(TaskOutputReference.init)?.taskID })
    }

    /// A reference and its version as kept: unchanged when `targets` admits them, minimized as any text otherwise. The version
    /// of a reference that is not admitted is minimized too: it names nothing the archive vouches for.
    public static func admitting(reference: String?, version: String?, targets: [String: Target],
                                 by minimization: ValueMinimization = ValueMinimization()) -> (String?, String?) {
        guard let reference, let parsed = TaskOutputReference(reference) else { return (reference, version) }
        if targets[parsed.taskID]?.admits(parsed, version: version) == true { return (reference, version) }
        return (minimization.minimize(text: reference).0, version.map { minimization.minimize(text: $0).0 })
    }

    /// The values with each structural reference kept only when `targets` admits it.
    public static func admitting(_ values: [TaskValue], targets: [String: Target]) throws -> [TaskValue] {
        try values.map { value in
            let (reference, version) = admitting(reference: value.sourceRef, version: value.sourceVersion, targets: targets)
            guard reference != value.sourceRef || version != value.sourceVersion else { return value }
            return try TaskValue(name: value.name, role: value.role, kind: value.kind, content: value.content,
                                 sensitivity: value.sensitivity, source: value.source, sourceRef: reference, sourceVersion: version)
        }
    }

    /// The parameters with each structural reference kept only when `targets` admits it.
    public static func admitting(_ parameters: [ParameterStatement], targets: [String: Target]) throws -> [ParameterStatement] {
        try parameters.map { parameter in
            let (reference, version) = admitting(reference: parameter.sourceRef, version: parameter.sourceVersion, targets: targets)
            guard reference != parameter.sourceRef || version != parameter.sourceVersion else { return parameter }
            return try ParameterStatement(name: parameter.name, role: parameter.role, kind: parameter.kind, direction: parameter.direction,
                                          unit: parameter.unit, sensitivity: parameter.sensitivity, content: parameter.content,
                                          source: parameter.source, sourceRef: reference, sourceVersion: version,
                                          producedBy: parameter.producedBy)
        }
    }
}
