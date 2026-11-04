@testable import AutomationMCP
import AutomationRuntime
import Capabilities
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

@MainActor
struct CapabilityStepRecordingTests {
    @Test func schema22AcceptsRegisteredNameAndOneStartAndEnd() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sql = try String(contentsOf: root.appending(path: "Sources/Engine/SQLiteMemory/Resources/memory-schema-22.sql"), encoding: .utf8)
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute(sql)
        let tx = SQLiteTransaction(connection: db)
        let opening = SQLiteCapabilityCallRows.Opening(
            event: ActionContext(eventID: "capability-event", source: .app, streamID: "test", sessionID: nil)
                .event(app: nil, occurredAtMS: 10),
            capabilityID: "demo.write", effect: "write", channel: "braus", origin: "registered", originName: "demo",
            arguments: [try StructuredField(path: "/count", kind: .number, text: "1")], attribution: nil)
        try db.execute("BEGIN IMMEDIATE")
        try SQLiteCapabilityCallRows.began(opening, in: tx)
        try db.execute("COMMIT")
        #expect(try db.query("SELECT tool_kind,execution_status FROM memory_agent_actions") {
            (try $0.text(0) ?? "") + ":" + (try $0.text(1) ?? "")
        } == ["demo.write:started"])
        try db.execute("BEGIN IMMEDIATE")
        try SQLiteCapabilityCallRows.began(opening, in: tx)
        try SQLiteCapabilityCallRows.ended(opening, atMS: 20, results: [], failure: nil,
            verification: "readBack", verified: true, in: tx)
        try SQLiteCapabilityCallRows.ended(opening, atMS: 20, results: [], failure: nil,
            verification: "readBack", verified: true, in: tx)
        try db.execute("COMMIT")
        #expect(try db.query("SELECT capability_id,effect_class FROM memory_call_capabilities") {
            (try $0.text(0) ?? "") + ":" + (try $0.text(1) ?? "")
        } == ["demo.write:write"])
        #expect(try db.query("SELECT verdict FROM memory_verifications") { try $0.text(0) } == ["passed"])
        #expect(try db.query("SELECT scope FROM memory_verifications") { try $0.text(0) } == ["call"])
        #expect(try SchemaCoherence.check(SQLiteSnapshot(connection: db)).isEmpty)
        #expect(try db.query("SELECT count(*) FROM memory_agent_actions") { $0.integer(0) } == [1])
    }

    @Test func dispatcherConfirmsBeforeEffectAndReportsReadFailure() async throws {
        for fails in [false, true] {
            let observer = CapabilityObserver(fails: fails)
            let provider = RecordedRead(observer: observer)
            let tools = AutomationTools(session: ToolResultSession(), capabilities: [provider], recording: observer)
            let answer = try await tools.call("call", .object(["name": .string("demo.read"), "arguments": .object([:])]))
            #expect(await observer.events == (fails ? ["begin", "effect"] : ["begin", "effect", "end"]))
            if fails {
                #expect(answer["content"].array?.first?["text"].string?.contains("not recorded") == true)
            }
        }
    }

    @Test func activeSchemaRecordsReadAndWriteCapabilities() async throws {
        let directory = URL.temporaryDirectory.appending(path: "capability-recorded-" + UUID().uuidString)
        let session = ToolResultSession()
        session.memoryDirectory = directory
        let observer = CapabilityObserver(fails: false)
        let read = AutomationTools(session: session, capabilities: [RecordedRead(observer: observer)])
        let answer = try await read.call("call", .object(["name": .string("demo.read"), "arguments": .object([:])]))
        #expect(answer["isError"].bool != true)
        let write = AutomationTools(session: session, capabilities: [RecordedRead(observer: observer, writes: true)])
        let written = try await write.call("call", .object(["name": .string("demo.read"), "arguments": .object([:])]))
        #expect(written["isError"].bool != true)
        #expect(await observer.events == ["effect", "effect"])
        let memory = MemoryService.shared(for: directory)
        let rows = try await memory.perform { repositories in
            try await repositories.store.read {
                try $0.query("""
                    SELECT count(*) FROM memory_agent_actions a JOIN memory_call_capabilities c USING(event_id)
                    WHERE a.execution_status = 'completed'
                    """) { $0.integer(0) }
            }
        }
        #expect(rows == [2])
        await memory.close()
        try FileManager.default.removeItem(at: directory)
    }

    @Test func historicalSchemaRefusesCapabilityWrites() async throws {
        let directory = URL.temporaryDirectory.appending(path: "capability-historical-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "memory.sqlite")
        let store = SQLiteMemoryStore(url: url, schema: .historical19)
        try await store.open()
        let opening = SQLiteCapabilityCallRows.Opening(
            event: ActionContext(source: .app, streamID: "test", sessionID: nil).event(app: nil, occurredAtMS: 10),
            capabilityID: "demo.write", effect: "write", channel: "braus", origin: "registered", originName: "demo",
            arguments: [], attribution: nil)
        await #expect(throws: SQLiteCapabilityCallRows.Failure.unavailable(schemaVersion: 19)) {
            try await SQLiteCapabilityCallRows(store: store).began(opening)
        }
        let rows = try await store.read { try $0.query("SELECT count(*) FROM memory_agent_actions") { $0.integer(0) } }
        #expect(rows == [0])
        await store.close()
        try FileManager.default.removeItem(at: directory)
    }

    @Test(arguments: [false, true])
    func failedEndSuspendsMemoryAndBlocksNextEffect(_ invalidResult: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: "capability-suspended-" + UUID().uuidString)
        let memory = MemoryService.shared(for: directory)
        let observer = CapabilityObserver(fails: false)
        let provider = RecordedRead(observer: observer, writes: true)
        let contract = try #require(provider.contracts.first)
        let recorder = CapabilityCallRecorder(memory: memory)
        let frame = CapabilityCallRecorder.CallFrame(
            context: ActionContext(source: .app, streamID: "test", sessionID: nil),
            attribution: nil, contract: contract)
        do {
            try await CapabilityCallRecorder.$frame.withValue(frame) {
                try await recorder.ended(contract.id, result: invalidResult ? .number(.nan) : .object([:]),
                    failure: nil, verified: nil)
            }
            Issue.record("An unavailable archive accepted a capability end")
        } catch {
            #expect(await memory.status().suspended != nil)
        }
        let session = ToolResultSession()
        let tools = AutomationTools(session: session, capabilities: [provider], recording: recorder)
        await #expect(throws: AutomationFailure.self) { try await tools.call("call", .object(["name": .string("demo.read"), "arguments": .object([:])])) }
        #expect(await observer.events.isEmpty)
        await memory.close()
        try FileManager.default.removeItem(at: directory)
    }

    @Test func notRecordedContractDoesNotInvokeObserver() async throws {
        let observer = CapabilityObserver(fails: true)
        let provider = RecordedRead(observer: observer, memory: .notRecorded(reason: "diagnostic"))
        let tools = AutomationTools(session: ToolResultSession(), capabilities: [provider], recording: observer)
        let result = try await tools.call("call", .object(["name": .string("demo.read"), "arguments": .object([:])]))
        #expect(await observer.events == ["effect"])
        #expect(result["content"].array?.first?["text"].string?.contains("not recorded") == false)
    }

    @Test func writeIsRefusedWhenStartFails() async throws {
        let observer = CapabilityObserver(fails: true)
        let provider = RecordedRead(observer: observer, writes: true)
        let tools = AutomationTools(session: ToolResultSession(), capabilities: [provider], recording: observer)
        await #expect(throws: AutomationFailure.self) { try await tools.call("call", .object(["name": .string("demo.read"), "arguments": .object([:])])) }
        #expect(await observer.events == ["begin"])
    }
}

private actor CapabilityObserver: CapabilityRecording {
    enum Failure: Error { case refused }
    let fails: Bool
    var events: [String] = []
    init(fails: Bool) { self.fails = fails }
    func began(_ id: CapabilityID, arguments: JSONValue) async throws {
        #expect(CapabilityCallRecorder.frame?.contract.id == id)
        events.append("begin")
        if fails { throw Failure.refused }
    }
    func effect() { events.append("effect") }
    func ended(_ id: CapabilityID, result: JSONValue?, failure: String?, verified: Bool?) async throws {
        #expect(CapabilityCallRecorder.frame?.contract.id == id)
        events.append("end")
    }
}

private nonisolated struct RecordedRead: CapabilityProviding {
    let observer: CapabilityObserver
    var writes = false
    var memory: MemoryRecord = .capabilityStep
    let family = "demo"
    var contracts: [CapabilityContract] {
        [.init(id: .init(rawValue: "demo.read"), group: "inspection", description: "Inspect state.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]),
            effect: writes ? .write : .read, interruption: writes ? .mutating : .readOnly,
            verification: .readBack(description: "Read state"), channel: .braus,
            origin: .registered(provider: "demo"), memory: memory, takesSession: false)]
    }
    func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue {
        await observer.effect()
        return .object(["verified": .bool(true)])
    }
}
