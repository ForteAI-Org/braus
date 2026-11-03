import Memory

/// The schema 22 content boundary keeps document formats separate and interns exact text once.
enum DB2CRecallIndexRows {
    static let offered = """
        SELECT p.part_id FROM memory_procedure_parts p
        JOIN memory_part_qualifications q ON q.part_id = p.part_id
            AND q.sequence = (SELECT max(sequence) FROM memory_part_qualifications WHERE part_id = p.part_id AND complete = 1)
        JOIN memory_qualification_policies c ON c.policy_id = q.policy_id AND c.status = 'active'
        WHERE q.verdict = 'admitted' AND q.complete = 1
          AND NOT EXISTS (SELECT 1 FROM memory_routes r WHERE r.supersedes_route_id = p.route_id)
          AND NOT EXISTS (
              SELECT 1 FROM memory_procedure_parts d
              WHERE d.route_id = p.route_id AND d.first_position >= p.first_position AND d.last_position <= p.last_position
                AND (d.part_id = p.part_id
                     OR CASE d.part_kind WHEN 'procedure' THEN 0 WHEN 'subprocedure' THEN 1 ELSE 2 END
                        > CASE p.part_kind WHEN 'procedure' THEN 0 WHEN 'subprocedure' THEN 1 ELSE 2 END)
                AND ifnull((SELECT s.state FROM memory_part_states s WHERE s.part_id = d.part_id
                            ORDER BY s.sequence DESC LIMIT 1), 'usable') <> 'usable')
        """

    static func usesIntegerKeys(_ handle: some SQLiteQuerying) throws -> Bool {
        try SQLiteRowIdentity(handle).usesIntegerKeys
    }

    static func space(_ handle: some SQLiteQuerying, _ publicID: String?) throws -> SQLiteValue {
        guard let publicID else { return .null }
        guard let id = try handle.query("SELECT space_int_id FROM memory_recall_spaces WHERE space_id = ?", [.text(publicID)], {
            $0.integer(0)
        }).first ?? nil else { throw SQLiteRecallRows.malformed("memory_recall_spaces", publicID, "missing space") }
        return .integer(id)
    }

    static func document(_ transaction: SQLiteTransaction, format: RecallDocument.Format, text: String, at nowMS: Int64) throws -> Int64 {
        let digest = Array(Digest16.of(text))
        let found = try transaction.query("SELECT text_id, text FROM memory_recall_texts WHERE digest = ?", [.blob(digest)]) {
            (id: $0.integer(0) ?? 0, text: try $0.text(1) ?? "")
        }.first
        let textID: Int64
        if let found {
            guard found.text.utf8.elementsEqual(text.utf8) else {
                throw SQLiteRecallRows.malformed("memory_recall_texts", "digest", "text digest collision")
            }
            textID = found.id
        } else {
            try transaction.execute("INSERT INTO memory_recall_texts (digest, format, text) VALUES (?, ?, ?)",
                                    [.blob(digest), .text(format.rawValue), .text(text)])
            textID = try transaction.query("SELECT last_insert_rowid()") { $0.integer(0) ?? 0 }.first ?? 0
        }
        try transaction.execute("""
            INSERT INTO memory_recall_documents (text_id, document_format, recorded_at_ms) VALUES (?, ?, ?)
            ON CONFLICT (text_id, document_format) DO NOTHING
            """, [.integer(textID), .text(format.rawValue), .integer(nowMS)])
        guard let id = try transaction.query("SELECT document_id FROM memory_recall_documents WHERE text_id = ? AND document_format = ?",
                                             [.integer(textID), .text(format.rawValue)], { $0.integer(0) }).first ?? nil else {
            throw SQLiteRecallRows.malformed("memory_recall_documents", "insert", "document not found")
        }
        return id
    }

    struct Document {
        let id: Int64
        let textID: Int64
        let digest: String
        let text: String
    }

    /// Legacy callers name documents by SHA-256(format, text); that derived value is never stored twice.
    static func documents(_ handle: some SQLiteQuerying) throws -> [Document] {
        try handle.query("""
            SELECT d.document_id, d.text_id, d.document_format, t.text
            FROM memory_recall_documents d JOIN memory_recall_texts t ON t.text_id = d.text_id ORDER BY d.document_id
            """, []) { row in
            guard let format = RecallDocument.Format(rawValue: try row.text(2) ?? "") else {
                throw SQLiteRecallRows.malformed("memory_recall_documents", String(row.integer(0) ?? 0), "document format")
            }
            let text = try row.text(3) ?? ""
            return Document(id: row.integer(0) ?? 0, textID: row.integer(1) ?? 0,
                            digest: SQLiteRecallRepository.digest(format: format, text: text), text: text)
        }
    }

    static func vectors(_ handle: some SQLiteQuerying, spaceID: String, digests: [String]) throws -> [String: [Float]] {
        let wanted = Set(digests)
        let vectors = Dictionary(uniqueKeysWithValues: try handle.query(
            "SELECT text_id, vector FROM memory_recall_vectors WHERE space_int_id = (SELECT space_int_id FROM memory_recall_spaces WHERE space_id = ?)",
            [.text(spaceID)]
        ) { ($0.integer(0) ?? 0, SQLiteRecallRows.floats($0.bytes(1) ?? [])) })
        var result: [String: [Float]] = [:]
        for document in try documents(handle) where wanted.contains(document.digest) {
            if let vector = vectors[document.textID] { result[document.digest] = vector }
        }
        return result
    }

    static func validateEnumeration(_ transaction: SQLiteTransaction, generationID: Int64, cursor: String?, enumerated: Bool) throws {
        let old = try transaction.query("""
            SELECT document_format, space_int_id, started_at_ms, status, enumerated, revision, cursor_route_id
            FROM memory_recall_generations WHERE generation_id = ?
            """, [.integer(generationID)]) {
                SchemaCoherence.Generation(id: generationID, format: try $0.text(0) ?? "", space: $0.integer(1),
                                           started: $0.integer(2) ?? 0, status: try $0.text(3) ?? "", enumerated: $0.integer(4) == 1,
                                           revision: $0.integer(5) ?? 0, cursor: $0.integer(6))
            }.first
        guard let old else { return }
        var updated = old
        updated.enumerated = enumerated
        updated.cursor = try transaction.query("SELECT route_id FROM memory_routes WHERE route_uuid = ?", [cursor.map(SQLiteValue.text) ?? .null]) {
            $0.integer(0)
        }.first ?? nil
        guard SchemaCoherence.memoryRecallGenerationsTransitions(old, updated) else {
            throw SQLiteRecallRows.malformed("memory_recall_generations", String(generationID), "generation transition")
        }
    }

    static func store(_ transaction: SQLiteTransaction, vectors: [(digest: String, embedded: EmbeddedText)], spaceID: String) throws {
        let space = try space(transaction, spaceID)
        let shape = try transaction.query("SELECT dimensions, precision FROM memory_recall_spaces WHERE space_int_id = ?", [space]) {
            (dimensions: $0.integer(0), precision: try $0.text(1))
        }.first
        let documents = Dictionary(uniqueKeysWithValues: try documents(transaction).map { ($0.digest, $0.textID) })
        for (digest, embedded) in vectors {
            guard let textID = documents[digest] else {
                throw SQLiteRecallRows.malformed("memory_recall_documents", digest, "missing document")
            }
            let bytes = embedded.vector.flatMap { value -> [UInt8] in
                let bits = value.bitPattern
                return [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8),
                        UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 24)]
            }
            guard SchemaCoherence.memoryRecallVectorsShape(Int64(bytes.count), shape?.dimensions, shape?.precision) else {
                throw SQLiteRecallRows.malformed("memory_recall_vectors", digest, "vector shape")
            }
            try transaction.execute("""
                INSERT INTO memory_recall_vectors (text_id, space_int_id, token_count, truncated, vector) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (text_id, space_int_id) DO NOTHING
                """, [.integer(textID), space, .integer(Int64(embedded.tokenCount)), .integer(embedded.isTruncated ? 1 : 0), .blob(bytes)])
        }
    }
}

extension DB2CRecallIndexRows {
    static func sync(_ transaction: SQLiteTransaction, routeID: String, generations: [SQLiteRecallRepository.Generation],
                     at nowMS: Int64) throws -> SQLiteRecallRepository.SyncReport {
        var report = SQLiteRecallRepository.SyncReport()
        let offered = try SQLiteRecallRows.offered(transaction, routeID: routeID)
        let stored = offered.isEmpty ? nil : try SQLiteProcedureRows.stored(transaction, routeID: routeID)
        let routeKey = try DB2CIdentity.key(transaction, "memory_routes", routeID)
        for generation in generations where generation.status == .building || generation.status == .ready {
            let documents = stored.map { RecallDocument.documents(of: $0, offered: offered, format: generation.format) } ?? []
            let wanted = Dictionary(uniqueKeysWithValues: documents.map { ($0.partID, $0) })
            let existing = try transaction.query("""
                SELECT p.part_uuid, d.document_format, t.text, e.qualification_sequence, e.state_sequence
                FROM memory_recall_entries e JOIN memory_procedure_parts p USING(part_id)
                JOIN memory_recall_documents d USING(document_id) JOIN memory_recall_texts t USING(text_id)
                WHERE e.generation_id = ? AND e.route_id = ?
                """, [.integer(generation.generationID), routeKey]) {
                    (part: try $0.text(0) ?? "", format: try $0.text(1) ?? "", text: try $0.text(2) ?? "",
                     qualification: $0.integer(3) ?? 0, state: $0.integer(4) ?? 0)
                }
            var kept: Set<String> = []
            func remove(_ part: String) throws {
                try transaction.execute("DELETE FROM memory_recall_entries WHERE generation_id = ? AND part_id = ?",
                    [.integer(generation.generationID), try DB2CIdentity.key(transaction, "memory_procedure_parts", part)])
            }
            for entry in existing {
                guard let document = wanted[entry.part] else { try remove(entry.part); report.removed += 1; continue }
                let sequences = try sequences(transaction, partID: entry.part)
                if entry.format == generation.format.rawValue && entry.text.utf8.elementsEqual(document.text.utf8)
                    && sequences.0 == entry.qualification && sequences.1 == entry.state {
                    kept.insert(entry.part)
                    report.kept += 1
                } else { try remove(entry.part) }
            }
            for document in documents where !kept.contains(document.partID) {
                let id = try self.document(transaction, format: generation.format, text: document.text, at: nowMS)
                let sequences = try sequences(transaction, partID: document.partID)
                try transaction.execute("""
                    INSERT INTO memory_recall_entries(generation_id,part_id,route_id,part_kind,document_id,qualification_sequence,
                                                       state_sequence,entered_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(generation.generationID), try DB2CIdentity.key(transaction, "memory_procedure_parts", document.partID),
                            routeKey, .text(document.kind.rawValue), .integer(id), .integer(sequences.0), .integer(sequences.1), .integer(nowMS)])
                report.entered += 1
            }
        }
        try DB2CCoherence.validate(transaction)
        return report
    }

    private static func sequences(_ handle: some SQLiteQuerying, partID: String) throws -> (Int64, Int64) {
        let key = try DB2CIdentity.key(handle, "memory_procedure_parts", partID)
        return try handle.query("""
            SELECT coalesce((SELECT max(sequence) FROM memory_part_qualifications WHERE part_id = ?), 0),
                   coalesce((SELECT max(sequence) FROM memory_part_states WHERE part_id = ?), 0)
            """, [key, key]) { ($0.integer(0) ?? 0, $0.integer(1) ?? 0) }.first ?? (0, 0)
    }

    static func entries(_ handle: some SQLiteQuerying, generation: SQLiteRecallRepository.Generation,
                        routes: [String]?) throws -> [SQLiteRecallRepository.IndexEntry] {
        var bindings: [SQLiteValue] = [generation.spaceID.map(SQLiteValue.text) ?? .null, .integer(generation.generationID)]
        var filter = ""
        if let routes {
            guard !routes.isEmpty else { return [] }
            filter = " AND e.route_id IN (" + Array(repeating: "?", count: routes.count).joined(separator: ",") + ")"
            bindings += try routes.map { try DB2CIdentity.key(handle, "memory_routes", $0) }
        }
        return try handle.query("""
            SELECT p.part_uuid, r.route_uuid, e.part_kind, d.document_format, t.text, v.vector, b.bundle_id
            FROM memory_recall_entries e JOIN memory_procedure_parts p USING(part_id)
            JOIN memory_routes r ON r.route_id=e.route_id JOIN memory_recall_documents d USING(document_id)
            JOIN memory_recall_texts t USING(text_id) LEFT JOIN brain_apps b ON b.app_id=p.app_id
            LEFT JOIN memory_recall_vectors v ON v.text_id=d.text_id
              AND v.space_int_id=(SELECT space_int_id FROM memory_recall_spaces WHERE space_id=?)
            WHERE e.generation_id=?\(filter) ORDER BY p.part_uuid
            """, bindings) { row in
                let id = try row.text(0) ?? "", text = try row.text(4) ?? ""
                guard let kind = PartKind(rawValue: try row.text(2) ?? ""),
                      let format = RecallDocument.Format(rawValue: try row.text(3) ?? "") else {
                    throw SQLiteRecallRows.malformed("memory_recall_entries", id, "part kind or format")
                }
                return SQLiteRecallRepository.IndexEntry(partID: id, routeID: try row.text(1) ?? "", kind: kind,
                    digest: SQLiteRecallRepository.digest(format: format, text: text), text: text,
                    vector: row.bytes(5).map(SQLiteRecallRows.floats), bundleID: try row.text(6))
            }
    }

    static func documentsWithoutVector(_ handle: some SQLiteQuerying, spaceID: String, generationIDs: [Int64],
        routes: [String]?, limit: Int
    ) throws -> [(digest: String, text: String)] {
        var bindings: [SQLiteValue] = [.text(spaceID)]
        var filter = ""
        if let routes {
            filter = " AND e.route_id IN (" + Array(repeating: "?", count: routes.count).joined(separator: ",") + ")"
            bindings += try routes.map { try DB2CIdentity.key(handle, "memory_routes", $0) }
        }
        let rows = try handle.query("""
            SELECT DISTINCT d.document_format,t.text FROM memory_recall_entries e
            JOIN memory_recall_documents d USING(document_id) JOIN memory_recall_texts t USING(text_id)
            WHERE NOT EXISTS (SELECT 1 FROM memory_recall_vectors v WHERE v.text_id=d.text_id
                AND v.space_int_id=(SELECT space_int_id FROM memory_recall_spaces WHERE space_id=?))
            AND e.generation_id IN (\(generationIDs.map(String.init).joined(separator: ",")))\(filter)
            """, bindings) { row -> (digest: String, text: String) in
                let text = try row.text(1) ?? ""
                guard let format = RecallDocument.Format(rawValue: try row.text(0) ?? "") else {
                    throw SQLiteRecallRows.malformed("memory_recall_documents", "format", "unknown format")
                }
                return (SQLiteRecallRepository.digest(format: format, text: text), text)
            }
        return Array(rows.sorted { $0.digest < $1.digest }.prefix(max(1, limit)))
    }
}
