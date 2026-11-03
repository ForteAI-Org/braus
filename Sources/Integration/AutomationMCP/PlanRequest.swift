import Foundation
import LocalMCP
import Memory

/// PlanRequest validates an entire plan before the handler can write or search memory.
struct PlanRequest {
    struct Row {
        let id: TodoRowID?
        let title: String
        let app: String?
        let part: String?
        let expected: MemoryTaskTool.ResultCheck?
    }
    let request: String?
    let inputs: [TaskValue]?
    /// Original arguments supply volatile file baselines, separately from the admitted task values.
    let rawInputs: JSONValue
    let rows: [Row]
    let reason: String?
    let secrets: [String]

    init(_ arguments: JSONValue, minimization: ValueMinimization, messageRef: String?) throws {
        guard let fields = arguments.object,
              Set(fields.keys).isSubset(of: ["request", "inputs", "rows", "reason"]),
              let rows = arguments["rows"].array, !rows.isEmpty else {
            throw MemoryTaskTool.Failure(code: "invalid_plan", message: ModelText.text(.init(rawValue: "task_cycle.rows_required.v2")))
        }
        guard rows.count <= Todo.rowLimit else {
            throw MemoryTaskTool.Failure(code: "todo_row_limit", message: ModelText.text(.init(rawValue: "task_cycle.limit.v2")))
        }
        let declared = MemoryTaskTool.declaredSecrets(in: arguments)
        let minimization = minimization.adding(secrets: declared)
        var begin: [String: JSONValue] = ["operation": .string("begin"), "goal": arguments["request"] == .null
            ? .string("Plan revision") : arguments["request"], "recall": .bool(false)]
        if fields["inputs"] != nil { begin["inputs"] = arguments["inputs"] }
        guard case .begin(let content, _, _) = try MemoryTaskTool.decode(.object(begin),
            minimization: minimization, messageRef: messageRef) else {
            throw MemoryTaskTool.Failure(code: "invalid_plan", message: ModelText.text(.init(rawValue: "task_cycle.inputs_invalid.v2")))
        }
        self.request = fields["request"] == nil ? nil : content.goal
        inputs = fields["inputs"] == nil ? nil : content.inputs
        rawInputs = arguments["inputs"]
        reason = try ToolArguments.optionalString(arguments, "reason").map { minimization.minimize(text: $0).0 }
        guard (reason?.utf8.count ?? 0) <= 200 else {
            throw MemoryTaskTool.Failure(code: "invalid_plan", message: ModelText.text(.init(rawValue: "task_cycle.reason_limit.v2")))
        }
        secrets = declared
        self.rows = try rows.map { row in
            guard let fields = row.object,
                  Set(fields.keys).isSubset(of: ["id", "title", "app", "part", "expect"]) else {
                throw MemoryTaskTool.Failure(code: "invalid_plan", message: ModelText.text(.init(rawValue: "task_cycle.row_fields.v2")))
            }
            let title = try ToolArguments.requiredString(row, "title")
            guard title.count <= Todo.titleLimit else {
                throw MemoryTaskTool.Failure(code: "todo_title_limit", message: ModelText.text(.init(rawValue: "task_cycle.title_limit.v2")))
            }
            let checks = try MemoryTaskTool.resultChecks(row["expect"], minimization: minimization)
            let expectedLength: Int
            if case .nothing(let reason) = checks.first?.read { expectedLength = reason.count }
            else { expectedLength = checks.first?.read.texts.joined().count ?? 0 }
            guard checks.count <= 1, expectedLength <= Todo.expectedLimit else {
                throw MemoryTaskTool.Failure(code: "todo_expected_limit", message: ModelText.text(.init(rawValue: "task_cycle.expected_limit.v2")))
            }
            return Row(id: try ToolArguments.optionalString(row, "id").map(TodoRowID.init(rawValue:)),
                       title: minimization.minimize(text: title).0, app: try ToolArguments.optionalString(row, "app").map { minimization.minimize(text: $0).0 },
                       part: try ToolArguments.optionalString(row, "part"), expected: checks.first)
        }
    }
}

/// EndRequest keeps the legacy result predicate vocabulary and restricts closure to terminal outcomes.
struct EndRequest {
    let outcome: DeclaredTaskStatus
    let note: String?
    let checks: [MemoryTaskTool.ResultCheck]

    init(_ arguments: JSONValue, minimization: ValueMinimization) throws {
        guard let fields = arguments.object,
              Set(fields.keys).isSubset(of: ["outcome", "note", "result_check"]),
              let word = arguments["outcome"].string,
              let outcome = DeclaredTaskStatus(rawValue: word), outcome != .open else {
            throw MemoryTaskTool.Failure(code: "invalid_end", message: ModelText.text(.init(rawValue: "task_cycle.end_outcome.v2")))
        }
        self.outcome = outcome
        note = try ToolArguments.optionalString(arguments, "note").map { minimization.minimize(text: $0).0 }
        checks = try MemoryTaskTool.resultChecks(arguments["result_check"], minimization: minimization)
    }
}
