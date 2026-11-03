import Foundation

/// Converts the command facts admitted by the exact schema 20 and 21 shapes.
/// Arguments and parameter bindings retain their existing scalar conversion and identities.
enum SQLiteMigration22Commands {
    static func convert(in db: SQLiteConnection) throws -> Int {
        let calls = try db.prepare("SELECT event_id FROM memory_agent_actions WHERE tool_kind='command' ORDER BY event_id")
        defer { calls.finalize() }
        while try calls.step() {
            try Task.checkCancellation()
            guard let event = calls.row.integer(0) else { throw refusal("command call identity") }
            let capability = try command(in: db, owner: "event_id", id: event)
            let origin = capability.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? capability
            guard !origin.isEmpty else { throw refusal("command origin") }
            try db.run("""
                INSERT INTO memory_call_capabilities(event_id,capability_id,effect_class,channel,origin,origin_name)
                VALUES (?,?,'write','command','registered',?)
                """, [.integer(event), .text(capability), .text(origin)])
        }
        let steps = try db.run("""
            UPDATE memory_candidate_steps SET step_kind='capability_call'
            WHERE call_event_id IN (SELECT event_id FROM memory_call_capabilities)
            """)
        // Recorded route definitions carry command identifiers as scalar arguments. Their original
        // operation order is preserved, including commands nested in a list.
        let operations = try db.prepare("""
            WITH RECURSIVE ordered(operation_id,step_id,tool_kind,path) AS (
                SELECT operation_id,step_id,tool_kind,printf('%020d',position)
                FROM memory_step_operations WHERE parent_operation_id IS NULL
                UNION ALL
                SELECT child.operation_id,child.step_id,child.tool_kind,
                       parent.path || '/' || printf('%020d',child.position)
                FROM memory_step_operations child JOIN ordered parent ON child.parent_operation_id=parent.operation_id
            )
            SELECT operation_id,step_id FROM ordered WHERE tool_kind='command' ORDER BY step_id,path
            """)
        defer { operations.finalize() }
        var currentStep: Int64?
        var position: Int64 = 0
        var convertedDefinitions: Int64 = 0
        while try operations.step() {
            try Task.checkCancellation()
            guard let operation = operations.row.integer(0), let step = operations.row.integer(1) else {
                throw refusal("command step identity")
            }
            if currentStep != step { currentStep = step; position = 0 }
            let capability = try command(in: db, owner: "operation_id", id: operation)
            try db.run("INSERT INTO memory_step_capabilities(step_id,position,capability_id) VALUES (?,?,?)",
                       [.integer(step), .integer(position), .text(capability)])
            position += 1
            convertedDefinitions += 1
        }
        let definitions = try db.query("SELECT count(*) FROM memory_step_operations WHERE tool_kind='command'") { $0.integer(0) }.first ?? nil
        guard definitions == convertedDefinitions else { throw refusal("command operation hierarchy") }
        return steps
    }

    private static func command(in db: SQLiteConnection, owner: String, id: Int64) throws -> String {
        // owner is selected only by this converter, never from archive content.
        let arguments = try db.query("""
            SELECT value_kind,text_value,position FROM memory_operation_arguments
            WHERE \(owner)=? AND argument_name='command'
            """, [.integer(id)]) { (kind: try $0.text(0), value: try $0.text(1), position: $0.integer(2)) }
        guard arguments.count == 1, let argument = arguments.first, argument.kind == "text", argument.position == 0,
              let identifier = argument.value, !identifier.isEmpty else { throw refusal("command identifier") }
        return identifier
    }

    private static func refusal(_ reason: String) -> SQLiteMigration22.Refusal {
        .verificationFailed([reason])
    }
}
