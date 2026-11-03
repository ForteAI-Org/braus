import Foundation
import Memory

/// DB2BElementSetRows interns byte-exact element content and unordered sets in a borrowed write transaction.
/// Content identity uses the canonical forms in Schema22.md; an occupied digest with different bytes refuses.
enum DB2BElementSetRows {
    static func element(in db: SQLiteTransaction, fields: [String?]) throws -> Int64 {
        guard fields.count == 6 else { throw refusal("element content") }
        let canonical = fields.map { value in value.map { "\($0.utf8.count):" + $0 } ?? "-:" }.joined()
        let digest = Array(Digest16.of(canonical))
        if let stored = try db.query(
            """
            SELECT element_id,role,kind,label,label_origin,container_path,state FROM memory_elements
            WHERE digest=? AND replaced_by_id IS NULL
            """,
            [.blob(digest)],
            { row in
                (id: row.integer(0), fields: try (1...6).map { try row.text($0).map { Array($0.utf8) } })
            }
        ).first {
            guard let id = stored.id, stored.fields == fields.map({ $0.map { Array($0.utf8) } }) else {
                throw refusal("element digest collision")
            }
            return id
        }
        try db.execute(
            """
            INSERT INTO memory_elements(digest,role,kind,label,label_origin,container_path,state)
            VALUES (?,?,?,?,?,?,?)
            """,
            [.blob(digest)] + fields.map { $0.map(SQLiteValue.text) ?? .null }
        )
        return try inserted(db)
    }

    static func set(in db: SQLiteTransaction, members: [Int64]) throws -> Int64 {
        guard members.allSatisfy({ $0 > 0 }) else { throw refusal("element set") }
        let ordered = Set(members).sorted()
        var bytes: [UInt8] = []
        var digests: [String] = []
        for id in ordered {
            var value = UInt64(id)
            repeat {
                let byte = UInt8(value & 0x7f)
                value >>= 7
                bytes.append(byte | (value == 0 ? 0 : 0x80))
            } while value > 0
            guard
                let digest = try db.query(
                    "SELECT digest FROM memory_elements WHERE element_id=?",
                    [.integer(id)],
                    {
                        $0.bytes(0)
                    }
                ).first ?? nil
            else { throw refusal("missing element") }
            digests.append(digest.map { String(format: "%02x", $0) }.joined())
        }
        let digest = Array(Digest16.of(Set(digests).sorted().joined(separator: "\n")))
        if let stored = try db.query(
            """
            SELECT set_id,members FROM memory_element_sets WHERE digest=? AND replaced_by_id IS NULL
            """,
            [.blob(digest)],
            { (id: $0.integer(0), members: $0.bytes(1)) }
        ).first {
            guard let id = stored.id, stored.members == bytes else { throw refusal("element set digest collision") }
            return id
        }
        try db.execute("INSERT INTO memory_element_sets(digest,members) VALUES (?,?)", [.blob(digest), .blob(bytes)])
        return try inserted(db)
    }

    private static func inserted(_ db: SQLiteTransaction) throws -> Int64 {
        guard let id = try db.query("SELECT last_insert_rowid()", [], { $0.integer(0) }).first ?? nil else {
            throw refusal("inserted content identity")
        }
        return id
    }

    private static func refusal(_ reason: String) -> SQLiteMigration22.Refusal {
        .verificationFailed([reason])
    }
}
