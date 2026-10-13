//
//  SQLiteRecallRepository.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import CryptoKit
import Foundation
import Memory

/// SQLiteRecallRepository keeps the Recall's index and facts in the authoritative archive (schema 6). The index
/// is derived: spaces, generations, canonical documents, vectors and entries are rebuilt from the catalogue and
/// never consulted alone, since every part a reader takes from an entry is checked again against the catalogue
/// (`offered`) before anything is delivered. The index work is recorded by the archive's triggers with the writes
/// that change the catalogue; this repository takes it, applies it in short transactions that never wait for a
/// model, and marks it done. The facts (queries, needs, selections, requirements, links, reports) are kept as
/// written. Every write is one transaction; none is held across an embedding or a model's turn.
public struct SQLiteRecallRepository: Sendable {

    let store: SQLiteMemoryStore

    public init(store: SQLiteMemoryStore) {
        self.store = store
    }

    // MARK: Spaces and generations

    /// Generation is one generation as stored.
    public struct Generation: Sendable, Equatable {
        public enum Status: String, Sendable, Equatable { case building, ready, retired, failed }

        public let generationID: Int64
        public let format: RecallDocument.Format
        public let spaceID: String?
        public let status: Status
        public let cursorRouteID: String?
        public let isEnumerated: Bool
        public let revision: Int64
        public let startedAtMS: Int64
        public let readyAtMS: Int64?
        public let reason: String?
    }

    /// Records a space once; the same space again is the stored one.
    public func ensure(space: EmbeddingSpace, at nowMS: Int64) async throws {
        try await store.write { transaction in
            _ = try transaction.execute(
                """
                INSERT INTO memory_recall_spaces (space_id, model_id, model_revision, weights_digest, tokenizer_digest, dimensions,
                    pooling, normalization, precision, query_prefix, document_prefix, maximum_tokens, recorded_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (space_id) DO NOTHING
                """,
                [.text(space.spaceID), .text(space.modelID), .text(space.modelRevision), .text(space.weightsDigest),
                 .text(space.tokenizerDigest), .integer(Int64(space.dimensions)), .text(space.pooling), .text(space.normalization),
                 .text(space.precision), .text(space.queryPrefix), .text(space.documentPrefix), .integer(Int64(space.maximumTokens)),
                 .integer(nowMS)]
            )
        }
    }

    /// The generations being built or ready, the ready one first.
    public func liveGenerations() async throws -> [Generation] {
        try await store.read { snapshot in
            try SQLiteRecallRows.generations(snapshot, where: "status IN ('ready', 'building')")
        }
    }

    /// Starts a generation of a format in a space (nil: lexical only), or answers the one being built.
    public func startGeneration(format: RecallDocument.Format, spaceID: String?, at nowMS: Int64) async throws -> Generation {
        try await store.write { transaction in
            if let building = try SQLiteRecallRows.generations(transaction, where: "status = 'building'").first { return building }
            try transaction.execute(
                "INSERT INTO memory_recall_generations (document_format, space_id, status, started_at_ms) VALUES (?, ?, 'building', ?)",
                [.text(format.rawValue), spaceID.map(SQLiteValue.text) ?? .null, .integer(nowMS)]
            )
            guard let made = try SQLiteRecallRows.generations(transaction, where: "status = 'building'").first else {
                throw SQLiteRecallRows.malformed("memory_recall_generations", "building", "not found after its insert")
            }
            return made
        }
    }

    /// Makes a built generation the current one, retiring the one it replaces, in one transaction. Refused while
    /// it is not enumerated, or, when `requiringVectors`, while one of its documents still lacks a vector: a
    /// replacement is complete before it is current, while the first generation of an archive may answer
    /// lexically as its vectors are computed.
    public func promote(_ generationID: Int64, requiringVectors: Bool = true, at nowMS: Int64) async throws {
        try await store.write { transaction in
            guard let generation = try SQLiteRecallRows.generations(transaction, where: "generation_id = \(generationID)").first,
                  generation.status == .building else {
                throw SQLiteRecallRows.malformed("memory_recall_generations", "\(generationID)", "not being built")
            }
            let backlog = requiringVectors ? try SQLiteRecallRows.vectorBacklog(transaction, generation) : 0
            guard generation.isEnumerated, backlog == 0 else {
                throw SQLiteRecallRows.malformed("memory_recall_generations", "\(generationID)", "not complete")
            }
            try transaction.execute(
                "UPDATE memory_recall_generations SET status = 'retired', ended_at_ms = ?, reason = 'replaced' WHERE status = 'ready'",
                [.integer(nowMS)]
            )
            try transaction.execute(
                "UPDATE memory_recall_generations SET status = 'ready', ready_at_ms = ? WHERE generation_id = ?",
                [.integer(nowMS), .integer(generationID)]
            )
        }
    }

    /// Ends a generation being built as failed, with why; the ready one stays as it was.
    public func fail(_ generationID: Int64, reason: String, at nowMS: Int64) async throws {
        try await store.write { transaction in
            _ = try transaction.execute(
                "UPDATE memory_recall_generations SET status = 'failed', ended_at_ms = ?, reason = ? WHERE generation_id = ? AND status = 'building'",
                [.integer(nowMS), .text(reason), .integer(generationID)]
            )
        }
    }

    /// Retires a generation being built that is no longer wanted (another configuration replaced it).
    public func abandon(_ generationID: Int64, reason: String, at nowMS: Int64) async throws {
        try await store.write { transaction in
            _ = try transaction.execute(
                "UPDATE memory_recall_generations SET status = 'retired', ended_at_ms = ?, reason = ? WHERE generation_id = ? AND status = 'building'",
                [.integer(nowMS), .text(reason), .integer(generationID)]
            )
        }
    }

    // MARK: Work

    /// Work is one pending row of index work.
    public struct Work: Sendable, Equatable {
        public let workID: Int64
        public let routeID: String?
        public let reason: String
        public let attempts: Int
    }

    /// The oldest pending work, at most `limit`.
    public func pendingWork(limit: Int) async throws -> [Work] {
        try await store.read { snapshot in
            try snapshot.query(
                "SELECT work_id, route_id, reason, attempts FROM memory_recall_work WHERE done_at_ms IS NULL ORDER BY work_id LIMIT ?",
                [.integer(Int64(max(1, limit)))]
            ) { Work(workID: $0.integer(0) ?? 0, routeID: try $0.text(1), reason: try $0.text(2) ?? "", attempts: Int($0.integer(3) ?? 0)) }
        }
    }

    /// Marks work done.
    public func complete(_ workIDs: [Int64], at nowMS: Int64) async throws {
        guard !workIDs.isEmpty else { return }
        try await store.write { transaction in
            for id in workIDs {
                try transaction.execute("UPDATE memory_recall_work SET done_at_ms = ? WHERE work_id = ? AND done_at_ms IS NULL",
                                        [.integer(nowMS), .integer(id)])
            }
        }
    }

    /// Counts a failed attempt of work, with what failed in a sentence with no content of the agent's.
    public func failed(_ workID: Int64, reason: String) async throws {
        try await store.write { transaction in
            _ = try transaction.execute("UPDATE memory_recall_work SET attempts = attempts + 1, last_error = ? WHERE work_id = ?",
                                    [.text(reason), .integer(workID)])
        }
    }

    /// Queues a whole rebuild, as `braus memory --recall-rebuild` asks.
    public func queueRebuild(at nowMS: Int64) async throws {
        try await store.write { transaction in
            _ = try transaction.execute(
                """
                INSERT INTO memory_recall_work (route_id, reason, enqueued_at_ms) SELECT NULL, 'rebuild', ?
                WHERE NOT EXISTS (SELECT 1 FROM memory_recall_work WHERE done_at_ms IS NULL AND route_id IS NULL)
                """,
                [.integer(nowMS)]
            )
        }
    }

    // MARK: Entries

    /// SyncReport is what bringing one version's entries in line with the catalogue did.
    public struct SyncReport: Sendable, Equatable {
        public var entered = 0
        public var kept = 0
        public var removed = 0
    }

    /// Brings the entries of one version, in every given generation, in line with what the catalogue offers now:
    /// an entry for each offered part with its document, none for a part no longer offered. One transaction.
    @discardableResult
    public func sync(routeID: String, generations: [Generation], at nowMS: Int64) async throws -> SyncReport {
        try await store.write { transaction in
            try SQLiteRecallRows.sync(transaction, routeID: routeID, generations: generations, at: nowMS)
        }
    }

    /// Enters the next page of the catalogue's versions into a generation being built, from its cursor; marks it
    /// enumerated when the catalogue has no more. Answers the versions the page held.
    @discardableResult
    public func enumerate(_ generation: Generation, pageSize: Int, at nowMS: Int64) async throws -> [String] {
        try await store.write { transaction in
            let routes = try transaction.query(
                "SELECT DISTINCT r.route_id FROM (\(SQLiteProcedureRows.offered)) o JOIN memory_procedure_parts r ON r.part_id = o.part_id "
                    + "WHERE r.route_id > ? ORDER BY r.route_id LIMIT ?",
                [.text(generation.cursorRouteID ?? ""), .integer(Int64(max(1, pageSize)))]
            ) { try $0.text(0) ?? "" }
            for route in routes { _ = try SQLiteRecallRows.sync(transaction, routeID: route, generations: [generation], at: nowMS) }
            try transaction.execute(
                "UPDATE memory_recall_generations SET cursor_route_id = ?, enumerated = ? WHERE generation_id = ?",
                [routes.last.map(SQLiteValue.text) ?? (generation.cursorRouteID.map(SQLiteValue.text) ?? .null),
                 .integer(routes.count < pageSize ? 1 : 0), .integer(generation.generationID)]
            )
            return routes
        }
    }

    // MARK: Vectors

    /// Documents of the given generations with no vector in the space, at most `limit`: of every entry, or of the entries
    /// of `routes` only, which an index on the route reaches without reading the others.
    public func documentsWithoutVector(spaceID: String, generationIDs: [Int64], routes: [String]? = nil,
                                       limit: Int) async throws -> [(digest: String, text: String)] {
        guard !generationIDs.isEmpty else { return [] }
        if let routes, routes.isEmpty { return [] }
        return try await store.read { snapshot in
            var arguments: [SQLiteValue] = [.text(spaceID)]
            var filter = ""
            if let routes {
                filter = " AND e.route_id IN (" + Array(repeating: "?", count: routes.count).joined(separator: ",") + ")"
                arguments += routes.map(SQLiteValue.text)
            }
            return try snapshot.query(
                """
                SELECT DISTINCT d.document_digest, d.text FROM memory_recall_entries e
                JOIN memory_recall_documents d ON d.document_digest = e.document_digest
                WHERE NOT EXISTS (SELECT 1 FROM memory_recall_vectors v WHERE v.space_id = ? AND v.document_digest = d.document_digest)
                  AND e.generation_id IN (\(generationIDs.map(String.init).joined(separator: ",")))\(filter)
                ORDER BY d.document_digest LIMIT ?
                """,
                arguments + [.integer(Int64(max(1, limit)))]
            ) { (digest: try $0.text(0) ?? "", text: try $0.text(1) ?? "") }
        }
    }

    /// Stores vectors of documents in a space; a vector already stored is kept as it was.
    public func store(vectors: [(digest: String, embedded: EmbeddedText)], spaceID: String, at nowMS: Int64) async throws {
        guard !vectors.isEmpty else { return }
        try await store.write { transaction in
            for (digest, embedded) in vectors {
                var bytes = [UInt8](repeating: 0, count: embedded.vector.count * 4)
                for (index, value) in embedded.vector.enumerated() {
                    let bits = value.bitPattern.littleEndian
                    bytes[index * 4]     = UInt8(truncatingIfNeeded: bits)
                    bytes[index * 4 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                    bytes[index * 4 + 2] = UInt8(truncatingIfNeeded: bits >> 16)
                    bytes[index * 4 + 3] = UInt8(truncatingIfNeeded: bits >> 24)
                }
                try transaction.execute(
                    """
                    INSERT INTO memory_recall_vectors (space_id, document_digest, token_count, truncated, vector, recorded_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (space_id, document_digest) DO NOTHING
                    """,
                    [.text(spaceID), .text(digest), .integer(Int64(embedded.tokenCount)), .integer(embedded.isTruncated ? 1 : 0),
                     .blob(bytes), .integer(nowMS)]
                )
            }
        }
    }

    /// How many documents of a generation have no vector in its space.
    public func vectorBacklog(of generation: Generation) async throws -> Int {
        try await store.read { snapshot in try SQLiteRecallRows.vectorBacklog(snapshot, generation) }
    }

    // MARK: Reading the index

    /// IndexEntry is one entry as a reader keeps it in memory: the part, its version and kind, its document and,
    /// when the generation has a space, its vector there (nil while it is not computed yet).
    public struct IndexEntry: Sendable {
        public let partID: String
        public let routeID: String
        public let kind: PartKind
        public let digest: String
        public let text: String
        public let vector: [Float]?
        /// The application the part runs in, nil for a part over several: what a need bound to an application excludes
        /// before any cut.
        public let bundleID: String?

        public init(partID: String, routeID: String, kind: PartKind, digest: String, text: String, vector: [Float]?, bundleID: String?) {
            self.partID   = partID
            self.routeID  = routeID
            self.kind     = kind
            self.digest   = digest
            self.text     = text
            self.vector   = vector
            self.bundleID = bundleID
        }

        /// The same entry with its vector, once computed.
        public func with(vector: [Float]) -> IndexEntry {
            IndexEntry(partID: partID, routeID: routeID, kind: kind, digest: digest, text: text, vector: vector, bundleID: bundleID)
        }
    }

    /// Every entry of a generation, with its document and vector, the generation's revision and the work mark read in the
    /// same snapshot.
    public func entries(of generation: Generation) async throws -> (revision: Int64, mark: Int64, entries: [IndexEntry]) {
        try await store.read { snapshot in
            let (revision, mark) = try Self.revisionAndMark(snapshot, generation)
            return (revision, mark, try Self.entries(snapshot, generation, routes: nil))
        }
    }

    /// Changes is what moved in a generation since a reader's mark, read in one snapshot: its revision, the new mark, the
    /// versions whose entries may have changed (every version with index work at or after the old mark: the work a
    /// trigger recorded before the catalogue's change, pending when the reader read, or recorded since) and their
    /// entries now. A version no longer offered has none.
    public struct Changes: Sendable {
        public let revision: Int64
        public let mark: Int64
        public let routes: [String]
        public let entries: [IndexEntry]
    }

    /// The entries of the versions that may have changed in a generation since `mark`, at most `limit` versions; nil when
    /// more did, for the reader to read the whole generation instead.
    public func changes(of generation: Generation, since mark: Int64, limit: Int) async throws -> Changes? {
        try await store.read { snapshot in
            let (revision, next) = try Self.revisionAndMark(snapshot, generation)
            let routes = try snapshot.query(
                "SELECT DISTINCT route_id FROM memory_recall_work WHERE work_id >= ? AND route_id IS NOT NULL ORDER BY route_id LIMIT ?",
                [.integer(mark), .integer(Int64(limit + 1))]
            ) { try $0.text(0) ?? "" }
            guard routes.count <= limit else { return nil }
            return Changes(revision: revision, mark: next, routes: routes, entries: try Self.entries(snapshot, generation, routes: routes))
        }
    }

    /// The vectors in a space of the documents named, those computed.
    public func vectors(spaceID: String, digests: [String]) async throws -> [String: [Float]] {
        guard !digests.isEmpty else { return [:] }
        return try await store.read { snapshot in
            var found: [String: [Float]] = [:]
            for start in stride(from: 0, to: digests.count, by: 500) {
                let page = Array(digests[start..<min(digests.count, start + 500)])
                let rows = try snapshot.query(
                    "SELECT document_digest, vector FROM memory_recall_vectors WHERE space_id = ? AND document_digest IN ("
                        + Array(repeating: "?", count: page.count).joined(separator: ",") + ")",
                    [.text(spaceID)] + page.map(SQLiteValue.text)
                ) { (try $0.text(0) ?? "", $0.bytes(1).map(SQLiteRecallRows.floats)) }
                for (digest, vector) in rows { if let vector { found[digest] = vector } }
            }
            return found
        }
    }

    /// A generation's revision and the work mark: the oldest work still pending, or the next work's id when none is, so
    /// every change to the generation's entries after this snapshot comes from work at or after it.
    private static func revisionAndMark(_ snapshot: SQLiteSnapshot, _ generation: Generation) throws -> (Int64, Int64) {
        let revision = try snapshot.query("SELECT revision FROM memory_recall_generations WHERE generation_id = ?",
                                          [.integer(generation.generationID)]) { $0.integer(0) ?? 0 }.first ?? 0
        let mark = try snapshot.query(
            "SELECT coalesce((SELECT min(work_id) FROM memory_recall_work WHERE done_at_ms IS NULL), (SELECT coalesce(max(work_id), 0) + 1 FROM memory_recall_work))"
        ) { $0.integer(0) ?? 0 }.first ?? 0
        return (revision, mark)
    }

    private static func entries(_ snapshot: SQLiteSnapshot, _ generation: Generation, routes: [String]?) throws -> [IndexEntry] {
        var arguments: [SQLiteValue] = [generation.spaceID.map(SQLiteValue.text) ?? .null, .integer(generation.generationID)]
        var filter = ""
        if let routes {
            guard !routes.isEmpty else { return [] }
            filter = " AND e.route_id IN (" + Array(repeating: "?", count: routes.count).joined(separator: ",") + ")"
            arguments += routes.map(SQLiteValue.text)
        }
        return try snapshot.query(
            """
            SELECT e.part_id, e.route_id, e.part_kind, e.document_digest, d.text, v.vector, b.bundle_id FROM memory_recall_entries e
            JOIN memory_recall_documents d ON d.document_digest = e.document_digest
            JOIN memory_procedure_parts p ON p.part_id = e.part_id
            LEFT JOIN brain_apps b ON b.app_id = p.app_id
            LEFT JOIN memory_recall_vectors v ON v.space_id = ? AND v.document_digest = e.document_digest
            WHERE e.generation_id = ?\(filter) ORDER BY e.part_id
            """,
            arguments
        ) { row -> IndexEntry in
            let id = try row.text(0) ?? ""
            guard let kind = PartKind(rawValue: try row.text(2) ?? "") else {
                throw SQLiteRecallRows.malformed("memory_recall_entries", id, "part_kind")
            }
            return IndexEntry(partID: id, routeID: try row.text(1) ?? "", kind: kind, digest: try row.text(3) ?? "",
                              text: try row.text(4) ?? "", vector: row.bytes(5).map(SQLiteRecallRows.floats), bundleID: try row.text(6))
        }
    }

    /// A generation's revision now.
    public func revision(of generationID: Int64) async throws -> Int64 {
        try await store.read { snapshot in
            try snapshot.query("SELECT revision FROM memory_recall_generations WHERE generation_id = ?", [.integer(generationID)]) {
                $0.integer(0) ?? 0
            }.first ?? 0
        }
    }

    // MARK: The catalogue, checked again

    /// The parts among `partIDs` the catalogue offers now.
    public func offered(_ partIDs: [String]) async throws -> Set<String> {
        guard !partIDs.isEmpty else { return [] }
        return try await store.read { snapshot in try SQLiteRecallRows.offered(snapshot, partIDs) }
    }

    /// The versions named, as the selector reads them, from the authoritative tables now; a version that is no
    /// longer stored is left out.
    public func sources(_ routeIDs: [String]) async throws -> [RecallSource] {
        try await store.read { snapshot in try routeIDs.compactMap { try SQLiteRecallRows.source(snapshot, routeID: $0) } }
    }

    /// The functional state the latest observation of a producer's stream showed, since `sinceMS`: the structural scene
    /// its latest event on an application (a call or an observation) was confirmed in after it. Nil when that event has
    /// no confirmed scene, or the stream has no such event since then: the state is then unknown, never guessed.
    public func observedState(of source: MemoryEventSource, stream: String, since sinceMS: Int64) async throws -> ObservedState? {
        try await store.read { snapshot in try SQLiteRecallRows.observedState(snapshot, source: source, stream: stream, since: sinceMS) }
    }

    // MARK: Facts

    /// RecordedQuery is a query with what it found, as it is recorded.
    public struct RecordedQuery: Sendable {
        public let queryID: String
        public let request: RecallRequest
        public let producer: TaskProducer
        public let generationID: Int64?
        public let channel: RecallChannel
        public let searchStatus: SearchStatus
        public let searchNote: String?
        public let candidatesConsidered: Int
        public let coverage: RecallCoverage
        public let delivery: String
        public let deliveryBytes: Int?
        public let durationUS: Int64?
        public let needs: [NeedOutcome]
        /// The rules that selected: the automatic selector's version, or the agent's choice's (`RecallChoice`).
        public var selectorVersion = RecallContract.selectorVersion

        public init(queryID: String, request: RecallRequest, producer: TaskProducer, generationID: Int64?, channel: RecallChannel,
                    searchStatus: SearchStatus, searchNote: String?, candidatesConsidered: Int, coverage: RecallCoverage, delivery: String,
                    deliveryBytes: Int?, durationUS: Int64?, needs: [NeedOutcome]) {
            self.queryID              = queryID
            self.request              = request
            self.producer             = producer
            self.generationID         = generationID
            self.channel              = channel
            self.searchStatus         = searchStatus
            self.searchNote           = searchNote
            self.candidatesConsidered = candidatesConsidered
            self.coverage             = coverage
            self.delivery             = delivery
            self.deliveryBytes        = deliveryBytes
            self.durationUS           = durationUS
            self.needs                = needs
        }
    }

    /// Records a query with its needs, selections and requirements, in one transaction.
    public func record(_ query: RecordedQuery, at nowMS: Int64) async throws {
        try await store.write { transaction in try SQLiteRecallRows.record(transaction, query, at: nowMS) }
    }

    /// StoredSelection is a selected interval of a delivered query of an attempt, with the bindings it was given: the one
    /// selection of a need, or one of the tracts the agent chose for it (`isChoice`, at `selectionPosition`).
    public struct StoredSelection: Sendable {
        public let queryID: String
        public let needPosition: Int
        public var selectionPosition = 0
        public var isChoice = false
        public let recordedAtMS: Int64
        public let routeID: String
        public let firstPosition: Int
        public let lastPosition: Int
        /// The task value each parameter was bound to, by name.
        public let bindings: [String: String]
        /// The task's revision the query was made under: whose values the bindings took.
        public let taskRevision: Int
    }

    /// The selections the attempt's delivered queries proposed, in the order the queries were made.
    public func selections(ofAttempt attemptID: String) async throws -> [StoredSelection] {
        try await store.read { snapshot in try SQLiteRecallRows.selections(snapshot, attemptID: attemptID) }
    }

    /// The calls of an attempt that started after `afterMS`, in their order, with whether each one's check passed.
    public func calls(ofAttempt attemptID: String, after afterMS: Int64) async throws -> [RecallUseLinking.Call] {
        try await store.read { snapshot in try SQLiteRecallRows.calls(snapshot, attemptID: attemptID, after: afterMS) }
    }

    /// Records links of calls to a query's need, each call once: a call already linked keeps its link. A choice's calls are
    /// linked to the tract (`selectionPosition`) they carried out.
    public func link(queryID: String, needPosition: Int, selectionPosition: Int = 0, isChoice: Bool = false, links: [RecallUseLinking.Link],
                     at nowMS: Int64) async throws -> Int {
        try await store.write { transaction in
            var written = 0
            for link in links {
                if isChoice {
                    written += try transaction.execute(
                        """
                        INSERT INTO memory_recall_choice_links (query_id, need_position, selection_position, call_event_id, step_position,
                            confirmed, undetermined, linked_at_ms)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (query_id, call_event_id) DO NOTHING
                        """,
                        [.text(queryID), .integer(Int64(needPosition)), link.stepPosition == nil ? .null : .integer(Int64(selectionPosition)),
                         .text(link.callEventID), link.stepPosition.map { .integer(Int64($0)) } ?? .null, .integer(link.confirmed ? 1 : 0),
                         .integer(link.undetermined ? 1 : 0), .integer(nowMS)]
                    )
                    continue
                }
                written += try transaction.execute(
                    """
                    INSERT INTO memory_recall_links (query_id, need_position, call_event_id, step_position, confirmed, undetermined,
                        linked_at_ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (query_id, call_event_id) DO NOTHING
                    """,
                    [.text(queryID), .integer(Int64(needPosition)), .text(link.callEventID),
                     link.stepPosition.map { .integer(Int64($0)) } ?? .null, .integer(link.confirmed ? 1 : 0),
                     .integer(link.undetermined ? 1 : 0), .integer(nowMS)]
                )
            }
            return written
        }
    }

    /// Appends the agent's declared use of a need's selection.
    public func report(queryID: String, needPosition: Int, declared: String, cause: String?, note: String?, at nowMS: Int64) async throws {
        try await store.write { transaction in
            let next = (try transaction.query(
                "SELECT ifnull(max(sequence), 0) FROM memory_recall_reports WHERE query_id = ? AND need_position = ?",
                [.text(queryID), .integer(Int64(needPosition))]
            ) { $0.integer(0) ?? 0 }.first ?? 0) + 1
            try transaction.execute(
                """
                INSERT INTO memory_recall_reports (query_id, need_position, sequence, declared, cause, note, recorded_at_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(queryID), .integer(Int64(needPosition)), .integer(next), .text(declared), cause.map(SQLiteValue.text) ?? .null,
                 note.map(SQLiteValue.text) ?? .null, .integer(nowMS)]
            )
        }
    }

    /// Whether a query of the attempt with this id exists, and its needs' count.
    public func needCount(queryID: String, attemptID: String) async throws -> Int? {
        try await store.read { snapshot in
            let found = try snapshot.query("SELECT count(*) FROM memory_recall_queries WHERE query_id = ? AND task_occurrence_id = ?",
                                           [.text(queryID), .text(attemptID)]) { $0.integer(0) ?? 0 }.first ?? 0
            guard found > 0 else { return nil }
            return Int(try snapshot.query("SELECT count(*) FROM memory_recall_needs WHERE query_id = ?", [.text(queryID)]) {
                $0.integer(0) ?? 0
            }.first ?? 0)
        }
    }

    /// Status is what a diagnosis shows of the index: the live generations, the pending work and the documents
    /// still without a vector.
    public struct Status: Sendable, Equatable {
        public let generations: [Generation]
        public let pendingWork: Int
        public let entries: Int
        public let vectorBacklog: Int

        public init(generations: [Generation], pendingWork: Int, entries: Int, vectorBacklog: Int) {
            self.generations   = generations
            self.pendingWork   = pendingWork
            self.entries       = entries
            self.vectorBacklog = vectorBacklog
        }
    }

    public func status() async throws -> Status {
        try await store.read { snapshot in
            let live = try SQLiteRecallRows.generations(snapshot, where: "status IN ('ready', 'building')")
            let pending = Int(try snapshot.query("SELECT count(*) FROM memory_recall_work WHERE done_at_ms IS NULL") { $0.integer(0) ?? 0 }.first ?? 0)
            let ready = live.first { $0.status == .ready } ?? live.first
            let entries = try ready.map { generation in
                Int(try snapshot.query("SELECT count(*) FROM memory_recall_entries WHERE generation_id = ?",
                                       [.integer(generation.generationID)]) { $0.integer(0) ?? 0 }.first ?? 0)
            } ?? 0
            let backlog = try ready.map { try SQLiteRecallRows.vectorBacklog(snapshot, $0) } ?? 0
            return Status(generations: live, pendingWork: pending, entries: entries, vectorBacklog: backlog)
        }
    }

    /// What a query needs of the status, read without counting the generation's entries or its vectors: the live
    /// generations and the pending work (its partial index makes the count proportional to the work pending). The query
    /// takes the entries and the vectors still missing from the index it holds in memory.
    public func queryStatus() async throws -> Status {
        try await store.read { snapshot in
            let live = try SQLiteRecallRows.generations(snapshot, where: "status IN ('ready', 'building')")
            let pending = Int(try snapshot.query("SELECT count(*) FROM memory_recall_work WHERE done_at_ms IS NULL") { $0.integer(0) ?? 0 }.first ?? 0)
            return Status(generations: live, pendingWork: pending, entries: 0, vectorBacklog: 0)
        }
    }

    /// The sha256 of a document's format and text: its identity, and the key its vector is shared by.
    public static func digest(format: RecallDocument.Format, text: String) -> String {
        SHA256.hash(data: Data((format.rawValue + "\u{1F}" + text).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
