//
//  MemoryTaskTool.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore

/// MemoryTaskTool is the `memory_task` tool: its definition, the instructions that tell an agent when to
/// use it, and the decoding of its arguments into the task contract. It is not an operation on an
/// application and is never recorded as one: its declarations are the task's facts.
nonisolated enum MemoryTaskTool {

    static let name = "memory_task"

    /// Operation is what one call of the tool asks.
    enum Operation: String, CaseIterable {
        case begin, update, checkpoint, end, resume, status, interpret, candidate, recall, use, choose, reconcile

        /// The operations the tool offers: all of them.
        static var offered: [Operation] { allCases }
    }

    /// Request is one decoded call, with the secret values it carried, which the producer keeps in
    /// memory to withhold them from every later record and which are never stored.
    enum Request {
        case begin(TaskRevisionContent, secrets: [String], recall: RecallPlan?)
        case update(Update, secrets: [String])
        case checkpoint(TaskCheckpointDraft, secrets: [String], uses: [UseReport], checks: [ResultCheck])
        case end(TaskCheckpointDraft, secrets: [String], uses: [UseReport], checks: [ResultCheck])
        case resume(taskID: String)
        case status
        case interpret(ProcedureInterpretation, secrets: [String], checks: [ResultCheck])
        case candidate(taskID: String)
        case recall(RecallReason, RecallPlan)
        case use([UseReport])
        case choose(RecallChoice.Plan)
        /// P2-06: what a later completed call read of an earlier call whose effect was not known.
        case reconcile(call: String, finding: CallReconciliation.Finding, evidence: String, note: String?)
    }

    /// ResultCheck is one result check a call names (`TaskResultCheck.Expectation`): as Braus reads it, with the paths
    /// and texts the agent gave, which stay in memory only, and as the archive keeps it, minimized as every text of the
    /// task is.
    struct ResultCheck {
        let read: TaskResultCheck.Expectation
        let kept: TaskResultCheck.Expectation
        /// A guard Braus added (`AutomationTools.guards`), recorded as one.
        var isGuard = false
    }

    /// RecallPlan is what a search looks for beyond the task's revision: the remaining work (the goal when omitted) and
    /// the needs it splits into. `propose` is the product's path, a proposal the agent chooses from; it is false only
    /// under the selector's control (`RecallSelectionControl`), for a comparison or a regression test.
    struct RecallPlan {
        let remaining: String?
        let needs: [RecallNeed]
        var propose = true
    }

    /// UseReport is the agent's declared use of one need's selection: followed, adapted, abandoned or not
    /// executed, with the cause of a failure when it knows one.
    struct UseReport {
        let queryID: String
        let needPosition: Int
        let declared: String
        let cause: String?
        let note: String?
    }

    /// Update is a revision's change: the fields given replace the revision's, inputs replace those of
    /// the same name or are added, `removedInputs` are dropped. `minimization` holds every secret known
    /// when it was decoded, the update's own included.
    struct Update {
        let expecting: Int?
        let goal: String?
        let result: String?
        let constraints: [String]?
        let inputs: [TaskValue]
        let removedInputs: [String]
        let reason: String?
        let minimization: ValueMinimization

        /// The content of the next revision, built on `base`, the revision the agent read. What it keeps
        /// of the base is minimized again, so a secret declared since is not carried forward.
        func applied(to base: TaskRevisionContent, messageRef: String?) throws -> TaskRevisionContent {
            var merged = try base.inputs.filter { input in
                !removedInputs.contains(input.name) && !inputs.contains { $0.name.utf8.elementsEqual(input.name.utf8) }
            }.map { try MemoryTaskTool.minimized($0, by: minimization) }
            merged += inputs
            var references = base.messageRefs
            if let messageRef, !references.contains(messageRef) { references.append(messageRef) }
            func kept(_ text: String) -> String { minimization.minimize(text: text).0 }
            return try TaskRevisionContent(
                goal           : goal ?? kept(base.goal),
                requestedResult: result ?? base.requestedResult.map(kept),
                constraints    : constraints ?? base.constraints.map(kept),
                inputs         : merged,
                messageRefs    : references
            )
        }
    }

    /// Failure is a call the tool answers with an error the agent can act on: a code, a sentence, and
    /// the facts it needs (the current revision, the open task).
    struct Failure: Error {
        let code: String
        let message: String
        var details: [String: JSONValue] = [:]
    }

    // MARK: Definition

    static var definition: JSONValue {
        let text: JSONValue = .object(["type": .string("string"), "minLength": .number(1)])
        let texts: JSONValue = .object(["type": .string("array"), "items": text])
        let value: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "name": text,
                "value": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string"),
                                 "enum": .array(["text", "number", "boolean", "file", "folder",
                                                 "reference"].map(JSONValue.string))]),
                "role": text,
                "source": .object(["type": .string("string"),
                                   "enum": .array(TaskValueSource.allCases.map { .string($0.rawValue) })]),
                "source_ref": text,
                "source_version": text,
                "secret": .object(["type": .string("boolean")]),
            ]),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false),
        ])
        let values: JSONValue = .object(["type": .string("array"), "items": value])
        let outcome: JSONValue = .object(["type": .string("string"),
                                          "enum": .array(["completed", "failed", "not_completed"].map(JSONValue.string))])
        let statement: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["label": text, "outcome": outcome]),
            "additionalProperties": .bool(false),
        ])
        let partStatement: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["part": text, "label": text, "outcome": outcome]),
            "required": .array([.string("part")]),
            "additionalProperties": .bool(false),
        ])
        let stepStatement: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["step": .object(["type": .string("integer"), "minimum": .number(1)]), "label": text,
                                   "outcome": outcome]),
            "required": .array([.string("step")]),
            "additionalProperties": .bool(false),
        ])
        let phaseStatement: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["from": .object(["type": .string("integer"), "minimum": .number(1)]),
                                   "to": .object(["type": .string("integer"), "minimum": .number(1)]), "label": text,
                                   "outcome": outcome]),
            "required": .array([.string("from"), .string("to"), .string("label")]),
            "additionalProperties": .bool(false),
        ])
        let check: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "file": text, "file_written": text, "file_changed": text, "file_unchanged": text, "file_absent": text,
                "file_moved": text, "file_copied": text, "to": text, "contains": text, "window": text, "open": .object(["type": .string("boolean")]), "element": text,
                "app": text, "value": .object(["type": .string("string")]),
                "state": .object(["type": .string("string"), "enum": .array(["on", "off", "mixed"].map(JSONValue.string))]),
                "present": .object(["type": .string("boolean")]), "none": text,
            ]),
            "additionalProperties": .bool(false),
        ])
        let resultCheck: JSONValue = .object(["anyOf": .array([check, .object(["type": .string("array"), "items": check])])])
        let parameter: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "name": text, "role": text, "value": .object(["type": .string("string")]),
                "kind": .object(["type": .string("string"),
                                 "enum": .array(["text", "number", "boolean", "file", "folder", "reference"].map(JSONValue.string))]),
                "direction": .object(["type": .string("string"), "enum": .array(["input", "output", "inout"].map(JSONValue.string))]),
                "unit": text, "secret": .object(["type": .string("boolean")]),
                "source": .object(["type": .string("string"), "enum": .array(TaskValueSource.allCases.map { .string($0.rawValue) })]),
                "source_ref": text, "source_version": text, "produced_by": text,
            ]),
            "required": .array([.string("name"), .string("role")]),
            "additionalProperties": .bool(false),
        ])
        let use: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "step": .object(["type": .string("integer"), "minimum": .number(1)]), "argument": text,
                "position": .object(["type": .string("integer"), "minimum": .number(0)]), "template": text,
            ]),
            "required": .array([.string("step"), .string("argument"), .string("template")]),
            "additionalProperties": .bool(false),
        ])
        let need: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["text": text, "app": text]),
            "required": .array([.string("text")]),
            "additionalProperties": .bool(false),
        ])
        let report: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "query": text, "need": .object(["type": .string("integer"), "minimum": .number(1)]),
                "outcome": .object(["type": .string("string"),
                                    "enum": .array(["followed", "adapted", "abandoned", "not_executed"].map(JSONValue.string))]),
                "cause": .object(["type": .string("string"),
                                  "enum": .array(["method", "driver", "application", "agent", "input", "unknown"].map(JSONValue.string))]),
                "note": text,
            ]),
            "required": .array([.string("query"), .string("outcome")]),
            "additionalProperties": .bool(false),
        ])
        return .object([
            "name": .string(name),
            "description": .string(
                ModelText.text(.init(rawValue: "memory_task_tool.report.v1"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.2"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.3"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.4"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.5"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.6"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.7"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.8"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.9"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.10"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.11"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.12"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.13"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.14"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.15"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.16"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.17"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.18"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.19"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.20"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.21"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.22"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.23"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.24"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.25"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.26"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.27"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.28"))
                + ModelText.text(.init(rawValue: "memory_task_tool.report.v1.29"))
            ),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "operation": .object(["type": .string("string"),
                                          "enum": .array(Operation.offered.map { .string($0.rawValue) })]),
                    "task": text,
                    "revision": .object(["type": .string("integer"), "minimum": .number(1)]),
                    "goal": text,
                    "result": text,
                    "constraints": texts,
                    "inputs": values,
                    "remove_inputs": texts,
                    "reason": text,
                    "note": text,
                    "outcome": .object(["type": .string("string"),
                                        "enum": .array(["completed", "failed", "abandoned"].map(JSONValue.string))]),
                    "outputs": values,
                    "candidate": text,
                    "procedure": statement,
                    "parts": .object(["type": .string("array"), "items": partStatement]),
                    "steps": .object(["type": .string("array"), "items": stepStatement]),
                    "phases": .object(["type": .string("array"), "items": phaseStatement]),
                    "result_check": resultCheck,
                    "parameters": .object(["type": .string("array"), "items": parameter]),
                    "uses": .object(["type": .string("array"), "items": use]),
                    "variant_of": text,
                    "divergence_step": .object(["type": .string("integer"), "minimum": .number(1)]),
                    "remaining": text,
                    "needs": .object(["type": .string("array"), "maxItems": .number(Double(RecallContract.maximumNeeds)), "items": need]),
                    "recall": .object(["type": .string("boolean")]),
                    "use": .object(["type": .string("array"), "items": report]),
                    "call": text,
                    "finding": .object(["type": .string("string"),
                                        "enum": .array(CallReconciliation.Finding.allCases.map { .string($0.rawValue) })]),
                    "evidence": text,
                ].merging(Self.choiceProperties(text), uniquingKeysWith: { $1 })),
                "required": .array([.string("operation")]),
                "additionalProperties": .bool(false),
            ]),
            "annotations": .object(["readOnlyHint": .bool(false)]),
        ])
    }

    /// The properties of a choice: the proposal chosen from and the plan.
    static func choiceProperties(_ text: JSONValue) -> [String: JSONValue] {
        let whole: JSONValue = .object(["type": .string("integer"), "minimum": .number(1)])
        let tract: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["source": text, "from": whole, "to": whole]),
            "required": .array([.string("source"), .string("from"), .string("to")]),
            "additionalProperties": .bool(false),
        ])
        let planned: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "need": whole, "tracts": .object(["type": .string("array"), "items": tract]),
                "covered": .object(["type": .string("string"), "enum": .array(RecallChoice.Declared.allCases.map { .string($0.rawValue) })]),
                "uncovered": text,
                "alternatives": .object(["type": .string("array"), "items": tract]),
                "settled_by": text,
            ]),
            "required": .array([.string("need"), .string("covered")]),
            "additionalProperties": .bool(false),
        ])
        return [
            "proposal": text,
            "plan": .object(["type": .string("array"), "maxItems": .number(Double(RecallContract.maximumNeeds)), "items": planned]),
        ]
    }

    /// The instructions of `memory_task`: the task's declarations, the Recall by the agent's choice, the interpretation.
    static var instructions: String {
        baseInstructions + "\n" + choiceInstructions + "\n" + interpretationInstructions
    }

    static let choiceInstructions = ModelText.text(.init(rawValue: "memory_task_tool.choiceInstructions.v1"))

    static let baseInstructions = ModelText.text(.init(rawValue: "memory_task_tool.baseInstructions.v1"))

    static let interpretationInstructions = ModelText.text(.init(rawValue: "memory_task_tool.interpretationInstructions.v1"))

    // MARK: Decoding

    /// The request a call's arguments state, with values that may not be kept withheld by `minimization`.
    static func decode(_ arguments: JSONValue, minimization: ValueMinimization, messageRef: String?) throws -> Request {
        let messageRef = messageRef.flatMap { $0.isEmpty ? nil : $0 }
        guard let object = arguments.object else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.object.v1"))) }
        let allowed = Set<String>(["operation", "task", "revision", "goal", "result", "constraints", "inputs",
                                    "remove_inputs", "reason", "note", "outcome", "outputs", "candidate", "procedure",
                                    "parts", "steps", "phases", "parameters", "uses", "variant_of", "divergence_step", "remaining",
                                    "needs", "recall", "use", "proposal", "plan", "recall_mode", "result_check", "call",
                                    "finding", "evidence"])
        guard Set(object.keys).isSubset(of: allowed) else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.allowed.v1"))) }
        guard let word = arguments["operation"].string, let operation = Operation(rawValue: word), Operation.offered.contains(operation) else {
            throw invalid((ModelText.text(.init(rawValue: "memory_task_tool.operation.v1"))
                + "\(Operation.offered.map(\.rawValue).joined(separator: ", "))"))
        }
        // The agent's choice is the product's one path. `recall_mode: propose`, which clients of the experiment sent, is
        // accepted and changes nothing; only the selector's control, in a test or a comparison, answers a selection.
        let propose: Bool
        switch arguments["recall_mode"] {
            case .null: propose = !RecallSelectionControl.automatic
            case .string("propose"): propose = true
            default: throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.propose.v1")))
        }
        // Every value the request declares secret is known before any of its texts is read, so a copy
        // of one in the goal, a constraint or a note is withheld as the value itself is.
        let minimization = minimization.adding(secrets: declaredSecrets(in: arguments))
        func text(_ key: String) -> String? { optionalText(arguments, key).map { minimization.minimize(text: $0).0 } }
        func list(_ key: String) throws -> [String]? {
            try texts(arguments, key)?.map { minimization.minimize(text: $0).0 }
        }
        var secrets: [String] = []
        do {
            switch operation {
                case .begin:
                    guard let goal = text("goal") else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.goal.v1"))) }
                    let inputs = try values(
                        arguments["inputs"],
                        minimization: minimization,
                        secrets     : &secrets,
                        outputs     : false
                    )
                    let content = try TaskRevisionContent(
                        goal           : goal,
                        requestedResult: text("result"),
                        constraints    : try list("constraints") ?? [],
                        inputs         : inputs,
                        messageRefs    : messageRef.map { [$0] } ?? []
                    )
                    let wantsRecall = arguments["recall"].bool ?? true
                    return .begin(content, secrets: secrets,
                                  recall: wantsRecall ? RecallPlan(remaining: text("remaining"), needs: try needs(arguments, minimization),
                                                                   propose: propose) : nil)
                case .update:
                    let revision: Int?
                    if object["revision"] != nil {
                        // Int(exactly:) refuses a fraction, an infinity and a number past the integers.
                        guard case .number(let number) = arguments["revision"], let whole = Int(exactly: number),
                              whole >= 1 else {
                            throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.whole.v1")))
                        }
                        revision = whole
                    } else {
                        revision = nil
                    }
                    let update = Update(
                        expecting    : revision,
                        goal         : text("goal"),
                        result       : text("result"),
                        constraints  : try list("constraints"),
                        inputs       : try values(
                            arguments["inputs"],
                            minimization: minimization,
                            secrets     : &secrets,
                            outputs     : false
                        ),
                        removedInputs: try list("remove_inputs") ?? [],
                        reason       : text("reason"),
                        minimization : minimization
                    )
                    return .update(update, secrets: secrets)
                case .checkpoint:
                    let outputs = try values(
                        arguments["outputs"],
                        minimization: minimization,
                        secrets     : &secrets,
                        outputs     : true
                    )
                    return .checkpoint(try TaskCheckpointDraft(kind: .checkpoint, note: text("note"), outputs: outputs),
                                       secrets: secrets, uses: try reports(arguments["use"], minimization),
                                       checks: try resultChecks(arguments["result_check"], minimization: minimization))
                case .end:
                    guard let word = arguments["outcome"].string,
                          let outcome = DeclaredTaskStatus(rawValue: word), outcome.isClosed else {
                        throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.outcome.v1")))
                    }
                    let outputs = try values(
                        arguments["outputs"],
                        minimization: minimization,
                        secrets     : &secrets,
                        outputs     : true
                    )
                    // What a completed task's result is, which Braus reads itself (`TaskResultCheck`): the checks named, else
                    // the files its outputs declare by an absolute path.
                    let checks = try resultChecks(arguments["result_check"], minimization: minimization)
                    if !checks.isEmpty, outcome != .completed { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.checks.v1"))) }
                    // The files its outputs declare by an absolute path are checked whatever else it names (`AutomationTools.completed`).
                    return .end(
                        try TaskCheckpointDraft(
                            kind    : .end,
                            declared: outcome,
                            note    : text("note"),
                            outputs : outputs
                        ),
                        secrets: secrets,
                        uses   : try reports(arguments["use"], minimization),
                        checks : checks
                    )
                case .resume:
                    guard let task = optionalText(arguments, "task") else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.task.v1"))) }
                    return .resume(taskID: task)
                case .status:
                    return .status
                case .candidate:
                    guard let task = optionalText(arguments, "task") else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.task.v1.2"))) }
                    return .candidate(taskID: task)
                case .interpret:
                    let checks = try resultChecks(arguments["result_check"], minimization: minimization)
                    guard case .interpret(let interpretation, let secrets, _) = try interpretation(arguments, minimization: minimization) else {
                        throw invalidInterpretation(ModelText.text(.init(rawValue: "memory_task_tool.secrets.v1")))
                    }
                    return .interpret(interpretation, secrets: secrets, checks: checks)
                case .recall:
                    guard let word = arguments["reason"].string, let reason = RecallReason(rawValue: word), reason != .initial else {
                        throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.reason.v1"))
                                      + ModelText.text(.init(rawValue: "memory_task_tool.reason.v1.2")))
                    }
                    return .recall(reason, RecallPlan(remaining: text("remaining"), needs: try needs(arguments, minimization), propose: propose))
                case .choose:
                    return .choose(try plan(arguments, minimization))
                case .use:
                    let uses = try reports(arguments["use"], minimization)
                    guard !uses.isEmpty else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.uses.v1"))) }
                    return .use(uses)
                case .reconcile:
                    guard let call = optionalText(arguments, "call"), let evidence = optionalText(arguments, "evidence"),
                          let word = arguments["finding"].string, let finding = CallReconciliation.Finding(rawValue: word) else {
                        throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.finding.v1"))
                                      + ModelText.text(.init(rawValue: "memory_task_tool.finding.v1.2")))
                    }
                    return .reconcile(call: call, finding: finding, evidence: evidence, note: text("note"))
            }
        } catch let error as TaskContextError {
            throw Failure(code: "invalid_task", message: (ModelText.text(.init(rawValue: "memory_task_tool.error.v1"))
                + "\(error)"
                + ModelText.text(.init(rawValue: "memory_task_tool.error.v1.2"))))
        } catch let error as ProcedureError {
            throw Failure(code: "invalid_interpretation", message: ModelText.text(.init(rawValue: "memory_task_tool.error.v1.3"))
                + ("\(words(error))" + ModelText.text(.init(rawValue: "answer.MemoryTaskTool.error.v1.fragment.2"))))
        }
    }

    /// A procedure error as the agent reads it: what to change, never the enum it is carried in. The canary of
    /// 14/10/2026 read "invalid(Memory.ProcedureError.Invalidity.parameter(…))" twice before it could interpret.
    static func words(_ error: ProcedureError) -> String {
        guard case .invalid(let invalidity) = error else { return "\(error)" }
        switch invalidity {
            case .parameter(let text), .label(let text), .template(let text): return text
            case .emptyText(let field)  : return ("\(field)" + ModelText.text(.init(rawValue: "memory_task_tool.field.v1")))
            case .tooLong(let field)    : return ("\(field)" + ModelText.text(.init(rawValue: "memory_task_tool.field.v1.2")))
            case .tooMany(let field)    : return (ModelText.text(.init(rawValue: "memory_task_tool.field.v1.3")) + "\(field)")
            case .duplicate(let field)  : return ("\(field)" + ModelText.text(.init(rawValue: "answer.MemoryTaskTool.field.v1.fragment.2")))
            case .outOfRange(let field) : return ("\(field)" + ModelText.text(.init(rawValue: "memory_task_tool.field.v1.4")))
            case .positions(let of)     : return (ModelText.text(.init(rawValue: "memory_task_tool.of.v1"))
                + "\(of)"
                + ModelText.text(.init(rawValue: "memory_task_tool.of.v1.2")))
            case .blocks                : return ModelText.text(.init(rawValue: "memory_task_tool.of.v1.3"))
            case .noSteps               : return ModelText.text(.init(rawValue: "memory_task_tool.of.v1.4"))
        }
    }

    /// An interpretation's statements, with every text minimized by what is known: labels, roles, values and
    /// templates; a value declared secret is withheld and kept aside, as a task's is.
    private static func interpretation(_ arguments: JSONValue, minimization: ValueMinimization) throws -> Request {
        guard let candidate = optionalText(arguments, "candidate") else { throw invalidInterpretation(ModelText.text(.init(rawValue: "memory_task_tool.candidate.v1"))) }
        func kept(_ text: String?) -> String? { text.map { minimization.minimize(text: $0).0 } }
        func outcome(_ value: JSONValue) throws -> DeclaredPartOutcome? {
            guard value != .null else { return nil }
            guard let word = value.string, let known = DeclaredPartOutcome(rawValue: word), known != .notDeclared else {
                throw invalidInterpretation(ModelText.text(.init(rawValue: "memory_task_tool.known.v1")))
            }
            return known
        }
        func reference(_ word: String) throws -> PartReference {
            if word == "procedure" { return .procedure }
            if word.hasPrefix("b"), let index = Int(word.dropFirst()), index >= 1 { return .block(index - 1) }
            if word.hasPrefix("s"), let index = Int(word.dropFirst()), index >= 1 { return .step(index - 1) }
            if word.hasPrefix("f") {
                let bounds = word.dropFirst().split(separator: "-").compactMap { Int($0) }
                if bounds.count == 2, bounds[0] >= 1, bounds[1] >= bounds[0] { return .phase(first: bounds[0] - 1, last: bounds[1] - 1) }
            }
            throw invalidInterpretation(("\(word)" + ModelText.text(.init(rawValue: "memory_task_tool.bounds.v1"))))
        }
        func whole(_ value: JSONValue, _ what: String) throws -> Int {
            guard case .number(let number) = value, let integer = Int(exactly: number), integer >= 1 else {
                throw invalidInterpretation(("\(what)" + ModelText.text(.init(rawValue: "memory_task_tool.integer.v1"))))
            }
            return integer
        }
        var parts: [PartStatement] = []
        let procedure = arguments["procedure"]
        parts.append(try PartStatement(reference: .procedure, label: kept(procedure["label"].string),
                                       outcome: try outcome(procedure["outcome"])))
        for item in arguments["parts"].array ?? [] {
            guard let word = item["part"].string else { throw invalidInterpretation(ModelText.text(.init(rawValue: "memory_task_tool.word.v1"))) }
            parts.append(try PartStatement(reference: try reference(word), label: kept(item["label"].string),
                                           outcome: try outcome(item["outcome"])))
        }
        // Phases: the agent's own subprocedures, contiguous steps with one label (open the file, save a copy).
        for item in arguments["phases"].array ?? [] {
            let from = try whole(item["from"], ModelText.text(.init(rawValue: "memory_task_tool.from.v1"))), to = try whole(item["to"], ModelText.text(.init(rawValue: "memory_task_tool.from.v1.2")))
            guard to >= from else { throw invalidInterpretation(ModelText.text(.init(rawValue: "memory_task_tool.from.v1.3"))) }
            parts.append(try PartStatement(reference: .phase(first: from - 1, last: to - 1), label: kept(item["label"].string),
                                           outcome: try outcome(item["outcome"])))
        }
        for item in arguments["steps"].array ?? [] {
            let number = try whole(item["step"], "a step")
            parts.append(try PartStatement(reference: .step(number - 1), label: kept(item["label"].string),
                                           outcome: try outcome(item["outcome"])))
        }
        var secrets: [String] = []
        var parameters: [ParameterStatement] = []
        for item in arguments["parameters"].array ?? [] {
            guard let name = item["name"].string, let role = item["role"].string else {
                throw invalidInterpretation(ModelText.text(.init(rawValue: "memory_task_tool.role.v1")))
            }
            let secret = item["secret"].bool ?? false
            let kind = try item["kind"].string.map { word -> TaskValueKind in
                guard let known = TaskValueKind(rawValue: word), known != .missing else {
                    throw invalidInterpretation((ModelText.text(.init(rawValue: "memory_task_tool.known.v1.2")) + "\(name)"))
                }
                return known
            } ?? .text
            let direction = try item["direction"].string.map { word -> ParameterDirection in
                guard let known = ParameterDirection(rawValue: word) else { throw invalidInterpretation((ModelText.text(.init(rawValue: "memory_task_tool.known.v1.3"))
                    + "\(name)")) }
                return known
            } ?? .input
            let source = try item["source"].string.map { word -> TaskValueSource in
                guard let known = TaskValueSource(rawValue: word) else { throw invalidInterpretation((ModelText.text(.init(rawValue: "memory_task_tool.known.v1.4"))
                    + "\(name)")) }
                return known
            }
            var content: TaskValue.Content?
            if let text = item["value"].string {
                if secret || minimization.minimize(text: text).1 != nil {
                    secrets.append(text)
                    content = .withheld
                } else {
                    content = .text(text)
                }
            }
            parameters.append(try ParameterStatement(
                name         : name,
                role         : kept(role) ?? role,
                kind         : kind,
                direction    : direction,
                unit         : kept(item["unit"].string),
                sensitivity  : secret ? .secret : .ordinary,
                content      : content,
                source       : source,
                sourceRef    : item["source_ref"].string.map { TaskOutputReference.kept($0, by: minimization) },
                sourceVersion: item["source_version"].string.map {
                    TaskOutputReference.keptVersion($0, reference: item["source_ref"].string, by: minimization)
                },
                producedBy   : try item["produced_by"].string.map(reference)
            ))
        }
        var uses: [UseStatement] = []
        for item in arguments["uses"].array ?? [] {
            guard let argument = item["argument"].string, let template = item["template"].string else {
                throw invalidInterpretation(ModelText.text(.init(rawValue: "memory_task_tool.template.v1")))
            }
            let position: Int
            if item["position"] == .null { position = 0 } else {
                guard case .number(let number) = item["position"], let integer = Int(exactly: number), integer >= 0 else {
                    throw invalidInterpretation(ModelText.text(.init(rawValue: "memory_task_tool.integer.v1.2")))
                }
                position = integer
            }
            uses.append(try UseStatement(stepPosition: try whole(item["step"], "a use's step") - 1, argumentName: argument,
                                         argumentPosition: position, pieces: try UsePiece.parse(template)))
        }
        let revision = arguments["revision"] == .null ? nil : try whole(arguments["revision"], "revision")
        let divergence = arguments["divergence_step"] == .null ? nil : try whole(arguments["divergence_step"], "divergence_step") - 1
        return .interpret(try ProcedureInterpretation(
            candidateID       : candidate,
            revision          : revision,
            parts             : parts,
            parameters        : parameters,
            uses              : uses,
            variantOf         : optionalText(arguments, "variant_of"),
            divergencePosition: divergence
        ), secrets: secrets, checks: [])
    }

    /// The plan of a `choose`: the proposal and, per need (from 1), its tracts (a source of the proposal, the first and last
    /// steps from 1), how much of the need they cover and what remains, minimized as every text of the agent's is.
    private static func plan(_ arguments: JSONValue, _ minimization: ValueMinimization) throws -> RecallChoice.Plan {
        guard let proposal = optionalText(arguments, "proposal") else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.proposal.v1"))) }
        guard let items = arguments["plan"].array, items.count <= RecallContract.maximumNeeds else {
            throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.items.v1")))
        }
        func whole(_ value: JSONValue, _ what: String) throws -> Int {
            guard case .number(let number) = value, let integer = Int(exactly: number), integer >= 1 else {
                throw invalid(("\(what)" + ModelText.text(.init(rawValue: "memory_task_tool.integer.v1.3"))))
            }
            return integer
        }
        let needs = try items.map { item -> RecallChoice.PlannedNeed in
            let need = try whole(item["need"], ModelText.text(.init(rawValue: "memory_task_tool.need.v1")))
            guard let covered = item["covered"].string.flatMap(RecallChoice.Declared.init(rawValue:)) else {
                throw invalid((ModelText.text(.init(rawValue: "memory_task_tool.covered.v1"))
                    + "\(need)"
                    + ModelText.text(.init(rawValue: "memory_task_tool.covered.v1.2"))))
            }
            func tracts(_ field: String) throws -> [RecallChoice.Tract] {
                guard item[field] != .null else { return [] }
                guard let list = item[field].array, list.count <= RecallContract.candidateLimit else {
                    throw invalid((ModelText.text(.init(rawValue: "memory_task_tool.list.v1"))
                        + "\(need)"
                        + ModelText.text(.init(rawValue: "memory_task_tool.list.v1.2"))
                        + "\(field)"
                        + ModelText.text(.init(rawValue: "memory_task_tool.list.v1.3"))))
                }
                return try list.map { tract -> RecallChoice.Tract in
                    guard let source = tract["source"].string, !source.isEmpty else { throw invalid((ModelText.text(.init(rawValue: "memory_task_tool.source.v1"))
                        + "\(need)"
                        + ModelText.text(.init(rawValue: "memory_task_tool.source.v1.2")))) }
                    return RecallChoice.Tract(key: source, first: try whole(tract["from"], "from") - 1, last: try whole(tract["to"], "to") - 1)
                }
            }
            func text(_ field: String) throws -> String? {
                let value = item[field].string.flatMap { $0.isEmpty ? nil : minimization.minimize(text: $0).0 }
                if let value, value.utf8.count > TaskContextContract.maximumTextBytes { throw invalid((ModelText.text(.init(rawValue: "memory_task_tool.value.v1"))
                    + "\(need)"
                    + ModelText.text(.init(rawValue: "memory_task_tool.value.v1.2"))
                    + "\(field)"
                    + ModelText.text(.init(rawValue: "memory_task_tool.value.v1.3")))) }
                return value
            }
            return RecallChoice.PlannedNeed(position: need - 1, tracts: try tracts("tracts"), declared: covered, uncovered: try text("uncovered"),
                                            alternatives: try tracts("alternatives"), settledBy: try text("settled_by"))
        }
        return RecallChoice.Plan(proposalID: proposal, needs: needs)
    }

    /// The needs a request names, each a text with an optional application, minimized as every task text is.
    private static func needs(_ arguments: JSONValue, _ minimization: ValueMinimization) throws -> [RecallNeed] {
        guard arguments["needs"] != .null else { return [] }
        guard let items = arguments["needs"].array, items.count <= RecallContract.maximumNeeds else {
            throw invalid((ModelText.text(.init(rawValue: "memory_task_tool.items.v1.2"))
                + ModelText.render(.init(rawValue: "memory_task_tool.needLimit.v1"), ["count": .count(RecallContract.maximumNeeds)])
                + ModelText.text(.init(rawValue: "memory_task_tool.items.v1.3"))))
        }
        return try items.map { item in
            guard let text = item["text"].string ?? item.string else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.text.v1"))) }
            return try RecallNeed(text: minimization.minimize(text: text).0, bundleID: item["app"].string.map { minimization.minimize(text: $0).0 })
        }
    }

    /// The use reports of a request: the query, the need from 1, the declared outcome, an optional cause and note.
    private static func reports(_ list: JSONValue, _ minimization: ValueMinimization) throws -> [UseReport] {
        guard list != .null else { return [] }
        guard let items = list.array else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.items.v1.4"))) }
        return try items.map { item in
            guard let query = item["query"].string, !query.isEmpty else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.query.v1"))) }
            let need: Int
            if item["need"] == .null { need = 1 } else {
                guard case .number(let number) = item["need"], let whole = Int(exactly: number), whole >= 1 else {
                    throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.whole.v1.2")))
                }
                need = whole
            }
            guard let outcome = item["outcome"].string, ["followed", "adapted", "abandoned", "not_executed"].contains(outcome) else {
                throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.outcome.v1.2")))
            }
            let cause = item["cause"].string
            if let cause, !["method", "driver", "application", "agent", "input", "unknown"].contains(cause) {
                throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.cause.v1")))
            }
            return UseReport(queryID: query, needPosition: need - 1, declared: outcome, cause: cause,
                             note: item["note"].string.map { minimization.minimize(text: $0).0 })
        }
    }

    /// The result checks a call names under `result_check`: one object or a list of them, each one kind
    /// (`TaskResultCheck.Expectation`). A path is absolute (a leading ~ is the home folder); `file` alone is a file
    /// written, with `contains` a text file holding it.
    static func resultChecks(_ value: JSONValue, minimization: ValueMinimization) throws -> [ResultCheck] {
        guard value != .null else { return [] }
        let items = value.array ?? [value]
        guard items.count <= 8 else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.items.v1.5"))) }
        func path(_ text: String) throws -> String {
            let expanded = (text as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.expanded.v1"))) }
            return (expanded as NSString).standardizingPath
        }
        let read = try items.map { item -> TaskResultCheck.Expectation in
            guard let fields = item.object, !fields.isEmpty else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.fields.v1"))) }
            let app = item["app"].string.flatMap { $0.isEmpty ? nil : $0 }
            let simple: [(String, (String) -> TaskResultCheck.Expectation)] = [
                ("file_written", { .fileWritten(path: $0) }), ("file_changed", { .fileChanged(path: $0) }),
                ("file_unchanged", { .fileUnchanged(path: $0) }), ("file_absent", { .fileAbsent(path: $0) }),
            ]
            for (key, make) in simple {
                if let file = item[key].string { return make(try path(file)) }
            }
            for key in ["file_moved", "file_copied"] {
                guard let from = item[key].string else { continue }
                guard let to = item["to"].string else { throw invalid(("\(key)" + ModelText.text(.init(rawValue: "memory_task_tool.to.v1")))) }
                return key == "file_moved" ? .fileMoved(from: try path(from), to: try path(to)) : .fileCopied(from: try path(from), to: try path(to))
            }
            if let file = item["file"].string {
                if let text = item["contains"].string, !text.isEmpty { return .fileContains(path: try path(file), text: text) }
                return .fileWritten(path: try path(file))
            }
            if let title = item["window"].string, !title.isEmpty {
                return .window(app: app, title: title, open: item["open"].bool ?? true)
            }
            if let label = item["element"].string, !label.isEmpty {
                if let value = item["value"].string { return .element(app: app, label: label, expect: .value(value)) }
                if let word = item["state"].string {
                    guard let state = ControlState(rawValue: word), state != .unknown else { throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.state.v1"))) }
                    return .element(app: app, label: label, expect: .state(state))
                }
                return .element(app: app, label: label, expect: item["present"].bool == false ? .absent : .present)
            }
            if let folder = item["no_other_files"].string {
                guard let named = item["named"].array, named.allSatisfy({ $0.string != nil }) else {
                    throw invalid(ModelText.text(.init(rawValue: "task_cycle.named_files.v2")))
                }
                return .noOtherFiles(folder: try path(folder), named: named.compactMap(\.string))
            }
            if let reason = item["none"].string, !reason.isEmpty { return .nothing(reason: reason) }
            throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.reason.v1.3"))
                          + ModelText.text(.init(rawValue: "memory_task_tool.reason.v1.4")))
        }
        return read.map { ResultCheck(read: $0, kept: Self.kept($0, by: minimization)) }
    }

    /// An expectation as the archive keeps it: every path and text minimized, and the reason of `none` too.
    static func kept(_ expectation: TaskResultCheck.Expectation, by minimization: ValueMinimization) -> TaskResultCheck.Expectation {
        if case .nothing(let reason) = expectation { return .nothing(reason: minimization.minimize(text: reason).0) }
        return expectation.mapTexts { minimization.minimize(text: $0).0 }
    }

    /// The files a completed task's outputs declare by an absolute path: what Braus checks were written when the end
    /// names no result check.
    static func declaredFiles(_ outputs: JSONValue, minimization: ValueMinimization) -> [ResultCheck] {
        (outputs.array ?? []).compactMap { item -> ResultCheck? in
            guard item["kind"].string == "file", item["secret"].bool != true, let text = item["value"].string else { return nil }
            let expanded = (text as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return nil }
            let read = TaskResultCheck.Expectation.fileWritten(path: (expanded as NSString).standardizingPath)
            return ResultCheck(read: read, kept: Self.kept(read, by: minimization))
        }
    }

    private static func invalidInterpretation(_ message: String) -> Failure {
        Failure(code: "invalid_interpretation", message: (ModelText.text(.init(rawValue: "memory_task_tool.invalidInterpretation.v1"))
            + "\(message)"
            + ModelText.text(.init(rawValue: "memory_task_tool.invalidInterpretation.v1.2"))))
    }

    /// The named values of `inputs` or `outputs`: a secret's text is withheld and kept aside, a text with
    /// a credential's shape or holding a known secret is withheld whole too, a value with no text is a
    /// missing input, and the texts that describe a value (name, role, source) are minimized.
    private static func values(_ list: JSONValue, minimization: ValueMinimization, secrets: inout [String],
                               outputs: Bool) throws -> [TaskValue] {
        guard list != .null else { return [] }
        guard let items = list.array else { throw invalid(("\(outputs ? "outputs" : "inputs")"
            + ModelText.text(.init(rawValue: "memory_task_tool.items.v1.6")))) }
        return try items.map { item in
            guard let fields = item.object, let name = item["name"].string, !name.isEmpty else {
                throw invalid(ModelText.text(.init(rawValue: "memory_task_tool.name.v1")))
            }
            let allowed: Set<String> = ["name", "value", "kind", "role", "source", "source_ref", "source_version",
                                        "secret"]
            guard Set(fields.keys).isSubset(of: allowed) else { throw invalid((ModelText.text(.init(rawValue: "memory_task_tool.allowed.v1.2"))
                + "\(name)")) }
            let secret = item["secret"].bool ?? false
            let source = try item["source"].string.map { word -> TaskValueSource in
                guard let known = TaskValueSource(rawValue: word) else {
                    throw invalid((ModelText.text(.init(rawValue: "memory_task_tool.known.v1.5")) + "\(name)"))
                }
                return known
            } ?? (outputs ? .derived : .request)
            let declared = try item["kind"].string.map { word -> TaskValueKind in
                guard let known = TaskValueKind(rawValue: word), known != .missing else {
                    throw invalid((ModelText.text(.init(rawValue: "memory_task_tool.known.v1.6")) + "\(name)"))
                }
                return known
            } ?? .text
            let kind: TaskValueKind
            let content: TaskValue.Content
            let sensitivity: TaskValueSensitivity = secret ? .secret : .ordinary
            switch item["value"] {
                case .string(let text) where !text.isEmpty:
                    kind = declared
                    if secret {
                        secrets.append(text)
                        content = .withheld
                    } else if minimization.minimize(text: text).1 != nil {
                        secrets.append(text)
                        content = .withheld
                    } else {
                        content = .text(text)
                    }
                case .null, .string:
                    guard !outputs else { throw invalid((ModelText.text(.init(rawValue: "answer.MemoryTaskTool.text.v1.fragment.0"))
                        + "\(name)"
                        + ModelText.text(.init(rawValue: "answer.MemoryTaskTool.text.v1.fragment.2")))) }
                    kind    = .missing
                    content = .missing
                default:
                    throw invalid((ModelText.text(.init(rawValue: "memory_task_tool.text.v1.2"))
                        + "\(name)"
                        + ModelText.text(.init(rawValue: "memory_task_tool.text.v1.3"))))
            }
            func kept(_ text: String?) -> String? { text.map { minimization.minimize(text: $0).0 } }
            return try TaskValue(
                name         : kept(name) ?? name,
                role         : kept(item["role"].string),
                kind         : kind,
                content      : content,
                sensitivity  : sensitivity,
                source       : source,
                sourceRef    : item["source_ref"].string.map { TaskOutputReference.kept($0, by: minimization) },
                sourceVersion: item["source_version"].string.map {
                    TaskOutputReference.keptVersion($0, reference: item["source_ref"].string, by: minimization)
                }
            )
        }
    }

    /// The values the arguments declare secret, and those with a credential's shape: what every record
    /// of the request, its transcript first, withholds before any of it is written.
    static func declaredSecrets(in arguments: JSONValue) -> [String] {
        var found: [String] = []
        for key in ["inputs", "outputs", "parameters"] {
            for item in arguments[key].array ?? [] {
                guard let text = item["value"].string, !text.isEmpty, !found.contains(text) else { continue }
                let verdict = SensitivityClassifier().classify(
                    text,
                    in: .init(declaredSecret: item["secret"].bool == true)
                )
                if verdict.sensitivity == .secret { found.append(text) }
            }
        }
        return found
    }

    /// A stored value minimized by what is known now: its describing texts minimized, its text withheld
    /// whole when it holds a secret, since part of a value is no value anyone gave.
    static func minimized(_ value: TaskValue, by minimization: ValueMinimization) throws -> TaskValue {
        func kept(_ text: String?) -> String? { text.map { minimization.minimize(text: $0).0 } }
        var content = value.content
        if case .text(let text) = value.content, minimization.minimize(text: text).1 != nil { content = .withheld }
        return try TaskValue(
            name         : kept(value.name) ?? value.name,
            role         : kept(value.role),
            kind         : value.kind,
            content      : content,
            sensitivity  : value.sensitivity,
            source       : value.source,
            sourceRef    : value.sourceRef.map { TaskOutputReference.kept($0, by: minimization) },
            sourceVersion: value.sourceVersion.map { TaskOutputReference.keptVersion($0, reference: value.sourceRef, by: minimization) }
        )
    }

    private static func optionalText(_ arguments: JSONValue, _ key: String) -> String? {
        guard let text = arguments[key].string, !text.isEmpty else { return nil }
        return text
    }

    private static func texts(_ arguments: JSONValue, _ key: String) throws -> [String]? {
        guard arguments.object?[key] != nil else { return nil }
        guard let items = arguments[key].array else { throw invalid(("\(key)" + ModelText.text(.init(rawValue: "memory_task_tool.items.v1.7")))) }
        return try items.map { item in
            guard let text = item.string, !text.isEmpty else { throw invalid(("\(key)"
                + ModelText.text(.init(rawValue: "memory_task_tool.text.v1.4")))) }
            return text
        }
    }

    private static func invalid(_ message: String) -> Failure {
        Failure(code: "invalid_task", message: (ModelText.text(.init(rawValue: "memory_task_tool.invalid.v1"))
            + "\(message)"
            + ModelText.text(.init(rawValue: "memory_task_tool.invalid.v1.2"))))
    }
}
