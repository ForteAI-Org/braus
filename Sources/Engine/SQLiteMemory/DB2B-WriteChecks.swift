/// DB2BWriteChecks validates schema-22 relationships before a repository transaction commits.
/// Schema-19 writes retain their historical trigger checks.
enum DB2BWriteChecks {
    static func perform<T>(_ transaction: SQLiteTransaction, _ body: () throws -> T) throws -> T {
        let result = try body()
        if try SQLiteRowIdentity(transaction).usesIntegerKeys {
            let failures = try SchemaCoherence.check(transaction)
            guard failures.isEmpty else {
                throw SQLiteConnection.Failure(primary: 19, extended: 1811, message: failures.joined(separator: ", "))
            }
        }
        return result
    }
}

extension SQLiteMemoryStore {
    /// Runs a repository write with schema coherence checked before commit.
    func db2BWrite<T: Sendable>(_ body: @Sendable (SQLiteTransaction) throws -> T) async throws -> T {
        try await write { transaction in
            try DB2BWriteChecks.perform(transaction) { try body(transaction) }
        }
    }
}
