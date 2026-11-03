import Foundation
import Memory

/// SQLiteMigration22Content supplies explicit scalar, privacy and Recall-content conversion rules.
/// Source reads stay in the admitted snapshot; all derived rows and temporary catalogs belong to the destination.
final class SQLiteMigration22Content {
    let plan: SQLiteMigration22Plan
    private let source: SQLiteConnection
    private let target: SQLiteConnection

    init(source: SQLiteConnection, target: SQLiteConnection, plan: SQLiteMigration22Plan) throws {
        self.source = source
        self.target = target
        self.plan = plan
        try target.execute("CREATE TEMP TABLE migration_texts(document_id INTEGER PRIMARY KEY,text_id INTEGER NOT NULL) STRICT")
        let documents = try source.prepare("SELECT document_digest,document_format,text FROM memory_recall_documents ORDER BY rowid")
        defer { documents.finalize() }
        while try documents.step() {
            try Task.checkCancellation()
            let row = documents.row
            guard let key = try row.text(0), let format = try row.text(1), let text = try row.text(2) else {
                throw Self.refusal("Recall document content")
            }
            let document = try plan.keys.id(in: "memory_recall_documents", for: [.text(key)])
            let textID = try intern(text: text, format: format)
            try target.run("INSERT INTO temp.migration_texts(document_id,text_id) VALUES (?,?)", [.integer(document),.integer(textID)])
        }
    }

    func fields(for table: String) throws -> [String: SQLiteMigration22RowCopy.Field] {
        switch table {
        case "memory_task_values", "memory_parameter_bindings":
            return ["value_digest": .derived { row in
                guard row["content"] == .text("text"), case .text(let text) = row["text_value"] else { return .null }
                return .blob(Array(Digest16.of(text)))
            }]
        case "memory_part_states":
            return ["reason_code": .constant(.text("migrated")), "recorded_by": .derived { row in
                .text(row["recorded_by"] == .text("braus-cli") ? "person" : "braus")
            }]
        case "memory_recall_documents":
            return ["text_id": .derived { try self.textID(for: Self.text($0, "document_digest")) }]
        case "memory_recall_vectors":
            return ["text_id": .derived { try self.textID(for: Self.text($0, "document_digest")) },
                    "space_int_id": .identity("memory_recall_spaces", ["space_id"])]
        case "memory_recall_queries", "memory_recall_proposals":
            return ["remaining_work": .derived { row in
                .text(try self.mask(Self.text(row, "remaining_work"), context: row))
            }]
        case "memory_recall_needs", "memory_recall_proposal_needs":
            let parent = table == "memory_recall_needs" ? "memory_recall_queries" : "memory_recall_proposals"
            let key = table == "memory_recall_needs" ? "query_id" : "proposal_id"
            return ["text": .derived { row in
                let context = try self.source.query("""
                    SELECT task_id,task_occurrence_id,task_revision,recorded_at_ms FROM \(parent) WHERE \(key)=?
                    """, [.text(try Self.text(row, key))]) { value -> [String: SQLiteValue] in
                        ["task_id": .text(try value.text(0) ?? ""), "task_occurrence_id": .text(try value.text(1) ?? ""),
                         "task_revision": value.integer(2).map(SQLiteValue.integer) ?? .null,
                         "recorded_at_ms": value.integer(3).map(SQLiteValue.integer) ?? .null]
                    }.first
                guard let context else { throw Self.refusal("Recall request owner") }
                return .text(try self.mask(Self.text(row, "text"), context: context))
            }]
        case "brain_relations":
            return ["element_key_id": .derived { try self.elementKey($0) }]
        case "brain_relation_proofs":
            return ["to_scene_id": .derived { row in
                let scene = try self.source.query("SELECT to_scene_id FROM brain_relations WHERE relation_id=?",
                                                  [.text(try Self.text(row, "relation_id"))]) { try $0.text(0) }.first ?? nil
                return try scene.map { .integer(try self.plan.keys.id(in: "brain_scenes", for: [.text($0)])) } ?? .null
            }]
        default: return [:]
        }
    }

    private func textID(for digest: String) throws -> SQLiteValue {
        let document = try plan.keys.id(in: "memory_recall_documents", for: [.text(digest)])
        guard let text = try target.query("SELECT text_id FROM temp.migration_texts WHERE document_id=?",
                                         [.integer(document)], { $0.integer(0) }).first ?? nil else {
            throw Self.refusal("Recall text identity")
        }
        return .integer(text)
    }

    private func intern(text: String, format: String) throws -> Int64 {
        let digest = Array(Digest16.of(text))
        if let stored = try target.query("SELECT text_id,text FROM memory_recall_texts WHERE digest=?", [.blob(digest)], {
            (id: $0.integer(0), text: try $0.text(1))
        }).first {
            guard let id = stored.id, stored.text.map({ Array($0.utf8) }) == Array(text.utf8) else {
                throw Self.refusal("Recall text digest collision")
            }
            return id
        }
        try target.run("INSERT INTO memory_recall_texts(digest,format,text) VALUES (?,?,?)",
                       [.blob(digest),.text(format),.text(text)])
        guard let id = try target.query("SELECT last_insert_rowid()", [], { $0.integer(0) }).first ?? nil else {
            throw Self.refusal("Recall text identity")
        }
        return id
    }

    private func mask(_ text: String, context: [String: SQLiteValue]) throws -> String {
        let task = try Self.text(context, "task_id")
        let revision = context["task_revision"] ?? .null
        let attempt = context["task_occurrence_id"] ?? .null
        let at = context["recorded_at_ms"] ?? .integer(Int64.max)
        let values = try source.query("""
            SELECT v.name,v.text_value FROM memory_task_values v
            WHERE v.task_id=? AND v.content='text' AND (v.revision=? OR (v.task_occurrence_id=? AND EXISTS (
                SELECT 1 FROM memory_task_checkpoints c WHERE c.task_occurrence_id=v.task_occurrence_id
                AND c.sequence=v.checkpoint_sequence AND c.recorded_at_ms<=?))) ORDER BY v.value_id
            """, [.text(task),revision,attempt,at]) { row in
                try TaskValue(name: row.text(0) ?? "", kind: .text, content: .text(row.text(1) ?? ""), source: .request)
            }
        return RecallQueryMasking.masked(text, values: values)
    }

    private func elementKey(_ row: [String: SQLiteValue]) throws -> SQLiteValue {
        if case .null? = row["element_key"] { return .null }
        guard case .text(let key) = row["element_key"], case .integer(let app) = row["app_id"] else {
            throw Self.refusal("relation element key")
        }
        let digest = Array(Digest16.of(key))
        if let found = try target.query("""
            SELECT element_key_id,key_text FROM brain_element_keys WHERE app_id=? AND digest=? AND replaced_by_id IS NULL
            """, [.integer(app),.blob(digest)], { (id: $0.integer(0), text: try $0.text(1)) }).first {
            guard let id = found.id, found.text.map({ Array($0.utf8) }) == Array(key.utf8) else {
                throw Self.refusal("element key digest collision")
            }
            return .integer(id)
        }
        try target.run("INSERT INTO brain_element_keys(app_id,key_text,digest,first_seen_ms) VALUES (?,?,?,?)",
                       [.integer(app),.text(key),.blob(digest),row["first_seen_ms"] ?? .integer(0)])
        guard let id = try target.query("SELECT last_insert_rowid()", [], { $0.integer(0) }).first ?? nil else {
            throw Self.refusal("element key identity")
        }
        return .integer(id)
    }

    private static func text(_ row: [String: SQLiteValue], _ name: String) throws -> String {
        guard case .text(let value) = row[name] else { throw refusal("content field \(name)") }
        return value
    }

    private static func refusal(_ reason: String) -> SQLiteMigration22.Refusal {
        .verificationFailed([reason])
    }
}
