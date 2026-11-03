/// DB2BKeys resolves global task and definition identities without changing shared codecs.
enum DB2BKeys {
    static func local(_ handle: some SQLiteQuerying, _ value: String?) throws -> SQLiteValue {
        guard let value else { return .null }
        guard try SQLiteRowIdentity(handle).usesIntegerKeys else { return .text(value) }
        return Int64(value).map(SQLiteValue.integer) ?? .null
    }

    static func task(_ handle: some SQLiteQuerying, _ uuid: String) throws -> SQLiteValue {
        try key(handle, uuid, table: "memory_tasks", id: "task_id", uuid: "task_uuid")
    }

    static func key(_ handle: some SQLiteQuerying, _ value: String?, table: String, id: String, uuid: String) throws
        -> SQLiteValue
    {
        guard let value else { return .null }
        guard try SQLiteRowIdentity(handle).usesIntegerKeys else { return .text(value) }
        return try handle.query("SELECT \(id) FROM \(table) WHERE \(uuid)=?", [.text(value)]) {
            $0.integer(0).map(SQLiteValue.integer) ?? .null
        }.first ?? .null
    }

    static func taskReference(_ handle: some SQLiteQuerying, _ column: String) throws -> String {
        try SQLiteRowIdentity(handle).usesIntegerKeys
            ? "(SELECT task_uuid FROM memory_tasks identity_task WHERE identity_task.task_id=\(column))" : column
    }

    static func revision(_ handle: some SQLiteQuerying, task: String, number: Int) throws -> SQLiteValue {
        try handle.query(
            "SELECT task_revision_id FROM memory_task_revisions WHERE task_id=? AND revision=?",
            [try self.task(handle, task), .integer(Int64(number))]
        ) {
            $0.integer(0).map(SQLiteValue.integer) ?? .null
        }.first ?? .null
    }
}
