//
//  ProcedureInterpretation.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Foundation

/// ProcedureInterpretationContract is the versioned contract of what an agent says about a candidate:
/// the label and the declared outcome of the procedure, of each block and of each step, the parameters
/// with their role, kind, direction and episodic value with its source, and each use of a parameter in
/// an argument of a step, as a template over the argument's recorded text. The agent writes it in its
/// ordinary turn, through `memory_task interpret`, from the candidate the tool gave it at a checkpoint
/// or at the end; no second model and no person compiles it. The system decides the steps, their order
/// and their blocks, and checks every reference and every use against the calls; it does not decide
/// whether the agent understood the intent.
public enum ProcedureInterpretationContract {
    public static let version = 1

    /// The longest label kept, in UTF-8 bytes: a short sentence, refused rather than cut.
    public static let maximumLabelBytes = 512

    /// The most parameters or uses one interpretation states.
    public static let maximumItems = 512
}

/// PartReference names a part of a candidate: the procedure, a block by its index or a step by its
/// position, both from 0. The tool shows them from 1 (`b1`, step 1).
public enum PartReference: Sendable, Equatable, Hashable {
    case procedure
    case block(Int)
    case step(Int)
}

/// DeclaredPartOutcome is what the agent declared a part reached: completed, failed, not completed, or
/// nothing declared. A declaration is never a verification.
public enum DeclaredPartOutcome: String, Sendable, Equatable, Hashable, CaseIterable {
    case completed, failed
    case notCompleted = "not_completed"
    case notDeclared  = "not_declared"
}

/// PartStatement is the label and the declared outcome the agent gives one part. A missing label leaves
/// the part kept and unqualified; a missing outcome is taken from the part that contains it when that
/// one is declared completed, and is not declared otherwise.
public struct PartStatement: Sendable, Equatable {
    public let reference: PartReference
    public let label: String?
    public let outcome: DeclaredPartOutcome?

    public init(reference: PartReference, label: String?, outcome: DeclaredPartOutcome?) throws {
        if let label {
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProcedureError.invalid(.emptyText(field: "label"))
            }
            guard label.utf8.count <= ProcedureInterpretationContract.maximumLabelBytes else {
                throw ProcedureError.invalid(.tooLong(field: "label"))
            }
        }
        if outcome == .notDeclared { throw ProcedureError.invalid(.label("an outcome is completed, failed or not_completed")) }
        self.reference = reference
        self.label     = label
        self.outcome   = outcome
    }

    public static func == (lhs: PartStatement, rhs: PartStatement) -> Bool {
        lhs.reference == rhs.reference && EventFactText.same(lhs.label, rhs.label) && lhs.outcome == rhs.outcome
    }
}

/// ParameterStatement is one parameter as the agent describes it: a name unique in the interpretation,
/// its role in its own words, a base kind, a direction, a unit or format when it has one, whether it is a
/// secret, and the value it had in this attempt with its source. A value left out is taken from the
/// task's input of the same name, with that input's source; a secret's value is never kept. An output
/// names the part that produced it.
public struct ParameterStatement: Sendable, Equatable {
    public let name: String
    public let role: String
    public let kind: TaskValueKind
    public let direction: ParameterDirection
    public let unit: String?
    public let sensitivity: TaskValueSensitivity
    /// The value in this attempt, or nil to take the task's input of the same name.
    public let content: TaskValue.Content?
    public let source: TaskValueSource?
    public let sourceRef: String?
    public let sourceVersion: String?
    public let producedBy: PartReference?

    public init(name: String, role: String, kind: TaskValueKind, direction: ParameterDirection = .input, unit: String? = nil,
                sensitivity: TaskValueSensitivity = .ordinary, content: TaskValue.Content? = nil, source: TaskValueSource? = nil,
                sourceRef: String? = nil, sourceVersion: String? = nil, producedBy: PartReference? = nil) throws {
        func refuse(_ problem: String) -> ProcedureError { .invalid(.parameter(problem)) }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw refuse("a parameter's name is letters, digits, _ and -")
        }
        guard !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw refuse("\(name) needs a role") }
        for text in [name, role, unit, sourceRef, sourceVersion].compactMap({ $0 }) where text.utf8.count > TaskContextContract.maximumTextBytes {
            throw ProcedureError.invalid(.tooLong(field: name))
        }
        guard kind != .missing else { throw refuse("\(name) has a kind, missing is a value") }
        if sensitivity == .secret, case .text? = content { throw refuse("a secret's value is never kept: \(name)") }
        if direction == .output, producedBy == nil { throw refuse("the output \(name) names the part that produced it") }
        if direction != .output, producedBy != nil { throw refuse("only an output is produced by a part: \(name)") }
        if source == .previousOutput, sourceRef == nil { throw refuse("a previous output names its source: \(name)") }
        self.name          = name
        self.role          = role
        self.kind          = kind
        self.direction     = direction
        self.unit          = unit
        self.sensitivity   = sensitivity
        self.content       = content
        self.source        = source
        self.sourceRef     = sourceRef
        self.sourceVersion = sourceVersion
        self.producedBy    = producedBy
    }

    public static func == (lhs: ParameterStatement, rhs: ParameterStatement) -> Bool {
        let sameContent: Bool
        switch (lhs.content, rhs.content) {
            case (nil, nil): sameContent = true
            case (.text(let a)?, .text(let b)?): sameContent = a.utf8.elementsEqual(b.utf8)
            case (.missing?, .missing?), (.withheld?, .withheld?): sameContent = true
            default: sameContent = false
        }
        return lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.role.utf8.elementsEqual(rhs.role.utf8) && lhs.kind == rhs.kind
            && lhs.direction == rhs.direction && EventFactText.same(lhs.unit, rhs.unit) && lhs.sensitivity == rhs.sensitivity
            && sameContent && lhs.source == rhs.source && EventFactText.same(lhs.sourceRef, rhs.sourceRef)
            && EventFactText.same(lhs.sourceVersion, rhs.sourceVersion) && lhs.producedBy == rhs.producedBy
    }
}

/// UsePiece is one piece of a use's template: a literal text or a parameter by its name.
public enum UsePiece: Sendable, Equatable {
    case literal(String)
    case parameter(String)

    public static func == (lhs: UsePiece, rhs: UsePiece) -> Bool {
        switch (lhs, rhs) {
            case (.literal(let a), .literal(let b)), (.parameter(let a), .parameter(let b)): a.utf8.elementsEqual(b.utf8)
            default: false
        }
    }

    /// The pieces of a template: `{name}` is a parameter, `{{` and `}}` are literal braces, everything
    /// else is literal; adjacent literals are one piece. A brace that opens no well formed parameter is
    /// refused.
    public static func parse(_ template: String) throws -> [UsePiece] {
        func refuse(_ problem: String) -> ProcedureError { .invalid(.template(problem)) }
        var pieces: [UsePiece] = []
        var literal = ""
        let characters = Array(template)
        var index = 0
        func flush() {
            if !literal.isEmpty { pieces.append(.literal(literal)) }
            literal = ""
        }
        while index < characters.count {
            let character = characters[index]
            if character == "{" {
                if index + 1 < characters.count, characters[index + 1] == "{" {
                    literal.append("{")
                    index += 2
                    continue
                }
                guard let close = characters[(index + 1)...].firstIndex(of: "}") else { throw refuse("an unclosed {") }
                let name = String(characters[(index + 1)..<close])
                guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                    throw refuse("{\(name)} is not a parameter's name")
                }
                flush()
                pieces.append(.parameter(name))
                index = close + 1
            } else if character == "}" {
                guard index + 1 < characters.count, characters[index + 1] == "}" else { throw refuse("a lone }") }
                literal.append("}")
                index += 2
            } else {
                literal.append(character)
                index += 1
            }
        }
        flush()
        guard !pieces.isEmpty else { throw refuse("an empty template") }
        guard pieces.contains(where: { if case .parameter = $0 { true } else { false } }) else {
            throw refuse("a template without a parameter")
        }
        return pieces
    }
}

/// UseStatement is one use the agent states: the step, the argument by its name and position in the
/// call, and the template of the argument's text in the call's own terms, such as
/// `{output_name}.{output_extension}`. Only the stated arguments are parameters: no text is replaced
/// anywhere else because it is equal, so a file named Export and the Export command keep their roles.
public struct UseStatement: Sendable, Equatable {
    public let stepPosition: Int
    public let argumentName: String
    public let argumentPosition: Int
    public let pieces: [UsePiece]

    public init(stepPosition: Int, argumentName: String, argumentPosition: Int = 0, pieces: [UsePiece]) throws {
        guard stepPosition >= 0, argumentPosition >= 0 else { throw ProcedureError.invalid(.outOfRange(field: "use")) }
        guard !argumentName.isEmpty else { throw ProcedureError.invalid(.emptyText(field: "argument")) }
        guard !pieces.isEmpty else { throw ProcedureError.invalid(.template("an empty template")) }
        self.stepPosition     = stepPosition
        self.argumentName     = argumentName
        self.argumentPosition = argumentPosition
        self.pieces           = pieces
    }

    /// The names of the parameters the template uses, in order, once each.
    public var parameterNames: [String] {
        var names: [String] = []
        for case .parameter(let name) in pieces where !names.contains(name) { names.append(name) }
        return names
    }
}

/// ProcedureInterpretation is one interpretation as the agent offers it, before the store gives it a
/// revision: the candidate it is about, the revision it means when it names one (nil is the next), the
/// statements of parts, parameters and uses, and the version it is a variant of with the position of
/// the first step that differs. Texts are already minimized by the producer.
public struct ProcedureInterpretation: Sendable, Equatable {
    public let candidateID: String
    public let revision: Int?
    public let parts: [PartStatement]
    public let parameters: [ParameterStatement]
    public let uses: [UseStatement]
    public let variantOf: String?
    public let divergencePosition: Int?

    public init(candidateID: String, revision: Int? = nil, parts: [PartStatement], parameters: [ParameterStatement] = [],
                uses: [UseStatement] = [], variantOf: String? = nil, divergencePosition: Int? = nil) throws {
        func refuse(_ invalidity: ProcedureError.Invalidity) -> ProcedureError { .invalid(invalidity) }
        guard !candidateID.isEmpty else { throw refuse(.emptyText(field: "candidate")) }
        if let revision, revision < 1 { throw refuse(.outOfRange(field: "revision")) }
        guard parameters.count <= ProcedureInterpretationContract.maximumItems,
              uses.count <= ProcedureInterpretationContract.maximumItems,
              parts.count <= ProcedureInterpretationContract.maximumItems * 2 else { throw refuse(.tooMany(field: "items")) }
        guard Set(parts.map(\.reference)).count == parts.count else { throw refuse(.duplicate(field: "parts")) }
        guard let procedure = parts.first(where: { $0.reference == .procedure }), procedure.label != nil else {
            throw refuse(.label("the procedure needs a label"))
        }
        var names: Set<[UInt8]> = []
        for parameter in parameters where !names.insert(Array(parameter.name.utf8)).inserted {
            throw refuse(.duplicate(field: "parameter \(parameter.name)"))
        }
        var used: Set<String> = []
        for use in uses where !used.insert("\(use.stepPosition)#\(use.argumentName)#\(use.argumentPosition)").inserted {
            throw refuse(.duplicate(field: "use of \(use.argumentName) at step \(use.stepPosition + 1)"))
        }
        guard (variantOf == nil) == (divergencePosition == nil) else { throw refuse(.outOfRange(field: "variant")) }
        if let divergencePosition, divergencePosition < 0 { throw refuse(.outOfRange(field: "divergence")) }
        if let variantOf, variantOf.isEmpty { throw refuse(.emptyText(field: "variant_of")) }
        self.candidateID        = candidateID
        self.revision           = revision
        self.parts              = parts
        self.parameters         = parameters
        self.uses               = uses
        self.variantOf          = variantOf
        self.divergencePosition = divergencePosition
    }

    /// The statement of a part, if the agent made one.
    public func statement(of reference: PartReference) -> PartStatement? {
        parts.first { $0.reference == reference }
    }

    /// The canonical rendering of what the interpretation states, revision apart: the same statements
    /// in any order of parts render alike. Its digest tells a repeated offer from another content.
    public var canonical: String {
        func field(_ text: String?) -> String { CanonicalText.field(text) }
        func reference(_ reference: PartReference?) -> String {
            switch reference {
                case nil: "~"
                case .procedure?: "p"
                case .block(let index)?: "b\(index)"
                case .step(let position)?: "s\(position)"
            }
        }
        var lines = ["candidate " + field(candidateID), "variant " + field(variantOf) + " " + field(divergencePosition.map(String.init))]
        for part in parts.sorted(by: { reference($0.reference) < reference($1.reference) }) {
            lines.append("part \(reference(part.reference)) " + field(part.label) + " " + field(part.outcome?.rawValue))
        }
        for parameter in parameters {
            let content: String = switch parameter.content {
                case nil: "~"
                case .text(let text)?: "text " + field(text)
                case .missing?: "missing"
                case .withheld?: "withheld"
            }
            lines.append(["parameter", field(parameter.name), field(parameter.role), parameter.kind.rawValue,
                          parameter.direction.rawValue, field(parameter.unit), parameter.sensitivity.rawValue, content,
                          field(parameter.source?.rawValue), field(parameter.sourceRef), field(parameter.sourceVersion),
                          reference(parameter.producedBy)].joined(separator: " "))
        }
        for use in uses {
            let pieces = use.pieces.map { piece -> String in
                switch piece {
                    case .literal(let text): "l" + field(text)
                    case .parameter(let name): "p" + field(name)
                }
            }.joined(separator: ",")
            lines.append("use \(use.stepPosition) " + field(use.argumentName) + " \(use.argumentPosition) " + pieces)
        }
        return lines.joined(separator: "\n")
    }

    /// A digest of the canonical rendering, kept with the stored interpretation.
    public var digest: String { "\(canonical.utf8.count)-\(StructuralDigest.fnv1a(canonical))" }
}
