import Memory

/// DB2BExperiences writes integer-owned experience rows and returns the store's identity.
enum DB2BExperiences {
    static func parameters(_ handle: some SQLiteQuerying, route: String) throws -> [RouteParameter] {
        let key = try DB2BKeys.key(handle, route, table: "memory_routes", id: "route_id", uuid: "route_uuid")
        return try handle.query(
            """
            SELECT \(try DB2CIdentity.publicReference(handle, "memory_route_parameters", "parameter_id")),name,direction,value_type,is_required FROM memory_route_parameters WHERE route_id=?
            """,
            [key]
        ) { row in
            guard let direction = ParameterDirection(rawValue: try row.text(2) ?? ""),
                let type = ParameterValueType(rawValue: try row.text(3) ?? "")
            else {
                throw EventFactError.missingDefinition(id: route)
            }
            return RouteParameter(
                parameterID: try row.text(0) ?? "",
                name: try row.text(1) ?? "",
                direction: direction,
                valueType: type,
                isRequired: row.integer(4) == 1
            )
        }
    }

    static func insert(
        _ transaction: SQLiteTransaction,
        _ offered: ExperienceRecord
    ) throws -> (receipt: MemoryReceipt, experience: ExperienceRecord) {
        let route = try DB2BKeys.key(
            transaction,
            offered.routeID,
            table: "memory_routes",
            id: "route_id",
            uuid: "route_uuid"
        )
        guard route != .null else { throw EventFactError.missingDefinition(id: offered.routeID) }
        if let step = offered.stepID {
            let key = try DB2CIdentity.key(transaction, "memory_route_steps", step)
            guard key != .null, try transaction.query(
                    "SELECT count(*) FROM memory_route_steps WHERE step_id=? AND route_id=?",
                    [key, route],
                    { $0.integer(0) ?? 0 }
                ).first == 1
            else { throw EventFactError.missingDefinition(id: step) }
        }
        try SQLiteExperienceRows.checkBindings(transaction, offered)
        try transaction.execute(
            """
            INSERT INTO memory_experiences(phrase,route_id,step_id,created_at_ms) VALUES (?,?,?,?)
            """,
            [
                .text(offered.phrase), route, try DB2CIdentity.key(transaction, "memory_route_steps", offered.stepID),
                .integer(offered.createdAtMS),
            ]
        )
        let id = try SQLiteIdentityRows.lastInsertedRow(transaction)
        for binding in offered.bindings {
            let parameter = try DB2CIdentity.key(transaction, "memory_route_parameters", binding.parameterID)
            guard parameter != .null else {
                throw EventFactError.missingDefinition(id: binding.parameterID)
            }
            var values: [SQLiteValue] = Array(repeating: .null, count: 5)
            let kind: String
            switch binding.source {
            case .literal(let literal):
                kind = "literal"
                switch literal {
                case .text(let value): values[1] = .text(value)
                case .integer(let value): values[2] = .integer(value)
                case .real(let value): values[3] = .real(value)
                case .boolean(let value): values[4] = .integer(value ? 1 : 0)
                }
            case .requestSlot(let name):
                kind = "request_slot"
                values[0] = .text(name)
            case .contextSlot(let name):
                kind = "context_slot"
                values[0] = .text(name)
            }
            try transaction.execute(
                """
                INSERT INTO memory_experience_bindings(experience_id,route_id,parameter_id,value_type,binding_kind,
                    binding_contract_version,slot_name,literal_text,literal_integer,literal_real,literal_boolean)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """,
                [
                    .integer(id), route, parameter, .text(binding.valueType.rawValue), .text(kind),
                    .integer(Int64(ExperienceBinding.contractVersion)),
                ] + values
            )
        }
        return (.committed, try copy(offered, id: String(id)))
    }

    private static func copy(_ value: ExperienceRecord, id: String) throws -> ExperienceRecord {
        try ExperienceRecord(
            experienceID: id,
            phrase: value.phrase,
            routeID: value.routeID,
            stepID: value.stepID,
            createdAtMS: value.createdAtMS,
            bindings: value.bindings
        )
    }
}
