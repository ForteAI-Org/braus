import Memory

/// Procedure assembly reads the request and execution status, without decoding an obsolete outcome representation.
enum DB2CProcedureCallRows {
    struct Call {
        let request: AgentCallRequest
        let status: AgentCallStatus
    }

    static func read(_ handle: some SQLiteQuerying, eventID: String) throws -> Call? {
        guard try SQLiteRowIdentity(handle).usesIntegerKeys else {
            return try SQLiteAgentCallRows.call(handle, eventID: eventID).map { Call(request: $0.request, status: $0.progress.status) }
        }
        let key = try DB2CIdentity.key(handle, "memory_events", eventID)
        guard let header = try handle.query("SELECT tool_kind,execution_status,contract_version FROM memory_agent_actions WHERE event_id=?", [key], {
            (try $0.text(0) ?? "", try $0.text(1) ?? "", $0.integer(2) ?? 0)
        }).first else { return nil }
        guard header.2 == Int64(AgentCallContract.version) else {
            throw AgentCallError.unsupportedContractVersion(eventID: eventID, version: Int(header.2))
        }
        guard let tool = AgentTool(rawValue: header.0), let status = AgentCallStatus(rawValue: header.1) else {
            throw SQLiteProcedureRows.malformed("memory_agent_actions", eventID, "tool or status")
        }
        let arguments = try handle.query("""
            SELECT argument_name,position,value_kind,text_value,integer_value,real_value,boolean_value,
                   operation_id,brain_application_id,route_id,parameter_id,anchor_id,menu_command_id
            FROM memory_operation_arguments WHERE event_id=? ORDER BY argument_id
            """, [key]) { row -> BrainArgument in
                func refuse(_ malformation: AgentCallError.Malformation) -> AgentCallError {
                    .malformedCall(eventID: eventID, malformation: malformation)
                }
                for (index, column) in [(7,"operation_id"),(8,"brain_application_id"),(9,"route_id"),(10,"parameter_id"),
                                        (11,"anchor_id"),(12,"menu_command_id")] where !row.isNull(index) {
                    throw refuse(.forbiddenColumn(column))
                }
                let name = try row.text(0) ?? "", set = [3,4,5,6].filter { !row.isNull($0) }
                let value: BrainArgument.Value
                switch (try row.text(2) ?? "", set) {
                case ("text", [3]): value = .text(try row.text(3) ?? "")
                case ("integer", [4]): value = .integer(row.integer(4) ?? 0)
                case ("real", [5]): value = .real(row.real(5) ?? 0)
                case ("boolean", [6]): value = .boolean(row.integer(6) == 1)
                default: throw refuse(.argumentKindMismatch(name))
                }
                return BrainArgument(name: name, position: Int(row.integer(1) ?? -1), value: value)
            }
        return Call(request: try AgentCallRequest(tool: tool, arguments: arguments, eventID: eventID), status: status)
    }
}
