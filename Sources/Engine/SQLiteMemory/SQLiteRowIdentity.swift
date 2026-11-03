/// SQLiteRowIdentity borrows one transaction's identity lookups at a repository boundary.
/// UUIDs enter and leave the repository; schema 22 statements bind local integer keys. Schema 19 retains its text keys.
struct SQLiteRowIdentity<Handle: SQLiteQuerying> {
    enum Entity {
        case event, attempt

        var columns: (table: String, id: String, uuid: String) {
            switch self {
            case .event: ("memory_events", "event_id", "event_uuid")
            case .attempt: ("memory_task_occurrences", "task_occurrence_id", "task_occurrence_uuid")
            }
        }
    }

    private let handle: Handle
    let usesIntegerKeys: Bool

    init(_ handle: Handle) throws {
        self.handle = handle
        usesIntegerKeys = try handle.query("PRAGMA user_version", []) { $0.integer(0) }.first == 22
    }

    func key(_ entity: Entity, _ uuid: String?) throws -> SQLiteValue {
        guard let uuid else { return .null }
        guard usesIntegerKeys else { return .text(uuid) }
        let columns = entity.columns
        let found = try handle.query("SELECT \(columns.id) FROM \(columns.table) WHERE \(columns.uuid)=?", [.text(uuid)]) {
            $0.integer(0)
        }.first ?? nil
        return found.map(SQLiteValue.integer) ?? .null
    }

    /// Returns a scalar expression for a saved reference. The column is a module-owned SQL literal.
    func publicReference(_ entity: Entity, column: String) -> String {
        guard usesIntegerKeys else { return column }
        let columns = entity.columns
        return "(SELECT \(columns.uuid) FROM \(columns.table) identity_row WHERE identity_row.\(columns.id)=\(column))"
    }
}
