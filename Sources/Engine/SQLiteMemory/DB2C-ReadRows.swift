import Foundation

/// Borrows a snapshot for retained read codecs that consume public keys. No projected row is stored or mutated.
/// Schema selection inside those codecs sees the historical logical vocabulary; the underlying store stays at 22.
final class DB2CReadRows<Handle: SQLiteQuerying>: SQLiteQuerying {
    private let handle: Handle
    private let integerKeys: Bool
    private let tables: Set<String>
    private var projections: [String: String] = [:]

    init(_ handle: Handle) throws {
        self.handle = handle
        integerKeys = try SQLiteRowIdentity(handle).usesIntegerKeys
        tables = integerKeys ? Set(try handle.query("SELECT name FROM sqlite_schema WHERE type='table'", []) { try $0.text(0) ?? "" }) : []
    }

    func query<T>(_ sql: String, _ bindings: [SQLiteValue], _ row: (SQLiteStatement.Row) throws -> T) throws -> [T] {
        guard integerKeys else { return try handle.query(sql, bindings, row) }
        let upper = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if upper == "PRAGMA USER_VERSION" { return try handle.query("SELECT 19", bindings, row) }
        guard upper.hasPrefix("SELECT ") || upper.hasPrefix("WITH ") else {
            throw SQLiteRecallRows.malformed("read_codec", "statement", "only a read may use public keys")
        }
        let names = Set(sql.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)).intersection(tables).sorted()
        guard !names.isEmpty else { return try handle.query(sql, bindings, row) }
        let clauses = try names.map { name -> String in
            if let saved = projections[name] { return saved }
            let fields = try handle.query("PRAGMA main.table_info(\(name))", []) { (try $0.text(1) ?? "", try $0.text(2) ?? "") }
            let columns = fields.map(\.0)
            let types = Dictionary(uniqueKeysWithValues: fields)
            let foreign = try handle.query("PRAGMA main.foreign_key_list(\(name))", []) {
                (parent: try $0.text(2) ?? "", child: try $0.text(3) ?? "", target: try $0.text(4) ?? "")
            }
            let resultKind = name == "memory_agent_actions" ? try DB2BOutcomes.legacyKindSQL(handle, alias: "r") : nil
            var expressions = columns.map { column -> String in
                if column == "result_kind", let resultKind { return "\(resultKind) AS result_kind" }
                var target = foreign.first { $0.child == column }.map { (table: $0.parent, key: $0.target) }
                if target == nil, types[column] == "INTEGER", let owner = DB2CIdentity.contextOwners[column] {
                    target = (owner, DB2CIdentity.entities[owner]?.key ?? column)
                }
                if let own = DB2CIdentity.entities[name], own.key == column { target = (name, column) }
                guard var target else { return "r.\(column)" }
                target.table = DB2CIdentity.sharedParents[target.table] ?? target.table
                if let entity = DB2CIdentity.entities[target.table], entity.key == target.key, entity.key != entity.uuid {
                    return "(SELECT p.\(entity.uuid) FROM main.\(target.table) p WHERE p.\(entity.key)=r.\(column)) AS \(column)"
                }
                if let prefix = DB2CIdentity.dependentPrefixes[target.table] {
                    return "CASE WHEN r.\(column) IS NULL THEN NULL ELSE '\(prefix):' || r.\(column) END AS \(column)"
                }
                return "r.\(column)"
            }
            if name == "memory_events" { expressions.append("r.event_id AS local_order") }
            if name == "brain_relations" {
                expressions.append("(SELECT key_text FROM main.brain_element_keys k WHERE k.element_key_id=r.element_key_id) AS element_key")
            }
            let projection = "\(name) AS (SELECT \(expressions.joined(separator: ",")) FROM main.\(name) r)"
            projections[name] = projection
            return projection
        }.joined(separator: ",")
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let statement: String
        if upper.hasPrefix("WITH RECURSIVE ") {
            statement = "WITH RECURSIVE \(clauses)," + trimmed.dropFirst(15)
        } else if upper.hasPrefix("WITH ") {
            statement = "WITH \(clauses)," + trimmed.dropFirst(5)
        } else { statement = "WITH \(clauses) " + sql }
        return try handle.query(statement, bindings, row)
    }
}
