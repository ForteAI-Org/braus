import Foundation

/// SQLiteMigration22Keys stores historical identities in temporary destination tables during row conversion.
/// It borrows a destination write transaction. Source keys retain their exact UTF-8 bytes and scalar types.
final class SQLiteMigration22Keys {
    private let target: SQLiteConnection
    private let tables: Set<String>
    private let lookup: SQLiteStatement

    init(in target: SQLiteConnection) throws {
        guard target.isInTransaction else {
            throw SQLiteMigration22.Refusal.verificationFailed(["identity transaction"])
        }
        self.target = target
        self.tables = Set(SQLiteMemorySchema.tableNames(in: try SQLiteMemorySchema.historical19Text()))
        try target.execute("""
            CREATE TEMP TABLE migration_keys(
                entity TEXT NOT NULL, source_key BLOB NOT NULL, destination_id INTEGER NOT NULL,
                PRIMARY KEY(entity,source_key), UNIQUE(entity,destination_id)
            ) STRICT
            """)
        lookup = try target.prepare("SELECT destination_id FROM temp.migration_keys WHERE entity=? AND source_key=?")
    }

    /// Assigns source rowids, an explicit integer identity, or an already assigned parent's identity.
    /// Identifiers must belong to the frozen historical resource. The caller rolls back conversion on any refusal.
    @discardableResult
    func assign(
        from source: SQLiteConnection,
        table: String,
        columns: [String],
        idColumn: String = "rowid",
        parent: String? = nil
    ) throws -> Int {
        guard source !== target, source.isInTransaction, target.isInTransaction else {
            throw SQLiteMigration22.Refusal.verificationFailed(["identity transaction"])
        }
        guard tables.contains(table) else {
            throw SQLiteMigration22.Refusal.verificationFailed(["identity table"])
        }
        let fields = try source.query("PRAGMA table_info(\(table))") {
            (name: try $0.text(1) ?? "", type: try $0.text(2) ?? "")
        }
        let types = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.type) })
        guard !columns.isEmpty, Set(columns).count == columns.count,
              columns.allSatisfy({ types[$0] != nil }),
              idColumn == "rowid" || types[idColumn] == "INTEGER" else {
            throw SQLiteMigration22.Refusal.verificationFailed(["identity columns of \(table)"])
        }
        let rows = try source.prepare("SELECT \(idColumn),\(columns.joined(separator: ",")) FROM \(table) ORDER BY rowid")
        defer { rows.finalize() }
        let insert = try target.prepare("INSERT INTO temp.migration_keys(entity,source_key,destination_id) VALUES (?,?,?)")
        defer { insert.finalize() }
        var count = 0
        while try rows.step() {
            try Task.checkCancellation()
            let key = try columns.enumerated().map { index, name -> SQLiteValue in
                let column = index + 1
                let row = rows.row
                if row.isNull(column) { return .null }
                switch types[name] {
                case "TEXT":
                    guard let value = try row.text(column) else { break }
                    return .text(value)
                case "INTEGER":
                    guard let value = row.integer(column) else { break }
                    return .integer(value)
                case "REAL":
                    guard let value = row.real(column) else { break }
                    return .real(value)
                case "BLOB":
                    guard let value = row.bytes(column) else { break }
                    return .blob(value)
                default: break
                }
                throw SQLiteMigration22.Refusal.verificationFailed(["identity value in \(table)"])
            }
            let identity: Int64
            if let parent { identity = try id(in: parent, for: key) }
            else if let value = rows.row.integer(0) { identity = value }
            else { throw SQLiteMigration22.Refusal.verificationFailed(["integer identity in \(table)"]) }
            try insert.bind([.text(table), .blob(Self.bytes(key)), .integer(identity)])
            while try insert.step() {}
            insert.reset()
            count += 1
        }
        return count
    }

    /// Resolves a previously assigned identity. A missing reference is refused, never converted to NULL or a new ID.
    func id(in table: String, for key: [SQLiteValue]) throws -> Int64 {
        guard target.isInTransaction else {
            throw SQLiteMigration22.Refusal.verificationFailed(["identity transaction"])
        }
        // One prepared lookup is shared by this conversion, with bindings cleared after every result or refusal.
        defer { lookup.reset() }
        try lookup.bind([.text(table), .blob(Self.bytes(key))])
        guard try lookup.step(), let identity = lookup.row.integer(0) else {
            throw SQLiteMigration22.Refusal.verificationFailed(["missing identity in \(table)"])
        }
        return identity
    }

    private static func bytes(_ values: [SQLiteValue]) -> [UInt8] {
        var result: [UInt8] = []
        for value in values {
            let tag: UInt8
            let content: [UInt8]
            switch value {
            case .null: (tag, content) = (110, [])
            case .text(let text): (tag, content) = (116, Array(text.utf8))
            case .integer(let integer): (tag, content) = (105, Array(String(integer).utf8))
            case .real(let real):
                var bits = real.bitPattern.littleEndian
                (tag, content) = (114, withUnsafeBytes(of: &bits) { Array($0) })
            case .blob(let bytes): (tag, content) = (98, bytes)
            }
            result.append(tag)
            result.append(contentsOf: String(content.count).utf8)
            result.append(58)
            result.append(contentsOf: content)
        }
        return result
    }
}
