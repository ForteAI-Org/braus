import Foundation

/// SQLiteMigration22RowCopy transfers one historical table with explicit rules for changed columns.
/// It borrows the source snapshot and destination write transaction, retaining at most one source row in Swift.
enum SQLiteMigration22RowCopy {
    enum Field {
        case source(String)
        case identity(String, [String])
        case constant(SQLiteValue)
        case derived(([String: SQLiteValue]) throws -> SQLiteValue)
    }

    private struct Column {
        let name: String
        let type: String
        let required: Bool
    }

    /// Copies unchanged storage classes, applies explicit identity/scalar rules, and verifies the table's total count.
    /// Defaults and nullable additions may be omitted. Required additions and changed storage classes require rules.
    /// A refusal requires the caller to roll back the destination transaction; no source writes occur here.
    @discardableResult
    static func copy(
        _ table: String,
        from source: SQLiteConnection,
        into target: SQLiteConnection,
        keys: SQLiteMigration22Keys,
        fields: [String: Field] = [:],
        progress: (Int) -> Void = { _ in }
    ) throws -> Int {
        guard source !== target, source.isInTransaction, target.isInTransaction else {
            throw SQLiteMigration22.Refusal.verificationFailed(["row transaction"])
        }
        guard SQLiteMemorySchema.tableNames(in: try SQLiteMemorySchema.historical19Text()).contains(table) else {
            throw SQLiteMigration22.Refusal.verificationFailed(["row table"])
        }
        let old = try columns(in: source, table: table)
        let new = try columns(in: target, table: table)
        let oldNames = Set(old.map(\.name))
        let newNames = Set(new.map(\.name))
        guard !old.isEmpty, !new.isEmpty, Set(fields.keys).isSubset(of: newNames) else {
            throw SQLiteMigration22.Refusal.verificationFailed(["row fields of \(table)"])
        }
        var selected: [(name: String, field: Field)] = []
        for column in new {
            if let field = fields[column.name] {
                let inputs: [String]
                switch field {
                case .source(let name): inputs = [name]
                case .identity(_, let names):
                    guard !names.isEmpty, Set(names).count == names.count else {
                        throw SQLiteMigration22.Refusal.verificationFailed(["row fields of \(table)"])
                    }
                    inputs = names
                case .constant, .derived: inputs = []
                }
                guard Set(inputs).isSubset(of: oldNames) else {
                    throw SQLiteMigration22.Refusal.verificationFailed(["row fields of \(table)"])
                }
                selected.append((column.name, field))
            } else if let previous = old.first(where: { $0.name == column.name }) {
                guard previous.type == column.type else {
                    throw SQLiteMigration22.Refusal.verificationFailed(["row column \(table).\(column.name)"])
                }
                selected.append((column.name, .source(column.name)))
            } else if column.required {
                throw SQLiteMigration22.Refusal.verificationFailed(["row column \(table).\(column.name)"])
            }
        }
        guard !selected.isEmpty else {
            throw SQLiteMigration22.Refusal.verificationFailed(["row fields of \(table)"])
        }
        let rows = try source.prepare("SELECT \(old.map { quoted($0.name) }.joined(separator: ",")) FROM \(quoted(table)) ORDER BY rowid")
        defer { rows.finalize() }
        let insert = try target.prepare("""
            INSERT INTO \(quoted(table))(\(selected.map { quoted($0.name) }.joined(separator: ",")))
            VALUES (\(Array(repeating: "?", count: selected.count).joined(separator: ",")))
            """)
        defer { insert.finalize() }
        var count = 0
        while try rows.step() {
            try Task.checkCancellation()
            var values: [String: SQLiteValue] = [:]
            for (index, column) in old.enumerated() {
                values[column.name] = try value(rows.row, at: index, type: column.type)
            }
            let bindings = try selected.map { column -> SQLiteValue in
                switch column.field {
                case .constant(let value): return value
                case .derived(let convert): return try convert(values)
                case .source(let name):
                    guard let value = values[name] else {
                        throw SQLiteMigration22.Refusal.verificationFailed(["row fields of \(table)"])
                    }
                    return value
                case .identity(let entity, let names):
                    let key = try names.map { name in
                        guard let value = values[name] else {
                            throw SQLiteMigration22.Refusal.verificationFailed(["row fields of \(table)"])
                        }
                        return value
                    }
                    if key.contains(.null) { return .null }
                    return .integer(try keys.id(in: entity, for: key))
                }
            }
            try insert.bind(bindings)
            while try insert.step() {}
            insert.reset()
            count += 1
            if count.isMultiple(of: 256) { progress(count) }
        }
        guard let found = try target.query("SELECT count(*) FROM \(quoted(table))", [], { $0.integer(0) }).first ?? nil else {
            throw SQLiteMigration22.Refusal.verificationFailed(["row count \(table)"])
        }
        guard found == Int64(count) else {
            throw SQLiteMigration22.Refusal.verificationFailed(["row count \(table): expected \(count), found \(found)"])
        }
        progress(count)
        return count
    }

    private static func columns(in db: SQLiteConnection, table: String) throws -> [Column] {
        try db.query("PRAGMA table_info(\(quoted(table)))") {
            Column(name: try $0.text(1) ?? "", type: try $0.text(2) ?? "",
                   required: ($0.integer(3) == 1 && $0.isNull(4)) || ($0.integer(5) ?? 0) > 0)
        }
    }

    private static func value(_ row: SQLiteStatement.Row, at index: Int, type: String) throws -> SQLiteValue {
        if row.isNull(index) { return .null }
        switch type {
        case "TEXT": if let text = try row.text(index) { return .text(text) }
        case "INTEGER": if let integer = row.integer(index) { return .integer(integer) }
        case "REAL": if let real = row.real(index) { return .real(real) }
        case "BLOB": if let bytes = row.bytes(index) { return .blob(bytes) }
        default: break
        }
        throw SQLiteMigration22.Refusal.verificationFailed(["historical scalar storage class"])
    }

    private static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
