import Foundation
import Memory
import Synchronization
import Testing
@testable import SQLiteMemory

@Suite("Relation recovery selects indexed integer identities")
struct RelationRecoverySelectionTests {
    @Test func selectsLatestEvaluationsAndReturnsPublicIdentityInEventOrder() throws {
        let db = try fixture(count: 8)
        defer { db.close() }
        try db.execute("""
            UPDATE brain_relation_evaluations SET recoverable=0 WHERE call_event_id=1 AND sequence=2;
            UPDATE brain_relation_evaluations SET policy_version='brain-relations-3' WHERE call_event_id=2 AND sequence=2;
            UPDATE memory_agent_actions SET execution_status='started' WHERE event_id=3;
            DELETE FROM brain_relation_evaluations WHERE call_event_id IN (6,7,8);
            INSERT INTO brain_relation_applications(call_event_id) VALUES (7);
            """)
        let waiting = try SQLiteBrainRelationRows.waiting(db, limit: 2)
        #expect(waiting.map(\.0) == ["event-98", "event-96"])
        #expect(waiting.allSatisfy { $0.1.isEmpty })
        let missing = try SQLiteBrainRelationRows.unevaluated(db, limit: 2)
        #expect(missing.map(\.0) == ["event-94", "event-93"])
        #expect(missing.map(\.1) == [false, true])
        let stale = try SQLiteBrainRelationRows.stale(db, limit: 2)
        #expect(stale == ["event-99", "event-97"])
        #expect(try SQLiteBrainRelationRows.waiting(db, limit: 0).map(\.0) == ["event-98"])
        let legacy = try DB2CReadRows(db)
        #expect(try SQLiteBrainRelationRows.waiting(legacy, limit: 2).map(\.0) == waiting.map(\.0))
        #expect(try SQLiteBrainRelationRows.unevaluated(legacy, limit: 2).map(\.0) == missing.map(\.0))
        #expect(try SQLiteBrainRelationRows.stale(legacy, limit: 2) == stale)
    }

    @Test func boundedSelectionDoesNotCorrelatePublicUUIDProjectionsForEveryPair() throws {
        let db = try fixture(count: 1_500)
        defer { db.close() }
        let probes = Mutex(0)
        let control = BrainReadControl(shouldStop: { probes.withLock { $0 += 1; return $0 > 10_000 } })
        try BrainReadControl.$current.withValue(control) { () throws -> Void in
            let snapshot = SQLiteSnapshot(connection: db)
            #expect(try SQLiteBrainRelationRows.waiting(snapshot, limit: 25).count == 25)
            #expect(try SQLiteBrainRelationRows.unevaluated(snapshot, limit: 25).isEmpty)
            #expect(try SQLiteBrainRelationRows.stale(snapshot, limit: 25).count == 25)
        }
        #expect(probes.withLock { $0 } <= 10_000)
    }

    private func fixture(count: Int) throws -> SQLiteConnection {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("""
            PRAGMA user_version=22;
            CREATE TABLE memory_events(event_id INTEGER PRIMARY KEY, event_uuid TEXT NOT NULL UNIQUE);
            CREATE TABLE memory_agent_actions(event_id INTEGER PRIMARY KEY REFERENCES memory_events(event_id),
                tool_kind TEXT,execution_status TEXT);
            CREATE TABLE brain_relation_evaluations(call_event_id INTEGER REFERENCES memory_events(event_id),
                sequence INTEGER,recoverable INTEGER,reason TEXT,policy_version TEXT,UNIQUE(call_event_id,sequence));
            CREATE TABLE brain_relation_applications(call_event_id INTEGER REFERENCES memory_events(event_id));
            WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<\(count))
            INSERT INTO memory_events SELECT i,'event-' || (100-i) FROM n;
            INSERT INTO memory_agent_actions SELECT event_id,'act','completed' FROM memory_events;
            INSERT INTO brain_relation_evaluations SELECT event_id,1,1,'not_concluded','old' FROM memory_events;
            INSERT INTO brain_relation_evaluations SELECT event_id,2,1,'not_concluded','old' FROM memory_events;
            """)
        return db
    }
}
