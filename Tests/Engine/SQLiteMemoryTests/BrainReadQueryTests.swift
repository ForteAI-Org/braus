import Foundation
import Memory
@testable import SQLiteMemory
import Synchronization
import Testing

struct BrainReadQueryTests {
    @Test func cancelOnlyOwnReader() throws {
        let reader = try SQLiteConnection(path: ":memory:")
        let person = try SQLiteConnection(path: ":memory:")
        let writer = try SQLiteConnection(path: ":memory:")
        let probes = Mutex(0)
        let control = BrainReadControl(shouldStop: {
            probes.withLock { $0 += 1; return $0 >= 5 }
        })
        try BrainReadControl.$current.withValue(control) {
            #expect(throws: CancellationError.self) {
                _ = try SQLiteSnapshot(connection: reader).query("""
                    WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000000)
                    SELECT sum(x) FROM n
                    """) { $0.integer(0) }
            }
            try BrainReadControl.$current.withValue(nil) {
                let result = try SQLiteSnapshot(connection: person).query("SELECT 42") { $0.integer(0) }
                #expect(result == [42])
            }
            try writer.execute("PRAGMA user_version = 7")
            #expect(try writer.query("PRAGMA user_version") { $0.integer(0) } == [7])
        }
        #expect(probes.withLock { $0 } >= 5)
    }

    @Test func stoppedQueryCleansUpAndReusesReservedReader() async throws {
        let memory = try await ProcedureFixtures.open()
        let probes = Mutex(0)
        let control = BrainReadControl(shouldStop: {
            probes.withLock { $0 += 1; return $0 >= 5 }
        })
        do {
            await #expect(throws: CancellationError.self) {
                try await BrainReadControl.$current.withValue(control) {
                    try await memory.store.read { snapshot in
                        try snapshot.query("""
                            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000000)
                            SELECT sum(x) FROM n
                            """) { $0.integer(0) }
                    }
                }
            }
            let result = try await memory.store.read { snapshot in
                try snapshot.query("""
                    WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000)
                    SELECT sum(x) FROM n
                    """) { $0.integer(0) }
            }
            #expect(result == [500500])
            await #expect(throws: CancellationError.self) {
                try await BrainReadControl.$current.withValue(control) {
                    try await memory.store.read { _ in
                        Issue.record("A stopped read must not enter the reserved connection")
                        return 1
                    }
                }
            }
        } catch {
            await memory.store.close()
            throw error
        }
        await memory.store.close()
    }

    @Test func nestedQueryRestoresOuterProgressHandler() throws {
        let reader = try SQLiteConnection(path: ":memory:")
        let snapshot = SQLiteSnapshot(connection: reader)
        let probes = Mutex(0)
        let control = BrainReadControl(shouldStop: {
            probes.withLock { $0 += 1; return $0 >= 12 }
        })
        BrainReadControl.$current.withValue(control) {
            #expect(throws: CancellationError.self) {
                _ = try snapshot.query("""
                    WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000)
                    SELECT 1 UNION ALL SELECT sum(x) FROM n
                    """) { row in
                        _ = try snapshot.query("SELECT 7") { $0.integer(0) }
                        return row.integer(0)
                    }
            }
        }
        #expect(probes.withLock { $0 } >= 12)
    }

    @Test func handlerRemovedBeforePoolReuse() throws {
        let reader = try SQLiteConnection(path: ":memory:")
        let control = BrainReadControl()
        try BrainReadControl.$current.withValue(control) {
            let result = try SQLiteSnapshot(connection: reader).query("SELECT 7") { $0.integer(0) }
            #expect(result == [7])
        }
        control.requestStop()
        let result = try SQLiteSnapshot(connection: reader).query("""
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000)
            SELECT sum(x) FROM n
            """) { $0.integer(0) }
        #expect(result == [500500])
    }
}
