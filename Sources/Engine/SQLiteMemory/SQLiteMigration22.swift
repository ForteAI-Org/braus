import Darwin
import Foundation
import Memory

/// SQLiteMigration22 owns admission and file exchange for the single schema 22 conversion.
/// Its source is read through one read-only transaction, including committed WAL frames.
/// Nothing here activates schema 22 for ordinary store openings.
package enum SQLiteMigration22 {
    /// Admission is borrowed only inside withReservation, until all source connections and exchange work finish.
    final class Admission {
        let source: URL
        private let presence: SQLiteMemoryPresence
        var isHeld: Bool { presence.isHeld }

        fileprivate init(source: URL, presence: SQLiteMemoryPresence) {
            self.source = source
            self.presence = presence
        }
    }
    enum SourceShape: Sendable, Equatable {
        case unified19, command20, facts21
        case historical(String)
    }

    package enum Phase: Sendable, Equatable {
        case preparing, normalizing, copying, convertingObservations, convertingOutcomes
        case verifying, recording, swapping
    }

    enum Refusal: Error, Equatable, LocalizedError {
        case personEpisodeOpen
        case notEnoughSpace(needed: Int64, available: Int64)
        case sourceInUse, sourceNotReadable
        case verificationFailed([String])
        case unknownShape(String)
        case nameTaken(String)

        var errorDescription: String? {
            switch self {
            case .personEpisodeOpen: "Schema 22 migration waits until every person episode ends."
            case .notEnoughSpace(let needed, let available):
                "Schema 22 migration needs \(needed) bytes; \(available) bytes are available."
            case .sourceInUse: "Schema 22 migration requires exclusive use of the archive."
            case .sourceNotReadable: "The migration source cannot be read without writing its files."
            case .verificationFailed(let reasons): "Schema 22 verification failed: " + reasons.joined(separator: "; ")
            case .unknownShape(let shape): "Unrecognized migration source: \(shape)."
            case .nameTaken(let path): "Migration destination already exists: \(path)."
            }
        }
    }

    /// Reserves exclusive presence and checks capacity before opening the source.
    /// The body runs synchronously under that lock and one read transaction; it must not retain the connection.
    static func withAdmission<T>(
        from source: URL,
        shape: SourceShape,
        canMigrate: @Sendable () -> Bool,
        availableSpace: (URL) throws -> Int64 = availableSpace,
        _ body: (SQLiteConnection) throws -> T
    ) throws -> T {
        try withReservation(from: source, shape: shape, canMigrate: canMigrate, availableSpace: availableSpace) { _ in
            try withSource(at: source, body)
        }
    }

    /// Keeps exclusive presence across read-only conversion, connection closure and durable exchange.
    static func withReservation<T>(
        from source: URL,
        shape: SourceShape,
        canMigrate: @Sendable () -> Bool,
        availableSpace: (URL) throws -> Int64 = availableSpace,
        _ body: (Admission) throws -> T
    ) throws -> T {
        guard canMigrate() else { throw Refusal.personEpisodeOpen }
        guard let presence = try SQLiteMemoryPresence.take(.exclusive, of: source) else { throw Refusal.sourceInUse }
        defer { presence.release() }
        if let pending = SQLiteMemoryRecovery.pending(of: source) {
            throw MemoryStoreError.unavailable(.interruptedRecovery(pending))
        }
        let needed = try requiredSpace(sourceBytes: sourceBytes(source), shape: shape)
        let available = try availableSpace(source.deletingLastPathComponent())
        guard available >= needed else { throw Refusal.notEnoughSpace(needed: needed, available: available) }
        guard canMigrate() else { throw Refusal.personEpisodeOpen }
        return try body(Admission(source: source.standardizedFileURL, presence: presence))
    }

    /// Rounds up the 1.5x allowance, or 2.5x when historical normalization needs a working copy.
    static func requiredSpace(sourceBytes: Int64, shape: SourceShape) throws -> Int64 {
        guard sourceBytes >= 0 else { throw POSIXError(.EINVAL) }
        let extra = sourceBytes / 2 + sourceBytes % 2
        let factor: Int64 = if case .historical = shape { 2 } else { 1 }
        let (base, multipliedOverflow) = sourceBytes.multipliedReportingOverflow(by: factor)
        let (needed, addedOverflow) = base.addingReportingOverflow(extra)
        guard !multipliedOverflow, !addedOverflow else { throw POSIXError(.EOVERFLOW) }
        return needed
    }

    /// Opens only a file URI in mode=ro; readonly_shm prevents even shared-memory read marks being written.
    /// Closing after a thrown body ends its transaction without an implicit checkpoint.
    static func withSource<T>(at source: URL, _ body: (SQLiteConnection) throws -> T) throws -> T {
        guard source.isFileURL, source.query == nil, source.fragment == nil else { throw Refusal.sourceNotReadable }
        let uri = source.standardizedFileURL.absoluteString + "?mode=ro&readonly_shm=1"
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection(path: uri, readOnly: true, mayCreate: false, uri: true)
        } catch {
            throw Refusal.sourceNotReadable
        }
        defer { connection.close() }
        do {
            try connection.disableAutomaticCloseCheckpoint()
            try connection.execute("BEGIN")
            _ = try connection.query("SELECT count(*) FROM sqlite_schema") { $0.integer(0) }
        } catch {
            throw Refusal.sourceNotReadable
        }
        let result = try body(connection)
        try connection.execute("COMMIT")
        return result
    }

    private static func sourceBytes(_ source: URL) throws -> Int64 {
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = source.path + suffix
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if suffix != "", errno == ENOENT { continue }
                throw Refusal.sourceNotReadable
            }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw Refusal.sourceNotReadable }
            let (sum, overflow) = total.addingReportingOverflow(info.st_size)
            guard !overflow else { throw POSIXError(.EOVERFLOW) }
            total = sum
        }
        return total
    }

    static func availableSpace(_ directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else { throw POSIXError(.EIO) }
        return bytes
    }
}
