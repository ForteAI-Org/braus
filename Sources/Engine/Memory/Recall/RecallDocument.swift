//
//  RecallDocument.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation

/// RecallDocument is the canonical text of an offered part for retrieval: what it is for and what it works on,
/// from the definition only. A part's own label, the application it runs in, for a procedure or a subprocedure
/// the labels of what it contains in order, and the roles of the parameters it reads and produces. No argument
/// of an operation, no value of an episode, no chat and no trace enter it: the labels and roles are the agent's
/// generalized statements, the operations are reached through the part's identity once it is found. The same
/// part in the same format always gives the same text, so its vector is computed once and shared with any part
/// whose text is exactly the same.
public enum RecallDocument {

    /// Format is how the text is composed. A new format is a new generation of the index.
    public enum Format: String, Sendable, Equatable, Hashable, CaseIterable {
        /// The part's label, application, contents and parameters' roles.
        case labelled  = "recall-document-1"
        /// The same, and for a step the label of the part that contains it, as its context.
        case contextual = "recall-document-1c"
    }

    /// Document is one part's text with what an entry keeps of it.
    public struct Document: Sendable, Equatable {
        public let partID: String
        public let routeID: String
        public let kind: PartKind
        public let text: String
    }

    /// The documents of a version's parts that `offered` names, in the version's part order.
    public static func documents(of stored: StoredProcedureVersion, offered: Set<String>, format: Format) -> [Document] {
        let version = stored.version
        let parts = version.parts
        let byID = Dictionary(uniqueKeysWithValues: parts.map { ($0.partID, $0) })
        let details = Dictionary(uniqueKeysWithValues: version.parameterDetails.map { ($0.parameterID, $0) })
        return parts.compactMap { part -> Document? in
            guard offered.contains(part.partID), let label = part.label else { return nil }
            var sentences = [Self.sentence(label)]
            if let bundle = part.bundleID ?? version.definition.steps[part.firstPosition].bundleID {
                sentences.append("In \(applicationName(bundle)).")
            }
            let children = parts.filter { $0.parentPartID == part.partID }.sorted { $0.firstPosition < $1.firstPosition }
            let contained = children.compactMap(\.label)
            if part.kind != .step, !contained.isEmpty {
                let word = children.first?.kind == .subprocedure ? "Parts" : "Steps"
                sentences.append("\(word): " + contained.map(Self.trimmed).joined(separator: "; ") + ".")
            }
            if format == .contextual, part.kind == .step, let parent = part.parentPartID.flatMap({ byID[$0] })?.label {
                sentences.append("Within: \(Self.trimmed(parent)).")
            }
            let items = stored.contract.filter { $0.partID == part.partID }
            let inputs = items.filter { $0.kind == .input }.compactMap { $0.parameterID.flatMap { details[$0]?.role } }
            let outputs = items.filter { $0.kind == .output }.compactMap { $0.parameterID.flatMap { details[$0]?.role } }
            if !inputs.isEmpty { sentences.append("Needs: " + inputs.map(Self.trimmed).joined(separator: "; ") + ".") }
            if !outputs.isEmpty { sentences.append("Produces: " + outputs.map(Self.trimmed).joined(separator: "; ") + ".") }
            return Document(partID: part.partID, routeID: version.routeID, kind: part.kind, text: sentences.joined(separator: " "))
        }
    }

    /// The name a delivery gives an application, which the agent opens it by: a web identity (`web:<host>`, Braus's
    /// browser engine) whole, since it is a route of its own and its last component names nothing (M08); any other, its
    /// `applicationName`. The index, the constraints and the selector keep `applicationName`.
    public static func deliveredName(_ bundleID: String) -> String {
        bundleID.lowercased().hasPrefix("web:") ? bundleID : applicationName(bundleID)
    }

    /// The name of an application from its bundle id: its last component, which is how people call most of them.
    public static func applicationName(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        guard let first = last.first else { return bundleID }
        return first.uppercased() + last.dropFirst()
    }

    private static func trimmed(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == "." || last == ";" { text.removeLast() }
        return text
    }

    private static func sentence(_ text: String) -> String { trimmed(text) + "." }
}
