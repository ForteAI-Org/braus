import Foundation
import Testing

@testable import SQLiteMemory

@Suite("SchemaMigration22 integer identities")
struct SchemaMigration22KeyTests {
    @Test
    func eventKeysKeepLocalOrderAndChildrenInheritIt() throws {
        try fixture { source, target in
            let keys = try SQLiteMigration22Keys(in: target)
            #expect(try keys.assign(from: source, table: "memory_events", columns: ["event_id"], idColumn: "local_order") == 2)
            #expect(try keys.assign(from: source, table: "memory_agent_actions", columns: ["event_id"], parent: "memory_events") == 2)
            for table in ["memory_events", "memory_agent_actions"] {
                #expect(try keys.id(in: table, for: [.text("first")]) == 7)
                #expect(try keys.id(in: table, for: [.text("second")]) == 81)
            }
            #expect(try source.query("SELECT event_id FROM memory_agent_actions ORDER BY rowid") { try $0.text(0) }
                    == ["second", "first"])
            #expect(try SQLiteMemorySchema.objects(in: target).isEmpty)
        }
    }

    @Test
    func compositeKeysPreserveExactBytesAndTypes() throws {
        try fixture { source, target in
            let keys = try SQLiteMigration22Keys(in: target)
            #expect(try keys.assign(from: source, table: "brain_menu_path_segments", columns: ["menu_command_id", "position"]) == 4)
            let names = ["caf\u{e9}", "cafe\u{301}", "a\u{0}b", "a|b"]
            let ids = try names.map { try keys.id(in: "brain_menu_path_segments", for: [.text($0), .integer(0)]) }
            #expect(Set(ids).count == 4)
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["missing identity in brain_menu_path_segments"])) {
                _ = try keys.id(in: "brain_menu_path_segments", for: [.text(names[0]), .text("0")])
            }
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["missing identity in brain_menu_path_segments"])) {
                _ = try keys.id(in: "brain_menu_path_segments", for: [.text("a"), .text("b|0")])
            }
            #expect(try keys.id(in: "brain_menu_path_segments", for: [.text(names[0]), .integer(0)]) == ids[0])
            #expect(try keys.id(in: "brain_menu_path_segments", for: [.text(names[2]), .integer(0)]) == ids[2])
        }
    }

    @Test
    func unresolvedParentsAndDuplicateIdentityAllocationRefuse() throws {
        try fixture { source, target in
            let keys = try SQLiteMigration22Keys(in: target)
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["missing identity in memory_events"])) {
                _ = try keys.assign(from: source, table: "memory_agent_actions", columns: ["event_id"], parent: "memory_events")
            }
            _ = try keys.assign(from: source, table: "memory_events", columns: ["event_id"], idColumn: "local_order")
            #expect(throws: (any Error).self) {
                _ = try keys.assign(from: source, table: "memory_events", columns: ["event_id"], idColumn: "local_order")
            }
            #expect(try keys.id(in: "memory_events", for: [.text("second")]) == 81)
        }
    }

    @Test
    func untrustedIdentifiersAreRefusedBeforePreparingSQL() throws {
        try fixture { source, target in
            let keys = try SQLiteMigration22Keys(in: target)
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["identity table"])) {
                _ = try keys.assign(from: source, table: "unknown", columns: ["event_id"])
            }
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["identity columns of memory_events"])) {
                _ = try keys.assign(from: source, table: "memory_events", columns: ["event_id; SELECT 1"])
            }
            #expect(throws: SQLiteMigration22.Refusal.verificationFailed(["identity columns of memory_events"])) {
                _ = try keys.assign(from: source, table: "memory_events", columns: ["event_id"], idColumn: "event_id")
            }
        }
    }

    private func fixture(_ body: (SQLiteConnection, SQLiteConnection) throws -> Void) throws {
        let source = try SQLiteConnection(path: ":memory:")
        defer { source.close() }
        let target = try SQLiteConnection(path: ":memory:")
        defer { target.close() }
        try source.execute(SQLiteMemorySchema.historical19Text())
        try source.execute("""
            INSERT INTO memory_events(local_order,event_id,source,source_stream_id,event_kind,occurred_at_ms,capture_status)
            VALUES (7,'first','cli','synthetic','action',0,'not_applicable'),
                   (81,'second','cli','synthetic','action',0,'not_applicable');
            INSERT INTO memory_agent_actions(event_id,tool_kind,execution_status)
            VALUES ('second','act','planned'),('first','act','planned');
            """)
        for name in ["caf\u{e9}", "cafe\u{301}", "a\u{0}b", "a|b"] {
            try source.run("INSERT INTO brain_menu_path_segments(menu_command_id,position,title) VALUES (?,0,'Synthetic')", [.text(name)])
        }
        try source.execute("BEGIN")
        try target.execute("BEGIN IMMEDIATE")
        try body(source, target)
    }
}
