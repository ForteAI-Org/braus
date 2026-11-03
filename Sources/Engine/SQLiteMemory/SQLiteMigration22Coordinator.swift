import Foundation
import Memory

extension SQLiteMigration22 {
    struct Progress: Sendable, Equatable {
        let phase: Phase
        let rowsDone: Int
        let rowsTotal: Int
    }

    struct Report: Sendable, Equatable {
        let from: SourceShape
        let rowsByTable: [String: Int]
        let outcomesRecorded: Int
        let outcomesConverted: Int
        let outcomesConvertedPartially: Int
        let commandStepsConverted: Int
        let personFactsLeftInSource: Int
        let duration: Duration
    }

    /// Builds an unpublished file under admission. The source may change after this call releases admission.
    /// Use migrate for publication: it keeps the reservation through connection closure and file exchange.
    static func build(
        from source: URL,
        shape: SourceShape,
        into target: URL,
        keepingSourceAs copyName: String? = nil,
        canMigrate: @Sendable () -> Bool = { true },
        availableSpace: (URL) throws -> Int64 = availableSpace,
        at nowMS: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        faults: MigrationFaults = .none,
        progress: @Sendable (Progress) -> Void
    ) async throws -> Report {
        progress(Progress(phase: .preparing, rowsDone: 0, rowsTotal: 0))
        try faults.hit(.phase(.preparing))
        return try withReservation(from: source, shape: shape, canMigrate: canMigrate, availableSpace: availableSpace) { _ in
            try construct(from: source, shape: shape, into: target, copyName: copyName ?? retainedName(source, shape, nowMS),
                          at: nowMS, faults: faults, progress: progress)
        }
    }

    /// Converts and publishes under one exclusive presence lock, closing every source connection before exchange.
    static func migrate(
        from source: URL,
        shape: SourceShape,
        into target: URL,
        keepingSourceAs copyName: String,
        canMigrate: @Sendable () -> Bool = { true },
        availableSpace: (URL) throws -> Int64 = availableSpace,
        at nowMS: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        faults: MigrationFaults = .none,
        progress: @Sendable (Progress) -> Void
    ) async throws -> Report {
        let started = ContinuousClock.now
        progress(Progress(phase: .preparing, rowsDone: 0, rowsTotal: 0))
        try faults.hit(.phase(.preparing))
        return try withReservation(from: source, shape: shape, canMigrate: canMigrate, availableSpace: availableSpace) { admission in
            try validateNames(source, target, copyName)
            try withSource(at: source) { original in
                _ = try SQLiteMigration22Normalization.recognizedHistoricalShape(in: original, shape: shape)
            }
            _ = try retainUnpublished(from: source, admission: admission)
            let built = try construct(from: source, shape: shape, into: target, copyName: copyName,
                                      at: nowMS, faults: faults, progress: progress)
            let total = built.rowsByTable.values.reduce(0, +)
            progress(Progress(phase: .swapping, rowsDone: total, rowsTotal: total))
            try faults.hit(.phase(.swapping))
            guard canMigrate() else { throw Refusal.personEpisodeOpen }
            try Task.checkCancellation()
            try swap(live: source, built: target, keepingSourceAs: copyName, faults: faults, admission: admission) {
                guard canMigrate() else { throw Refusal.personEpisodeOpen }
                try Task.checkCancellation()
            }
            return Report(from: built.from, rowsByTable: built.rowsByTable, outcomesRecorded: built.outcomesRecorded,
                          outcomesConverted: built.outcomesConverted, outcomesConvertedPartially: built.outcomesConvertedPartially,
                          commandStepsConverted: built.commandStepsConverted, personFactsLeftInSource: built.personFactsLeftInSource,
                          duration: started.duration(to: .now))
        }
    }

    private static func construct(
        from source: URL,
        shape: SourceShape,
        into target: URL,
        copyName: String,
        at nowMS: Int64,
        faults: MigrationFaults,
        progress: @Sendable (Progress) -> Void
    ) throws -> Report {
        let started = ContinuousClock.now
        try validateNames(source, target, copyName)
        if let pending = SQLiteMemoryRecovery.pending(of: source) {
            throw MemoryStoreError.unavailable(.interruptedRecovery(pending))
        }
        return try withSource(at: source) { original in
            let version = try original.query("PRAGMA user_version") { $0.integer(0) }.first ?? nil
            guard let version else { throw Refusal.sourceNotReadable }
            if case .historical = shape {
                progress(Progress(phase: .normalizing, rowsDone: 0, rowsTotal: 0))
            }
            let work = URL(fileURLWithPath: source.path + ".migration-work-22-\(UUID().uuidString)")
            return try SQLiteMigration22Normalization.withSource(original, shape: shape, workingAt: work, faults: faults) { normalized in
                var copied: SQLiteMigration22Rows.Report?
                try SQLiteMigration22File.create(at: target, faults: faults) { destination in
                    copied = try SQLiteMigration22Rows.copy(from: normalized, into: destination, at: nowMS, faults: faults) {
                        progress(Progress(phase: $0, rowsDone: $1, rowsTotal: $2))
                    }
                } verify: { destination in
                    guard let copied else { throw Refusal.verificationFailed(["missing conversion report"]) }
                    let total = copied.rowsByTable.values.reduce(0, +)
                    progress(Progress(phase: .verifying, rowsDone: total, rowsTotal: total))
                    let failures = try SchemaCoherence.check(destination)
                    guard failures.isEmpty else { throw Refusal.verificationFailed(failures) }
                    progress(Progress(phase: .recording, rowsDone: total, rowsTotal: total))
                    try faults.hit(.phase(.recording))
                    try destination.run("""
                        INSERT INTO memory_schema_migrations(to_version,from_version,migrated_at_ms,copy_name) VALUES (22,?,?,?)
                        """, [.integer(version), .integer(nowMS), .text(copyName)])
                }
                guard let copied else { throw Refusal.verificationFailed(["missing conversion report"]) }
                return Report(from: shape, rowsByTable: copied.rowsByTable, outcomesRecorded: 0,
                              outcomesConverted: copied.outcomes.converted, outcomesConvertedPartially: copied.outcomes.partiallyConverted,
                              commandStepsConverted: copied.commandStepsConverted, personFactsLeftInSource: copied.personFactsLeftInSource, duration: started.duration(to: .now))
            }
        }
    }

    private static func validateNames(_ source: URL, _ target: URL, _ copyName: String) throws {
        guard source.standardizedFileURL.deletingLastPathComponent() == target.standardizedFileURL.deletingLastPathComponent(),
              source.standardizedFileURL != target.standardizedFileURL,
              !copyName.isEmpty, URL(fileURLWithPath: copyName).lastPathComponent == copyName else {
            throw Refusal.verificationFailed(["migration names"])
        }
    }

    private static func retainedName(_ source: URL, _ shape: SourceShape, _ nowMS: Int64) -> String {
        let name: String
        switch shape {
        case .unified19: name = "19"
        case .command20: name = "command-20"
        case .facts21: name = "facts-21"
        case .historical(let value): name = value
        }
        return source.lastPathComponent + ".schema-" + name + "-\(nowMS)"
    }
}
