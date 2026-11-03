import EngineCore
import Memory
import PerceptionCore

extension SQLiteRouteRows {
    static func insert22(_ transaction: SQLiteTransaction, _ definition: RouteDefinition, state: RouteState) throws {
        let routeID = definition.routeID
        let ids = try DB2CRouteIdentity(transaction, definition: definition)
        try transaction.execute(
            """
            INSERT INTO memory_routes (route_id, route_uuid, name, status, supersedes_route_id, created_at_ms, last_used_ms, demoted_at_ms, demotion_cause)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [try ids.key("memory_routes", routeID), .text(definition.routeID), .text(definition.name), .text(state.status.rawValue), try ids.key("memory_routes", definition.supersedesRouteID),
             .integer(definition.createdAtMS), state.lastUsedMS.map(SQLiteValue.integer) ?? .null,
             state.demotedAtMS.map(SQLiteValue.integer) ?? .null, state.demotionCause.map(SQLiteValue.text) ?? .null]
        )
        for parameter in definition.parameters {
            try transaction.execute(
                "INSERT INTO memory_route_parameters (parameter_id, route_id, name, direction, value_type, is_required) VALUES (?, ?, ?, ?, ?, ?)",
                [try ids.key("memory_route_parameters", parameter.parameterID), try ids.key("memory_routes", routeID), .text(parameter.name), .text(parameter.direction.rawValue),
                 .text(parameter.valueType.rawValue), .integer(parameter.isRequired ? 1 : 0)]
            )
        }
        for step in definition.steps {
            let appID = try step.bundleID.map { try SQLiteIdentityRows.ensureApp(transaction, bundleID: $0) }
            var callee: String?
            if case .routeCall(let called, _) = step.kind { callee = called }
            try transaction.execute(
                "INSERT INTO memory_route_steps (step_id, route_id, position, step_kind, goal_text, app_id, called_route_id) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [try ids.key("memory_route_steps", step.stepID), try ids.key("memory_routes", routeID), .integer(Int64(step.position)), .text(callee == nil ? "goal" : "route_call"),
                 .text(step.goalText), appID.map(SQLiteValue.integer) ?? .null, try ids.key("memory_routes", callee)]
            )
            for check in step.checks {
                if let scene = check.sceneID { try reference(transaction, "scene", scene, appID: appID) }
                if let anchor = check.anchorID { try reference(transaction, "anchor", anchor, appID: appID) }
                var expected: [SQLiteValue] = Array(repeating: .null, count: 6)
                switch check.expected {
                    case .state(let state)?   : expected[0] = .text(state.rawValue)
                    case .text(let text)?     : expected[1] = .text(text)
                    case .integer(let value)? : expected[2] = .integer(value)
                    case .real(let value)?    : expected[3] = .real(value)
                    case .boolean(let flag)?  : expected[4] = .integer(flag ? 1 : 0)
                    case .parameter(let id)?  : expected[5] = try ids.key("memory_route_parameters", id)
                    case nil                  : break
                }
                try transaction.execute(
                    """
                    INSERT INTO memory_step_checks (check_id, route_id, step_id, app_id, position, check_kind, expected_scene_id, expected_anchor_id,
                        expected_state, expected_text, expected_integer, expected_real, expected_bool, expected_parameter_id, comparison)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [try ids.key("memory_step_checks", check.checkID), try ids.key("memory_routes", routeID), try ids.key("memory_route_steps", step.stepID), appID.map(SQLiteValue.integer) ?? .null, .integer(Int64(check.position)),
                     .text(check.kind.rawValue), try ids.key("brain_scenes", check.sceneID), try ids.key("brain_anchors", check.anchorID)]
                        + expected + [check.comparison.map { .text($0.rawValue) } ?? .null]
                )
            }
            for operation in step.operations {
                try insert22(transaction, operation, parent: nil, routeID: routeID, stepID: step.stepID, appID: appID, ids: ids)
                for child in operation.children {
                    try insert22(transaction, child, parent: operation.operationID, routeID: routeID, stepID: step.stepID, appID: appID, ids: ids)
                }
            }
            if case .routeCall(let called, let bindings) = step.kind {
                for binding in bindings {
                    var values: [SQLiteValue] = Array(repeating: .null, count: 5)
                    switch binding.source {
                        case .parameter(let id)         : values[0] = try ids.key("memory_route_parameters", id)
                        case .literal(.text(let text))  : values[1] = .text(text)
                        case .literal(.integer(let v))  : values[2] = .integer(v)
                        case .literal(.real(let v))     : values[3] = .real(v)
                        case .literal(.boolean(let v))  : values[4] = .integer(v ? 1 : 0)
                    }
                    try transaction.execute(
                        """
                        INSERT INTO memory_route_call_bindings (step_id, route_id, called_route_id, called_parameter_id, source_parameter_id,
                            literal_text, literal_integer, literal_real, literal_bool) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [try ids.key("memory_route_steps", step.stepID), try ids.key("memory_routes", routeID), try ids.key("memory_routes", called), try DB2CIdentity.key(transaction, "memory_route_parameters", binding.calledParameterID)] + values
                    )
                }
            }
        }
    }

    private static func insert22(_ transaction: SQLiteTransaction, _ operation: StepOperation, parent: String?, routeID: String, stepID: String,
                               appID: Int64?, ids: DB2CRouteIdentity) throws {
        try transaction.execute(
            """
            INSERT INTO memory_step_operations (operation_id, route_id, step_id, parent_operation_id, position, tool_kind, contract_version, app_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [try ids.key("memory_step_operations", operation.operationID), try ids.key("memory_routes", routeID), try ids.key("memory_route_steps", stepID), try ids.key("memory_step_operations", parent), .integer(Int64(operation.position)),
             .text(operation.tool.rawValue), .integer(Int64(AgentCallContract.version)), appID.map(SQLiteValue.integer) ?? .null]
        )
        for (index, argument) in operation.arguments.enumerated() {
            if case .template(let segments) = argument.value {
                for (position, segment) in segments.enumerated() {
                    let (kind, literal, parameter): (String, SQLiteValue, SQLiteValue) = switch segment {
                        case .literal(let text)   : ("literal", .text(text), .null)
                        case .parameter(let id)   : ("parameter", .null, try ids.key("memory_route_parameters", id))
                    }
                    try transaction.execute(
                        """
                        INSERT INTO memory_operation_argument_segments (route_id, operation_id, argument_name, argument_position,
                            argument_index, segment_position, segment_kind, literal_text, parameter_id)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [try ids.key("memory_routes", routeID), try ids.key("memory_step_operations", operation.operationID), .text(argument.name), .integer(Int64(argument.position)),
                         .integer(Int64(index)), .integer(Int64(position)), .text(kind), literal, parameter]
                    )
                }
                continue
            }
            let (kind, column, value): (String, String, SQLiteValue)
            switch argument.value {
                case .literal(.text(let text))   : (kind, column, value) = ("text", "text_value", .text(text))
                case .literal(.integer(let v))   : (kind, column, value) = ("integer", "integer_value", .integer(v))
                case .literal(.real(let v))      : (kind, column, value) = ("real", "real_value", .real(v))
                case .literal(.boolean(let v))   : (kind, column, value) = ("boolean", "boolean_value", .integer(v ? 1 : 0))
                case .parameter(let id)          : (kind, column, value) = ("parameter", "parameter_id", try ids.key("memory_route_parameters", id))
                case .anchor(let id):
                    try reference(transaction, "anchor", id, appID: appID)
                    (kind, column, value) = ("anchor", "anchor_id", try ids.key("brain_anchors", id))
                case .menu(let id):
                    try reference(transaction, "menu", id, appID: appID)
                    (kind, column, value) = ("menu", "menu_command_id", try ids.key("brain_menu_commands", id))
                case .template:
                    continue
            }
            try transaction.execute(
                """
                INSERT INTO memory_operation_arguments (operation_id, route_id, app_id, argument_name, position, value_kind, \(column))
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [try ids.key("memory_step_operations", operation.operationID), try ids.key("memory_routes", routeID), appID.map(SQLiteValue.integer) ?? .null, .text(argument.name),
                 .integer(Int64(argument.position)), .text(kind), value]
            )
        }
    }

}
