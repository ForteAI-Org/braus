import Foundation
import Memory
import Testing
@testable import SQLiteMemory

@Suite("Archive projection import on schema 22", .serialized)
struct DB2CArchiveTests {
    @Test func historicalFactTransferKeepsItsStagingIdentity() async throws {
        let source = try await AgentCallFixtures.open()
        _ = try await source.calls.record(AgentCallFixtures.call("transfer-call", .observe(full: false)))
        await source.store.close()
        let before = try Data(contentsOf: source.url)
        let target = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await target.open()
        let report = try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in Int64.max }) {
            try await SQLiteArchiveTransfer.transfer(from: source.url, origin: "synthetic", location: "synthetic",
                into: target, staging: target.url.deletingLastPathComponent().appending(path: "staging"), nowMS: 1)
        }
        #expect(report.status == "completed", "\(report.detail ?? "no detail")")
        #expect(report.eventsAdded == 1)
        #expect(try await SQLiteAgentCallRepository(store: target).call("transfer-call") != nil)
        #expect(try Data(contentsOf: source.url) == before)
        await target.close()
    }

    @Test func jsonOriginReportsFrozenTablesWithoutProjectionRows() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        let origin = "previous-product:synthetic"
        try await SQLiteArchiveTransfer.beginJSONOnly(store, origin: origin, location: "synthetic", nowMS: 1)
        _ = try await SQLiteBrainRepository(store: store).merge(UIBrain(), into: "com.example.Editor", origin: origin,
                                                               now: Date(timeIntervalSince1970: 1_700_000_000))
        let result = try await SQLiteArchiveTransfer.recordJSONOnly(store, origin: origin, nowMS: 2)
        #expect(result.status == "completed")
        #expect(result.brainsImported == 0)
        #expect(result.frozenTables.contains("brain_anchors"))
        #expect(result.frozenTables.contains("brain_applications"))
        #expect(try await SQLiteArchiveTransfer.origins(store) == [origin: "completed"])
        #expect(try await store.read { try $0.query("SELECT count(*) FROM brain_anchors") { $0.integer(0) }.first ?? nil } == 0)
        #expect(try await store.read { try SchemaCoherence.check($0) }.isEmpty)
        await store.close()
    }
}
