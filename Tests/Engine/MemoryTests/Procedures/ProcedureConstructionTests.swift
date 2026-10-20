//
//  ProcedureConstructionTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// The pure rules D2 builds procedures by: the segmentation of an attempt's calls, the interpretation's
/// templates, the assembly of a version and its contract, and the qualification A. No archive: the
/// facts are given, and each case changes one fact.
@Suite("Procedures built from facts: segmentation, interpretation, assembly and qualification")
struct ProcedureConstructionTests {

    static let finder = "com.apple.finder", preview = "com.apple.Preview"

    static func call(_ id: String, _ tool: AgentTool, _ status: AgentCallStatus = .completed,
                     _ bundle: String? = finder, result: ActOutcomeKind? = nil) -> ProcedureSegmentation.Call {
        ProcedureSegmentation.Call(callEventID: id, tool: tool, status: status, bundleID: bundle, resultKind: result)
    }

    // MARK: Segmentation

    @Test("one step per started UI operation: context tools, a batch's container, planned and skipped steps are no step; a no-op that ran is one, a menu that only listed is none")
    func stepsAreStartedOperations() throws {
        let calls = [
            Self.call("open", .openSession), Self.call("look", .observe), Self.call("batch", .batch),
            Self.call("s1", .typeText), Self.call("s2", .select, .failed), Self.call("s3", .act, .skipped),
            Self.call("s4", .act, .planned), Self.call("noop", .act, result: .actedNoop), Self.call("crashed", .act, .started),
            Self.call("listing", .menu, result: .actedNoop), Self.call("menu", .menu, result: .foundActed),
            Self.call("press", .press), Self.call("list", .windows), Self.call("close", .closeSession),
        ]
        let steps = ProcedureSegmentation.steps(of: calls)
        #expect(steps.map(\.callEventID) == ["s1", "s2", "noop", "crashed", "menu", "press"])
        #expect(steps.map(\.position) == Array(0..<6))
        #expect(steps.allSatisfy { $0.stepOccurrenceID == ProcedureCandidate.occurrenceID(of: $0.callEventID) })
        #expect(ProcedureSegmentation.isListing(tool: .menu, resultKind: .actedNoop))
        #expect(!ProcedureSegmentation.isListing(tool: .act, resultKind: .actedNoop), "a toggle already in its state is a step")
        #expect(!ProcedureSegmentation.isListing(tool: .menu, resultKind: nil), "a menu that did not conclude is not a listing")
        #expect(ProcedureSegmentation.policyVersion == "app-blocks-2")
    }

    @Test("blocks are runs of consecutive operations on one application: Finder, Preview, Finder is three blocks")
    func blocksFollowTheApplication() throws {
        let calls = [Self.call("a", .typeText), Self.call("b", .act), Self.call("c", .act, .completed, Self.preview),
                     Self.call("d", .menu, .completed, Self.preview), Self.call("e", .act), Self.call("f", .act, .completed, nil)]
        let candidate = try #require(try ProcedureCandidate.of(calls, taskID: "t", attemptID: "a1", checkpointSequence: 1,
                                                               builtAtMS: 1_000))
        #expect(candidate.steps.map(\.blockIndex) == [0, 0, 1, 1, 2, 3])
        #expect(candidate.blocks.map { "\($0.bundleID ?? "?"):\($0.firstPosition)-\($0.lastPosition)" }
                == ["\(Self.finder):0-1", "\(Self.preview):2-3", "\(Self.finder):4-4", "?:5-5"])
        let again = try #require(try ProcedureCandidate.of(calls, taskID: "t", attemptID: "a1", checkpointSequence: 2,
                                                           builtAtMS: 9_000))
        #expect(again.candidateID == candidate.candidateID && again.hasSameStructure(as: candidate),
                "the same calls under the same rule are the same candidate, whatever the checkpoint or the instant")
        let other = try #require(try ProcedureCandidate.of(calls.dropLast(), taskID: "t", attemptID: "a1", checkpointSequence: 2,
                                                           builtAtMS: 9_000))
        #expect(other.candidateID != candidate.candidateID)
        #expect(try ProcedureCandidate.of([Self.call("o", .openSession)], taskID: "t", attemptID: "a1", checkpointSequence: nil,
                                          builtAtMS: 1) == nil, "an attempt that started no operation has no candidate")
    }

    // MARK: Templates

    @Test("a template keeps parameters and literals apart; braces are escaped; a template without a parameter or with a broken brace is refused")
    func templates() throws {
        #expect(try UsePiece.parse("{name}.{extension}") == [.parameter("name"), .literal("."), .parameter("extension")])
        #expect(try UsePiece.parse("~/Prove/{name}") == [.literal("~/Prove/"), .parameter("name")])
        #expect(try UsePiece.parse("{{x}} {n}") == [.literal("{x} "), .parameter("n")])
        for broken in ["plain", "{", "{a", "a}", "{}", "{a b}", ""] {
            #expect(throws: ProcedureError.self) { _ = try UsePiece.parse(broken) }
        }
    }

    // MARK: Assembly

    static func candidate(_ requests: [(AgentCallRequest, String?)]) throws -> (ProcedureCandidate, [ProcedureAssembly.StepFacts]) {
        let calls = requests.enumerated().map { Self.call("c\($0.offset)", $0.element.0.tool, .completed, $0.element.1) }
        let candidate = try #require(try ProcedureCandidate.of(calls, taskID: "t", attemptID: "a1", checkpointSequence: 1, builtAtMS: 1))
        let facts = requests.enumerated().map {
            ProcedureAssembly.StepFacts(position: $0.offset, request: $0.element.0, withheldArguments: [])
        }
        return (candidate, facts)
    }

    static let export: [(AgentCallRequest, String?)] = [
        (.typeText(target: "Search", text: "foto_demo", section: nil, replace: true), finder),
        (.act(target: "foto_demo.png", verb: .doubleClick, value: nil, section: nil), finder),
        (.typeText(target: "Name", text: "foto_web.jpg", section: nil, replace: true), preview),
        (.act(target: "Export", verb: .click, value: nil, section: nil), preview),
    ]

    static func interpretation(_ candidate: ProcedureCandidate, uses: [UseStatement], parameters: [ParameterStatement],
                               parts: [PartStatement] = []) throws -> ProcedureInterpretation {
        try ProcedureInterpretation(candidateID: candidate.candidateID,
                                    parts: [try PartStatement(reference: .procedure, label: "Export <name>", outcome: nil)] + parts,
                                    parameters: parameters, uses: uses)
    }

    @Test("a confirmed use becomes a parameter or a template; equal texts elsewhere stay literal; parts, inputs and outputs follow the blocks")
    func assembly() throws {
        let (candidate, facts) = try Self.candidate(Self.export)
        let interpretation = try Self.interpretation(candidate, uses: [
            try UseStatement(stepPosition: 0, argumentName: "text", pieces: try UsePiece.parse("{criterion}")),
            try UseStatement(stepPosition: 2, argumentName: "text", pieces: try UsePiece.parse("{name}.{extension}")),
        ], parameters: [
            try ParameterStatement(name: "criterion", role: "searched text", kind: .text, content: .text("foto_demo"), source: .request),
            try ParameterStatement(name: "name", role: "output name", kind: .text, content: .text("foto_web"), source: .request),
            try ParameterStatement(name: "extension", role: "output extension", kind: .text),
            try ParameterStatement(name: "exported", role: "the exported file", kind: .file, direction: .output,
                                   content: .text("~/foto_web.jpg"), source: .derived, producedBy: .block(1)),
        ], parts: [try PartStatement(reference: .block(1), label: "Export it", outcome: .completed)])
        let inputs = [try TaskValue(name: "extension", kind: .text, content: .text("jpg"), source: .message, sourceRef: "m2")]
        let version = try ProcedureAssembly.assemble(candidate: candidate, interpretation: interpretation, revision: 1, steps: facts,
                                                     taskInputs: inputs, supersedes: nil, builtAtMS: 2)
        #expect(version.findings.isEmpty)
        let steps = version.definition.steps
        #expect(steps.count == 4 && steps.allSatisfy { $0.operations.count == 1 })
        guard case .parameter? = steps[0].operations[0].arguments.first(where: { $0.name == "text" })?.value else {
            Issue.record("the criterion is no parameter"); return
        }
        guard case .template(let segments)? = steps[2].operations[0].arguments.first(where: { $0.name == "text" })?.value else {
            Issue.record("the name is no template"); return
        }
        #expect(segments.count == 3 && segments[1] == .literal("."))
        #expect(steps[3].operations[0].arguments.contains { if case .literal(.text("Export")) = $0.value { true } else { false } })
        #expect(version.bindings.map(\.source) == [.request, .request, .message, .derived],
                "a value left out is the task input's of the same name, with its source")
        #expect(version.parts.map(\.kind) == [.procedure, .subprocedure, .subprocedure, .step, .step, .step, .step])
        let contract = try ProcedureAssembly.contract(of: version, entryStates: [0: "S1", 2: nil])
        let blockInputs = contract.filter { $0.partID.hasSuffix("/block-1") && $0.kind == .input }.compactMap(\.parameterID)
        #expect(blockInputs.count == 2, "the export block reads the name and the extension, propagated from its step")
        #expect(contract.contains { $0.partID.hasSuffix("/block-1") && $0.kind == .output },
                "the output is the block's that produced it")
        #expect(contract.contains { $0.partID.hasSuffix("/procedure") && $0.kind == .output }, "and the procedure's that contains it")
        #expect(contract.contains { $0.partID.hasSuffix("/step-2") && $0.kind == .entryState && $0.sceneID == nil })
        #expect(contract.contains { $0.partID.hasSuffix("/step-0") && $0.kind == .entryState && $0.sceneID == "S1" })
        #expect(version.definition.parameters.first { $0.name == "exported" }?.isRequired == false)
    }

    @Test("a procedure of one application is its own block: no subprocedure duplicates it")
    func oneBlock() throws {
        let (candidate, facts) = try Self.candidate(Array(Self.export.prefix(2)))
        let version = try ProcedureAssembly.assemble(candidate: candidate, interpretation: try Self.interpretation(candidate, uses: [],
                                                     parameters: []), revision: 1, steps: facts, taskInputs: [], supersedes: nil,
                                                     builtAtMS: 2)
        #expect(version.parts.map(\.kind) == [.procedure, .step, .step])
        #expect(version.parts.dropFirst().allSatisfy { $0.parentPartID == version.parts[0].partID })
    }

    @Test("a use the call contradicts is a finding and the argument stays as recorded; a value not known is unverifiable; a secret takes only a withheld argument")
    func findings() throws {
        var (candidate, facts) = try Self.candidate(Self.export)
        facts[2] = ProcedureAssembly.StepFacts(position: 2, request: .typeText(target: "Name", text: "[withheld]", section: nil,
                                                                                 replace: true), withheldArguments: ["text#0"])
        let interpretation = try Self.interpretation(candidate, uses: [
            try UseStatement(stepPosition: 0, argumentName: "text", pieces: try UsePiece.parse("{criterion}")),
            try UseStatement(stepPosition: 1, argumentName: "target", pieces: try UsePiece.parse("{file}")),
            try UseStatement(stepPosition: 2, argumentName: "text", pieces: try UsePiece.parse("{code}")),
        ], parameters: [
            try ParameterStatement(name: "criterion", role: "searched text", kind: .text, content: .text("other"), source: .request),
            try ParameterStatement(name: "file", role: "the file", kind: .file),
            try ParameterStatement(name: "code", role: "a code", kind: .text, sensitivity: .secret),
        ])
        let version = try ProcedureAssembly.assemble(candidate: candidate, interpretation: interpretation, revision: 1, steps: facts,
                                                     taskInputs: [], supersedes: nil, builtAtMS: 2)
        #expect(version.findings.map { "\($0.stepPosition):\($0.kind.rawValue)" } == ["0:use_mismatch", "1:unverifiable_use"])
        guard case .literal(.text("foto_demo"))? = version.definition.steps[0].operations[0].arguments.first(where: { $0.name == "text" })?.value else {
            Issue.record("a contradicted use replaced the argument"); return
        }
        guard case .parameter? = version.definition.steps[2].operations[0].arguments.first(where: { $0.name == "text" })?.value else {
            Issue.record("the secret parameter did not take the withheld argument"); return
        }
        #expect(version.withheldLiteralSteps.isEmpty)
        #expect(version.bindings.first { $0.content == .withheld } != nil)
        // The same withheld argument left literal is a step that can be read and never reused.
        let unparameterized = try ProcedureAssembly.assemble(candidate: candidate, interpretation: try Self.interpretation(candidate,
                                                             uses: [], parameters: []), revision: 1, steps: facts, taskInputs: [],
                                                             supersedes: nil, builtAtMS: 2)
        #expect(unparameterized.withheldLiteralSteps == [2])
    }

    @Test("what is structurally wrong is refused whole: an unknown step, block or argument, a parameter of two types, an output as an argument")
    func structuralRefusals() throws {
        let (candidate, facts) = try Self.candidate(Self.export)
        func assemble(_ uses: [UseStatement], _ parameters: [ParameterStatement], parts: [PartStatement] = []) throws {
            _ = try ProcedureAssembly.assemble(candidate: candidate, interpretation: try Self.interpretation(candidate, uses: uses,
                                               parameters: parameters, parts: parts), revision: 1, steps: facts, taskInputs: [],
                                               supersedes: nil, builtAtMS: 2)
        }
        let text = try ParameterStatement(name: "p", role: "r", kind: .text, content: .text("foto_demo"))
        #expect(throws: ProcedureError.self) { try assemble([try UseStatement(stepPosition: 9, argumentName: "text", pieces: [.parameter("p")])], [text]) }
        #expect(throws: ProcedureError.self) { try assemble([try UseStatement(stepPosition: 0, argumentName: "item", pieces: [.parameter("p")])], [text]) }
        #expect(throws: ProcedureError.self) { try assemble([try UseStatement(stepPosition: 0, argumentName: "text", pieces: [.parameter("q")])], [text]) }
        #expect(throws: ProcedureError.self) { try assemble([], [], parts: [try PartStatement(reference: .block(5), label: "x", outcome: nil)]) }
        #expect(throws: ProcedureError.self) {
            try assemble([try UseStatement(stepPosition: 0, argumentName: "text", pieces: [.parameter("p")]),
                          try UseStatement(stepPosition: 2, argumentName: "replace", pieces: [.parameter("p")])], [text])
        }
        let output = try ParameterStatement(name: "o", role: "r", kind: .file, direction: .output, producedBy: .procedure)
        #expect(throws: ProcedureError.self) { try assemble([try UseStatement(stepPosition: 0, argumentName: "text", pieces: [.parameter("o")])], [output]) }
        #expect(throws: ProcedureError.self) { _ = try ProcedureInterpretation(candidateID: "c", parts: []) }
        #expect(throws: ProcedureError.self) { _ = try PartStatement(reference: .procedure, label: " ", outcome: nil) }
        #expect(throws: ProcedureError.self) { _ = try ParameterStatement(name: "a b", role: "r", kind: .text) }
        #expect(throws: ProcedureError.self) { _ = try ParameterStatement(name: "s", role: "r", kind: .text, sensitivity: .secret, content: .text("x")) }
    }

    // MARK: Qualification

    static func part(_ kind: PartKind = .step, label: String? = "a label", outcome: DeclaredPartOutcome = .completed) throws -> ProcedurePart {
        try ProcedurePart(partID: "p", routeID: "r", kind: kind, parentPartID: kind == .procedure ? nil : "r/procedure", firstPosition: 0,
                          lastPosition: 0, stepID: kind == .step ? "s" : nil, bundleID: finder,
                          label: kind == .procedure ? (label ?? "x") : label, declaredOutcome: outcome)
    }

    static func verification(_ condition: OperationCheck.Condition, _ verdict: OperationCheck.Verdict = .passed,
                             performed: OperationCheck.Performed = .requested, limits: [OperationCheck.Limit] = []) -> QualificationPolicy.VerificationFact {
        QualificationPolicy.VerificationFact(eventID: "v", condition: condition, verdict: verdict, performed: performed, limits: limits)
    }

    static func evaluate(_ part: ProcedurePart, _ step: QualificationPolicy.StepFacts, end: DeclaredTaskStatus? = .completed,
                         state: InterpretationState = .ended, parent: DeclaredPartOutcome? = nil) -> [String] {
        let qualification = QualificationPolicy.evaluate(QualificationPolicy.PartFacts(part: part, attemptEnd: end, interpretationState: state,
                                                                                         parentOutcome: parent, steps: [step]))
        return qualification.verdict == .admitted ? ["admitted"] : qualification.findings.map(\.reason.rawValue)
    }

    static func step(_ verifications: [QualificationPolicy.VerificationFact], status: AgentCallStatus = .completed,
                     gap: Bool = false) -> QualificationPolicy.StepFacts {
        QualificationPolicy.StepFacts(position: 0, callEventID: "c", status: status, hasRecordingGap: gap, verifications: verifications)
    }

    @Test("A admits a declared, complete, positively verified part: a state already present with no gesture is positive, a recovery or a delivery in doubt is not")
    func positiveVerification() throws {
        let part = try Self.part()
        #expect(Self.evaluate(part, Self.step([Self.verification(.structuralEffect, limits: [.windowWide, .noExpectation])])) == ["admitted"])
        #expect(Self.evaluate(part, Self.step([Self.verification(.requestedStateAlreadyPresent, performed: .none)])) == ["admitted"])
        #expect(Self.evaluate(part, Self.step([Self.verification(.menuItemChosen, limits: [.commandEffectUnchecked])])) == ["admitted"])
        #expect(Self.evaluate(part, Self.step([Self.verification(.recoveryInsteadOfRequest, performed: .substitute)])) == ["verification_not_positive"])
        #expect(Self.evaluate(part, Self.step([Self.verification(.menuClosedAfterChoice)])) == ["verification_not_positive"])
        #expect(Self.evaluate(part, Self.step([Self.verification(.structuralEffect, limits: [.deliveryUncertain])])) == ["verification_not_positive"])
        #expect(Self.evaluate(part, Self.step([Self.verification(.structuralEffect, performed: .none)])) == ["verification_not_positive"])
        #expect(Self.evaluate(part, Self.step([Self.verification(.none, .unknown)])) == ["verification_unknown"])
        #expect(Self.evaluate(part, Self.step([Self.verification(.valueReadBack, .failed)])) == ["verification_failed"])
        #expect(Self.evaluate(part, Self.step([])) == ["no_verification"])
        #expect(Self.evaluate(part, Self.step([], gap: true)) == ["recording_gap"], "a missing verification on a gap is no other reason")
        #expect(Self.evaluate(part, Self.step([Self.verification(.structuralEffect)], status: .started)) == ["call_incomplete"])
        #expect(Self.evaluate(part, Self.step([Self.verification(.structuralEffect)], status: .cancelled)) == ["call_cancelled"])
    }

    @Test("the declaration: a stated outcome is kept; an unstated one comes from the containing part's completion or, for the procedure, from the end; a late interpretation never completes")
    func declaration() throws {
        let passed = Self.step([Self.verification(.structuralEffect)])
        #expect(Self.evaluate(try Self.part(label: nil), passed) == ["missing_label"])
        #expect(Self.evaluate(try Self.part(outcome: .notDeclared), passed, parent: .completed) == ["admitted"])
        #expect(Self.evaluate(try Self.part(outcome: .notDeclared), passed, parent: .failed) == ["completion_not_declared"])
        #expect(Self.evaluate(try Self.part(outcome: .failed), passed, parent: .completed) == ["declared_failed"],
                "a child declared failed is not promoted by its parent")
        #expect(Self.evaluate(try Self.part(.procedure, outcome: .notDeclared), passed, end: .completed) == ["admitted"])
        #expect(Self.evaluate(try Self.part(.procedure, outcome: .notDeclared), passed, end: nil) == ["completion_not_declared"])
        #expect(Self.evaluate(try Self.part(.procedure, outcome: .completed), passed, end: .failed) == ["declared_failed"])
        #expect(Self.evaluate(try Self.part(.procedure, outcome: .notDeclared), passed, end: .abandoned) == ["completion_not_declared"])
        #expect(Self.evaluate(try Self.part(), passed, end: nil, state: .interrupted) == ["declared_late"])
        #expect(Self.evaluate(try Self.part(), passed, end: nil, state: .running) == ["admitted"],
                "a part declared completed at a checkpoint is admitted while the task goes on")
    }

    @Test("a contradiction, an unknown value, a withheld literal or a missing input keep the step out")
    func contractCoherence() throws {
        let part = try Self.part()
        func evaluate(_ findings: [InterpretationFinding.Kind] = [], withheld: Bool = false, missing: [String] = []) -> [String] {
            Self.evaluate(part, QualificationPolicy.StepFacts(position: 0, callEventID: "c", status: .completed, hasRecordingGap: false,
                                                              verifications: [Self.verification(.valueReadBack)], findings: findings,
                                                              keepsWithheldLiteral: withheld, missingInputs: missing))
        }
        #expect(evaluate([.useMismatch]) == ["use_mismatch"])
        #expect(evaluate([.unverifiableUse]) == ["unverifiable_use"])
        #expect(evaluate(withheld: true) == ["withheld_literal"])
        #expect(evaluate(missing: ["p"]) == ["missing_input"])
    }

    @Test("qualification C: an adapter's own oracle proves it, an unread change does not; a read needs a result; an ambiguous reference keeps the step out")
    func stepKinds() throws {
        let part = try Self.part()
        func evaluate(_ kind: ProcedureSegmentation.StepKind, _ verifications: [QualificationPolicy.VerificationFact],
                      ambiguous: Bool = false) -> [String] {
            Self.evaluate(part, QualificationPolicy.StepFacts(position: 0, callEventID: "c", status: .completed, hasRecordingGap: false,
                                                              verifications: verifications, kind: kind,
                                                              hasUnresolvedReference: ambiguous))
        }
        #expect(evaluate(.adapterCall, [Self.verification(.adapterEffect)]) == ["admitted"])
        #expect(evaluate(.adapterCall, [Self.verification(.adapterEffect, .unknown, performed: .uncertain)]) == ["adapter_unverified"])
        #expect(evaluate(.requiredRead, [Self.verification(.adapterRead)]) == ["admitted"])
        #expect(evaluate(.adapterCall, [Self.verification(.adapterEffect)], ambiguous: true) == ["reference_unresolved"])
    }
}
