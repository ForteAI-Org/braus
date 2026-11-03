import Foundation
import Memory

@testable import SQLiteMemory

extension AgentCallFixtures {
    static func open22(at url: URL? = nil) async throws -> Memory {
        let url = try url ?? temporaryDatabase()
        let store = SQLiteMemoryStore(url: url, schema: .version22)
        try await store.open()
        return Memory(
            url: url,
            store: store,
            calls: SQLiteAgentCallRepository(store: store),
            captures: SQLiteCaptureRepository(store: store)
        )
    }
}

extension AttributionFixtures {
    static func open22(at url: URL? = nil) async throws -> Memory {
        let url = try url ?? temporaryDatabase()
        let store = SQLiteMemoryStore(url: url, schema: .version22)
        try await store.open()
        return Memory(
            url: url,
            store: store,
            captures: SQLiteCaptureRepository(store: store),
            calls: SQLiteAgentCallRepository(store: store),
            inputs: SQLiteObservedInputRepository(store: store),
            verifications: SQLiteVerificationRepository(store: store),
            tasks: SQLiteTaskRepository(store: store)
        )
    }
}

/// DB2BFixtureSQL plants malformed history only in synthetic test databases.
enum DB2BFixtureSQL {
    static func withoutGuards<T>(_ transaction: SQLiteTransaction, names: [String], body: () throws -> T) throws -> T {
        var definitions: [String] = []
        for name in names {
            guard
                let sql = try transaction.query(
                    "SELECT sql FROM sqlite_schema WHERE type='trigger' AND name=?",
                    [.text(name)],
                    {
                        try $0.text(0)
                    }
                ).first ?? nil
            else { throw SQLiteMigration22.Refusal.verificationFailed(["missing fixture guard"]) }
            definitions.append(sql)
            try transaction.execute("DROP TRIGGER \(name)")
        }
        let result = try body()
        for sql in definitions { try transaction.execute(sql) }
        return result
    }
}

extension TaskFixtures {
    static func open22() async throws -> Memory {
        let url = try temporaryDatabase()
        let store = SQLiteMemoryStore(url: url, schema: .version22)
        try await store.open()
        return Memory(
            url: url,
            store: store,
            tasks: SQLiteTaskContextRepository(store: store),
            facts: SQLiteOperationFactRepository(store: store),
            calls: SQLiteAgentCallRepository(store: store)
        )
    }
}

extension SceneFixtures {
    static func open22(at url: URL? = nil, ids: SceneIDs = SceneIDs()) async throws -> Memory {
        let url = try url ?? temporaryDatabase()
        let store = SQLiteMemoryStore(url: url, schema: .version22)
        try await store.open()
        return Memory(
            url: url,
            store: store,
            captures: SQLiteCaptureRepository(store: store),
            scenes: SQLiteSceneRepository(store: store, makeSceneID: { ids.next() }),
            ids: ids
        )
    }
}
