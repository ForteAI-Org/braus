//
//  ProcedureVersion.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

/// PartKind is a part's level: the procedure, a subprocedure (a block of consecutive operations on one
/// application), or a step (one operation).
public enum PartKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case procedure, subprocedure, step

    /// A coarser kind contains a finer one only.
    public var rank: Int {
        switch self {
            case .procedure   : 0
            case .subprocedure: 1
            case .step        : 2
        }
    }
}

/// ProcedurePart is one part of a version: its id, its kind and parent, the ordered interval of the
/// version's steps it covers, the definition step a step part is, the application of a block or a step,
/// the agent's label and the outcome it declared. A procedure of one block has no subprocedure part of
/// its own: the procedure is that block, and is not duplicated to be identifiable.
public struct ProcedurePart: Sendable, Equatable {
    public let partID: String
    public let routeID: String
    public let kind: PartKind
    public let parentPartID: String?
    public let firstPosition: Int
    public let lastPosition: Int
    public let stepID: String?
    public let bundleID: String?
    public let label: String?
    public let declaredOutcome: DeclaredPartOutcome

    public init(partID: String, routeID: String, kind: PartKind, parentPartID: String?, firstPosition: Int, lastPosition: Int,
                stepID: String?, bundleID: String?, label: String?, declaredOutcome: DeclaredPartOutcome) throws {
        func refuse(_ invalidity: ProcedureError.Invalidity) -> ProcedureError { .invalid(invalidity) }
        guard !partID.isEmpty, !routeID.isEmpty else { throw refuse(.emptyText(field: "part")) }
        guard firstPosition >= 0, lastPosition >= firstPosition else { throw refuse(.positions(of: partID)) }
        guard (kind == .procedure) == (parentPartID == nil) else { throw refuse(.positions(of: "parent of \(partID)")) }
        guard (kind == .step) == (stepID != nil), kind != .step || firstPosition == lastPosition else {
            throw refuse(.positions(of: "step of \(partID)"))
        }
        if kind == .procedure, label == nil { throw refuse(.label("the procedure needs a label")) }
        if let label, label.isEmpty { throw refuse(.emptyText(field: "label")) }
        self.partID          = partID
        self.routeID         = routeID
        self.kind            = kind
        self.parentPartID    = parentPartID
        self.firstPosition   = firstPosition
        self.lastPosition    = lastPosition
        self.stepID          = stepID
        self.bundleID        = bundleID
        self.label           = label
        self.declaredOutcome = declaredOutcome
    }

    public static func == (lhs: ProcedurePart, rhs: ProcedurePart) -> Bool {
        lhs.partID.utf8.elementsEqual(rhs.partID.utf8) && lhs.routeID.utf8.elementsEqual(rhs.routeID.utf8) && lhs.kind == rhs.kind
            && EventFactText.same(lhs.parentPartID, rhs.parentPartID) && lhs.firstPosition == rhs.firstPosition
            && lhs.lastPosition == rhs.lastPosition && EventFactText.same(lhs.stepID, rhs.stepID)
            && EventFactText.same(lhs.bundleID, rhs.bundleID) && EventFactText.same(lhs.label, rhs.label)
            && lhs.declaredOutcome == rhs.declaredOutcome
    }

    /// Whether the part covers the step at `position`.
    public func covers(_ position: Int) -> Bool { firstPosition <= position && position <= lastPosition }
}

/// PartContractItem is one item of a part's contract: a parameter it reads (propagated from its steps'
/// uses) or produces, the application it runs in, or the functional state its first operation started
/// from (a structural scene, or nil stated when not known). A reader rebuilds what a part needs before
/// it is reused from these, without its parent.
public struct PartContractItem: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        case input, output, application
        case entryState = "entry_state"
    }

    public let partID: String
    public let position: Int
    public let kind: Kind
    public let parameterID: String?
    public let bundleID: String?
    public let sceneID: String?

    public init(partID: String, position: Int, kind: Kind, parameterID: String? = nil, bundleID: String? = nil,
                sceneID: String? = nil) throws {
        func refuse(_ problem: String) -> ProcedureError { .invalid(.positions(of: "contract of \(partID): \(problem)")) }
        switch kind {
            case .input, .output:
                guard parameterID != nil, bundleID == nil, sceneID == nil else { throw refuse("a parameter only") }
            case .application:
                guard parameterID == nil, bundleID != nil, sceneID == nil else { throw refuse("an application only") }
            case .entryState:
                guard parameterID == nil, bundleID != nil else { throw refuse("an application and a state or none") }
        }
        self.partID      = partID
        self.position    = position
        self.kind        = kind
        self.parameterID = parameterID
        self.bundleID    = bundleID
        self.sceneID     = sceneID
    }

    public static func == (lhs: PartContractItem, rhs: PartContractItem) -> Bool {
        lhs.partID.utf8.elementsEqual(rhs.partID.utf8) && lhs.position == rhs.position && lhs.kind == rhs.kind
            && EventFactText.same(lhs.parameterID, rhs.parameterID) && EventFactText.same(lhs.bundleID, rhs.bundleID)
            && EventFactText.same(lhs.sceneID, rhs.sceneID)
    }
}

/// ParameterDetail is what a version keeps of a parameter beside its Route row: the role the agent gave,
/// the base kind, the unit or format, whether it is a secret, and the part that produces it when it is
/// an output. Never its value.
public struct ParameterDetail: Sendable, Equatable {
    public let parameterID: String
    public let role: String
    public let kind: TaskValueKind
    public let unit: String?
    public let sensitivity: TaskValueSensitivity
    public let producedByPartID: String?

    public init(parameterID: String, role: String, kind: TaskValueKind, unit: String?, sensitivity: TaskValueSensitivity,
                producedByPartID: String?) {
        self.parameterID      = parameterID
        self.role             = role
        self.kind             = kind
        self.unit             = unit
        self.sensitivity      = sensitivity
        self.producedByPartID = producedByPartID
    }

    public static func == (lhs: ParameterDetail, rhs: ParameterDetail) -> Bool {
        lhs.parameterID.utf8.elementsEqual(rhs.parameterID.utf8) && lhs.role.utf8.elementsEqual(rhs.role.utf8)
            && lhs.kind == rhs.kind && EventFactText.same(lhs.unit, rhs.unit) && lhs.sensitivity == rhs.sensitivity
            && EventFactText.same(lhs.producedByPartID, rhs.producedByPartID)
    }
}

/// ParameterBinding is the value a parameter had in one attempt and its source: an episodic fact kept
/// beside the definition, never a default of it. A secret's binding is withheld.
public struct ParameterBinding: Sendable, Equatable {
    public let parameterID: String
    public let attemptID: String
    public let content: TaskValue.Content
    public let source: TaskValueSource
    public let sourceRef: String?
    public let sourceVersion: String?

    public init(parameterID: String, attemptID: String, content: TaskValue.Content, source: TaskValueSource,
                sourceRef: String?, sourceVersion: String?) {
        self.parameterID   = parameterID
        self.attemptID     = attemptID
        self.content       = content
        self.source        = source
        self.sourceRef     = sourceRef
        self.sourceVersion = sourceVersion
    }

    public static func == (lhs: ParameterBinding, rhs: ParameterBinding) -> Bool {
        let content: Bool = switch (lhs.content, rhs.content) {
            case (.text(let a), .text(let b)): a.utf8.elementsEqual(b.utf8)
            case (.missing, .missing), (.withheld, .withheld): true
            default: false
        }
        return content && lhs.parameterID.utf8.elementsEqual(rhs.parameterID.utf8) && lhs.attemptID.utf8.elementsEqual(rhs.attemptID.utf8)
            && lhs.source == rhs.source && EventFactText.same(lhs.sourceRef, rhs.sourceRef)
            && EventFactText.same(lhs.sourceVersion, rhs.sourceVersion)
    }
}

/// InterpretationFinding is a use the system could not confirm against the call it names: the template
/// with the parameters' values does not give the argument as recorded (`useMismatch`, a contradiction
/// that stops every part containing the step), or a value it needs is not known (`unverifiableUse`). The
/// argument stays as recorded in the definition.
public struct InterpretationFinding: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable, Hashable, CaseIterable {
        case useMismatch     = "use_mismatch"
        case unverifiableUse = "unverifiable_use"
    }

    public let kind: Kind
    public let stepPosition: Int
    public let argumentName: String
    public let argumentPosition: Int

    public init(kind: Kind, stepPosition: Int, argumentName: String, argumentPosition: Int) {
        self.kind             = kind
        self.stepPosition     = stepPosition
        self.argumentName     = argumentName
        self.argumentPosition = argumentPosition
    }
}

/// InterpretationState is where the attempt stood when the interpretation was recorded: running (at a
/// checkpoint), ended (after its end), or interrupted (a later interpretation of an attempt that never
/// ended, which may give labels and parameters and never a completion).
public enum InterpretationState: String, Sendable, Equatable, Hashable, CaseIterable {
    case running, ended, interrupted
}

/// ProcedureVersion is a version built from one interpretation of one candidate: the Route definition
/// (one definition step per candidate step, each of one operation whose arguments are the call's as
/// recorded, a parameter or a template where a use was confirmed), its parts, its parameters' details,
/// the attempt's bindings, the findings, and the occurrence each definition step stands for.
public struct ProcedureVersion: Sendable {
    public let routeID: String
    public let interpretationID: String
    public let revision: Int
    public let candidateID: String
    public let taskID: String
    public let attemptID: String
    public let contractVersion: Int
    public let variantOf: String?
    public let divergencePosition: Int?
    public let builtAtMS: Int64
    public let definition: RouteDefinition
    public let parts: [ProcedurePart]
    public let parameterDetails: [ParameterDetail]
    public let bindings: [ParameterBinding]
    public let findings: [InterpretationFinding]
    /// The occurrence each definition step stands for, by the step's id.
    public let stepOccurrences: [(stepID: String, stepOccurrenceID: String)]
    /// The positions of steps that keep a withheld value as a literal: a secret argument no secret
    /// parameter took. Such a step can be read and never reused.
    public let withheldLiteralSteps: Set<Int>

    public init(routeID: String, interpretationID: String, revision: Int, candidateID: String, taskID: String, attemptID: String,
                contractVersion: Int, variantOf: String?, divergencePosition: Int?, builtAtMS: Int64, definition: RouteDefinition,
                parts: [ProcedurePart], parameterDetails: [ParameterDetail], bindings: [ParameterBinding],
                findings: [InterpretationFinding], stepOccurrences: [(stepID: String, stepOccurrenceID: String)],
                withheldLiteralSteps: Set<Int>) {
        self.routeID              = routeID
        self.interpretationID     = interpretationID
        self.revision             = revision
        self.candidateID          = candidateID
        self.taskID               = taskID
        self.attemptID            = attemptID
        self.contractVersion      = contractVersion
        self.variantOf            = variantOf
        self.divergencePosition   = divergencePosition
        self.builtAtMS            = builtAtMS
        self.definition           = definition
        self.parts                = parts
        self.parameterDetails     = parameterDetails
        self.bindings             = bindings
        self.findings             = findings
        self.stepOccurrences      = stepOccurrences
        self.withheldLiteralSteps = withheldLiteralSteps
    }
}

/// ProcedureAssembly builds a version from a candidate, an interpretation and the calls' recorded facts:
/// a pure function, the same inputs giving the same rows, so a rebuild is recognized as the stored one.
/// It refuses what is structurally wrong (a part, a step, an argument or a parameter the candidate or
/// the calls do not have, a parameter used with two types, an output used as an argument), keeps what a
/// call contradicts as a finding, and decides nothing about qualification.
public enum ProcedureAssembly {

    /// StepFacts is what the assembly reads of a step's call: the request as the archive kept it (its
    /// withheld texts already the marker) and which of its arguments were withheld.
    public struct StepFacts: Sendable {
        public let position: Int
        public let request: AgentCallRequest
        /// The withheld arguments, as `name#position`.
        public let withheldArguments: Set<String>

        public init(position: Int, request: AgentCallRequest, withheldArguments: Set<String>) {
            self.position          = position
            self.request           = request
            self.withheldArguments = withheldArguments
        }
    }

    /// The ids a version's rows take, from its candidate and revision.
    public static func interpretationID(candidateID: String, revision: Int) -> String { "\(candidateID)/interpretation-\(revision)" }
    public static func routeID(candidateID: String, revision: Int) -> String { "\(candidateID)/version-\(revision)" }

    /// Builds the version. `taskInputs` are the inputs of the task's current revision, which a parameter
    /// stated without a value takes by name.
    public static func assemble(
        candidate     : ProcedureCandidate,
        interpretation: ProcedureInterpretation,
        revision      : Int,
        steps         : [StepFacts],
        taskInputs    : [TaskValue],
        supersedes    : String?,
        builtAtMS     : Int64
    ) throws -> ProcedureVersion {
        func unknown(_ what: String) -> ProcedureError { .unknownReference(what) }
        guard steps.count == candidate.steps.count, steps.enumerated().allSatisfy({ $0.offset == $0.element.position }) else {
            throw ProcedureError.invalid(.positions(of: "facts"))
        }
        let routeID = Self.routeID(candidateID: candidate.candidateID, revision: revision)
        let blocks  = candidate.blocks
        for part in interpretation.parts {
            switch part.reference {
                case .procedure: break
                case .block(let index): if !blocks.indices.contains(index) { throw unknown("block b\(index + 1)") }
                case .step(let position): if !candidate.steps.indices.contains(position) { throw unknown("step \(position + 1)") }
            }
        }
        if let divergence = interpretation.divergencePosition, divergence > candidate.steps.count {
            throw unknown("divergence position \(divergence + 1)")
        }

        // Part ids and declared outcomes, the coarser first so a finer part may inherit.
        let procedureID = "\(routeID)/procedure"
        func blockID(_ index: Int) -> String { blocks.count > 1 ? "\(routeID)/block-\(index)" : procedureID }
        func stepPartID(_ position: Int) -> String { "\(routeID)/step-\(position)" }
        func partID(_ reference: PartReference) -> String {
            switch reference {
                case .procedure: procedureID
                case .block(let index): blockID(index)
                case .step(let position): stepPartID(position)
            }
        }
        // A part keeps the outcome the agent stated for it, or none: what it inherits from the part that
        // contains it, or the procedure from the attempt's end, is decided when it is qualified, from the
        // facts then (`QualificationPolicy.effectiveOutcome`).
        let procedureStatement = interpretation.statement(of: .procedure)

        // Parameters: ids by statement order, values taken from the task's inputs by name when not given.
        var parameterIDs: [String: String] = [:]
        var statements: [String: ParameterStatement] = [:]
        for (index, parameter) in interpretation.parameters.enumerated() {
            parameterIDs[parameter.name] = "\(routeID)/parameter-\(index)"
            statements[parameter.name]   = parameter
        }
        var bindings: [String: ParameterBinding] = [:]
        var values: [String: String] = [:]
        for parameter in interpretation.parameters {
            guard let id = parameterIDs[parameter.name] else { continue }
            let input = taskInputs.first { $0.name.utf8.elementsEqual(parameter.name.utf8) }
            let content: TaskValue.Content
            let source: TaskValueSource
            var reference = parameter.sourceRef, version = parameter.sourceVersion
            if let given = parameter.content {
                content = parameter.sensitivity == .secret ? .withheld : given
                source  = parameter.source ?? .unknown
            } else if let input {
                content = parameter.sensitivity == .secret || input.sensitivity == .secret ? .withheld : input.content
                source  = parameter.source ?? input.source
                reference = reference ?? input.sourceRef
                version   = version ?? input.sourceVersion
            } else {
                content = parameter.sensitivity == .secret ? .withheld : .missing
                source  = parameter.source ?? .unknown
            }
            if source == .previousOutput, reference == nil { throw ProcedureError.invalid(.parameter("\(parameter.name) names no previous output")) }
            bindings[id] = ParameterBinding(parameterID: id, attemptID: candidate.attemptID, content: content, source: source,
                                            sourceRef: reference, sourceVersion: version)
            if case .text(let text) = content { values[parameter.name] = text }
        }

        // Uses: each checked against the call's argument as recorded; a confirmed use becomes the value.
        var types: [String: ParameterValueType] = [:]
        var applied: [String: OperationValue] = [:]
        var findings: [InterpretationFinding] = []
        for use in interpretation.uses {
            guard candidate.steps.indices.contains(use.stepPosition) else { throw unknown("step \(use.stepPosition + 1)") }
            let request = steps[use.stepPosition].request
            guard let spec = AgentCallArguments.specs(of: request.tool).first(where: { $0.name.utf8.elementsEqual(use.argumentName.utf8) }) else {
                throw unknown("argument \(use.argumentName) of \(request.tool.rawValue) at step \(use.stepPosition + 1)")
            }
            guard let recorded = request.arguments.first(where: {
                $0.name.utf8.elementsEqual(use.argumentName.utf8) && $0.position == use.argumentPosition
            }) else {
                throw unknown("argument \(use.argumentName)#\(use.argumentPosition) at step \(use.stepPosition + 1)")
            }
            for name in use.parameterNames {
                guard let parameter = statements[name] else { throw unknown("parameter \(name)") }
                guard parameter.direction != .output else {
                    throw ProcedureError.invalid(.parameter("the output \(name) is not an argument"))
                }
            }
            let whole: Bool = { if use.pieces.count == 1, case .parameter = use.pieces[0] { return true } else { return false } }()
            let type: ParameterValueType = whole ? ParameterValueType(spec.kind) : .text
            if !whole, spec.kind != .text { throw ProcedureError.invalid(.template("\(use.argumentName) is not a text")) }
            for name in use.parameterNames {
                if let known = types[name], known != type {
                    throw ProcedureError.invalid(.parameter("\(name) is used as \(known.rawValue) and as \(type.rawValue)"))
                }
                types[name] = type
            }
            let key = "\(use.stepPosition)#\(use.argumentName)#\(use.argumentPosition)"
            func finding(_ kind: InterpretationFinding.Kind) {
                findings.append(InterpretationFinding(kind: kind, stepPosition: use.stepPosition, argumentName: use.argumentName,
                                                      argumentPosition: use.argumentPosition))
            }
            let secrets = use.parameterNames.filter { statements[$0]?.sensitivity == .secret }
            let withheld = steps[use.stepPosition].withheldArguments.contains("\(use.argumentName)#\(use.argumentPosition)")
            if withheld || !secrets.isEmpty {
                // A withheld value is taken only by a secret parameter, whole: nothing else can be checked.
                guard withheld, whole, secrets.count == 1 else { finding(.useMismatch); continue }
            } else {
                guard use.parameterNames.allSatisfy({ values[$0] != nil }) else { finding(.unverifiableUse); continue }
                var rendered = ""
                for piece in use.pieces {
                    switch piece {
                        case .literal(let text): rendered += text
                        case .parameter(let name): rendered += values[name] ?? ""
                    }
                }
                let matches: Bool = switch recorded.value {
                    case .text(let text): rendered.utf8.elementsEqual(text.utf8)
                    default: whole && recorded.value.isSpelled(by: rendered)
                }
                guard matches else { finding(.useMismatch); continue }
            }
            if whole, case .parameter(let name) = use.pieces[0], let id = parameterIDs[name] {
                applied[key] = .parameter(id)
            } else {
                applied[key] = .template(use.pieces.map { piece in
                    switch piece {
                        case .literal(let text): .literal(text)
                        case .parameter(let name): .parameter(parameterIDs[name] ?? name)
                    }
                })
            }
        }

        // The definition: one step per candidate step, of one operation.
        var definitionSteps: [ProcedureStep] = []
        var occurrences: [(stepID: String, stepOccurrenceID: String)] = []
        var withheldLiterals: Set<Int> = []
        for step in candidate.steps {
            let facts   = steps[step.position]
            let stepID  = "\(routeID)/route-step-\(step.position)"
            let label   = interpretation.statement(of: .step(step.position))?.label
            var arguments: [OperationArgument] = []
            for argument in facts.request.arguments {
                let key = "\(step.position)#\(argument.name)#\(argument.position)"
                if let value = applied[key] {
                    arguments.append(OperationArgument(name: argument.name, position: argument.position, value: value))
                    continue
                }
                if facts.withheldArguments.contains("\(argument.name)#\(argument.position)") { withheldLiterals.insert(step.position) }
                arguments.append(OperationArgument(name: argument.name, position: argument.position, value: .literal(argument.value)))
            }
            definitionSteps.append(ProcedureStep(
                stepID    : stepID,
                position  : step.position,
                goalText  : label ?? "unlabelled \(facts.request.tool.rawValue) operation",
                bundleID  : step.bundleID,
                operations: [StepOperation(operationID: "\(routeID)/operation-\(step.position)", position: 0,
                                           tool: facts.request.tool, arguments: arguments)]
            ))
            occurrences.append((stepID, step.stepOccurrenceID))
        }
        let parameters = interpretation.parameters.compactMap { parameter -> RouteParameter? in
            guard let id = parameterIDs[parameter.name] else { return nil }
            let type = types[parameter.name] ?? {
                switch parameter.kind {
                    case .number: ParameterValueType.real
                    case .boolean: .boolean
                    default: .text
                }
            }()
            let used = types[parameter.name] != nil
            return RouteParameter(parameterID: id, name: parameter.name, direction: parameter.direction, valueType: type,
                                  isRequired: used)
        }
        let definition = RouteDefinition(
            routeID          : routeID,
            name             : procedureStatement?.label ?? "",
            supersedesRouteID: supersedes,
            createdAtMS      : builtAtMS,
            parameters       : parameters,
            steps            : definitionSteps
        )
        do {
            try definition.validate()
        } catch RouteError.invalidDefinition(let invalidity) {
            throw ProcedureError.invalid(.parameter("the definition is not valid: \(invalidity)"))
        }

        // Parts: the procedure, a subprocedure per block when there are several, a step per step.
        var parts: [ProcedurePart] = []
        let applications = Set(candidate.steps.map { $0.bundleID ?? "" })
        parts.append(try ProcedurePart(
            partID: procedureID, routeID: routeID, kind: .procedure, parentPartID: nil, firstPosition: 0,
            lastPosition: candidate.steps.count - 1, stepID: nil,
            bundleID: applications.count == 1 ? candidate.steps[0].bundleID : nil,
            label: procedureStatement?.label, declaredOutcome: procedureStatement?.outcome ?? .notDeclared
        ))
        if blocks.count > 1 {
            for block in blocks {
                parts.append(try ProcedurePart(
                    partID: blockID(block.index), routeID: routeID, kind: .subprocedure, parentPartID: procedureID,
                    firstPosition: block.firstPosition, lastPosition: block.lastPosition, stepID: nil, bundleID: block.bundleID,
                    label: interpretation.statement(of: .block(block.index))?.label,
                    declaredOutcome: interpretation.statement(of: .block(block.index))?.outcome ?? .notDeclared
                ))
            }
        }
        for step in candidate.steps {
            let statement = interpretation.statement(of: .step(step.position))
            parts.append(try ProcedurePart(
                partID: stepPartID(step.position), routeID: routeID, kind: .step, parentPartID: blockID(step.blockIndex),
                firstPosition: step.position, lastPosition: step.position, stepID: definitionSteps[step.position].stepID,
                bundleID: step.bundleID, label: statement?.label, declaredOutcome: statement?.outcome ?? .notDeclared
            ))
        }
        let details = interpretation.parameters.compactMap { parameter -> ParameterDetail? in
            guard let id = parameterIDs[parameter.name] else { return nil }
            return ParameterDetail(parameterID: id, role: parameter.role, kind: parameter.kind, unit: parameter.unit,
                                   sensitivity: parameter.sensitivity, producedByPartID: parameter.producedBy.map(partID))
        }
        return ProcedureVersion(
            routeID           : routeID,
            interpretationID  : interpretationID(candidateID: candidate.candidateID, revision: revision),
            revision          : revision,
            candidateID       : candidate.candidateID,
            taskID            : candidate.taskID,
            attemptID         : candidate.attemptID,
            contractVersion   : ProcedureInterpretationContract.version,
            variantOf         : interpretation.variantOf,
            divergencePosition: interpretation.divergencePosition,
            builtAtMS         : builtAtMS,
            definition        : definition,
            parts             : parts,
            parameterDetails  : details,
            bindings          : interpretation.parameters.compactMap { parameterIDs[$0.name].flatMap { bindings[$0] } },
            findings          : findings,
            stepOccurrences   : occurrences,
            withheldLiteralSteps: withheldLiterals
        )
    }

    /// The contract of each part: the parameters its steps use, in the order they are first used, the
    /// outputs produced by it or a part it contains, its application, and the state its first step
    /// started from. `entryStates` gives, by step position, the structural scene the step's call was
    /// observed in before acting (nil when not recognized); a step without an application has no
    /// application or entry state item.
    public static func contract(of version: ProcedureVersion, entryStates: [Int: String?]) throws -> [PartContractItem] {
        var items: [PartContractItem] = []
        var usesByStep: [Int: [String]] = [:]
        for step in version.definition.steps {
            for operation in step.operations {
                for argument in operation.arguments {
                    switch argument.value {
                        case .parameter(let id): usesByStep[step.position, default: []].append(id)
                        case .template(let segments):
                            for case .parameter(let id) in segments { usesByStep[step.position, default: []].append(id) }
                        default: break
                    }
                }
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: version.parts.map { ($0.partID, $0) })
        func contains(_ outer: ProcedurePart, _ partID: String) -> Bool {
            var current = byID[partID]
            while let part = current {
                if part.partID == outer.partID { return true }
                current = part.parentPartID.flatMap { byID[$0] }
            }
            return false
        }
        let directions = Dictionary(uniqueKeysWithValues: version.definition.parameters.map { ($0.parameterID, $0.direction) })
        for part in version.parts {
            var position = 0
            func add(_ kind: PartContractItem.Kind, parameter: String? = nil, bundle: String? = nil, scene: String? = nil) throws {
                items.append(try PartContractItem(partID: part.partID, position: position, kind: kind, parameterID: parameter,
                                                  bundleID: bundle, sceneID: scene))
                position += 1
            }
            var inputs: [String] = []
            for stepPosition in part.firstPosition...part.lastPosition {
                for id in usesByStep[stepPosition] ?? [] where !inputs.contains(id) && directions[id] != .output { inputs.append(id) }
            }
            for id in inputs { try add(.input, parameter: id) }
            for detail in version.parameterDetails {
                if let producer = detail.producedByPartID, contains(part, producer) { try add(.output, parameter: detail.parameterID) }
            }
            if let bundle = part.bundleID { try add(.application, bundle: bundle) }
            if let bundle = version.definition.steps[part.firstPosition].bundleID, let entry = entryStates[part.firstPosition] {
                try add(.entryState, bundle: bundle, scene: entry)
            }
        }
        return items
    }
}
