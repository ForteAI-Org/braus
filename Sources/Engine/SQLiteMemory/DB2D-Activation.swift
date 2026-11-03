import Foundation
import Memory

extension SQLiteMemoryStore {
    /// Distinguishes inspection contention from a refusal of exclusive migration admission.
    struct ActivationPresenceBusy: Error {}

    /// Overrides only capacity reporting in synthetic tests; production always queries the volume.
    @TaskLocal
    package static var migrationAvailableSpace: (@Sendable (URL) throws -> Int64)?

    /// Inspects under shared presence and releases it before the coordinator takes exclusive admission.
    /// The coordinator recognizes the source again under that reservation before publishing anything.
    static func activate22(
        at url: URL,
        opening: Opening,
        policy: MigrationPolicy,
        canMigrate: @escaping @Sendable () -> Bool,
        progress: @Sendable (SQLiteMigration22.Progress) -> Void
    ) async throws -> Migration? {
        if SQLiteMigration22.pendingExchange(of: url) != nil {
            guard opening.writes, policy.permitsMigration else {
                throw MemoryStoreError.unavailable(.interruptedRecovery("schema 22 exchange is pending"))
            }
            guard canMigrate() else { throw SQLiteMigration22.Refusal.personEpisodeOpen }
            _ = try SQLiteMigration22.recover(live: url)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let found: Inspection
        do {
            guard let presence = try SQLiteMemoryPresence.take(.shared, of: url) else {
                throw ActivationPresenceBusy()
            }
            defer { presence.release() }
            if let pending = SQLiteMemoryRecovery.pending(of: url) {
                throw MemoryStoreError.unavailable(.interruptedRecovery(pending))
            }
            found = try inspectOpeningSource(at: url)
        }
        guard let version = migratedVersion(found) else { return nil }
        guard opening.writes, policy.permitsMigration else {
            throw MemoryStoreError.schema(.migrationRequired(found: version, supported: 22))
        }
        let shape: SQLiteMigration22.SourceShape
        let label: String
        switch found {
        case .previous(19): shape = .unified19; label = "19"
        case .previous(20): shape = .command20; label = "command-20"
        case .previous(21): shape = .facts21; label = "facts-21"
        case .previous(1): shape = .historical("version-1"); label = "version-1"
        case .historical(let name): shape = .historical(name); label = name
        default: throw SQLiteMigration22.Refusal.unknownShape(String(version))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS'Z'"
        let stamp = formatter.string(from: Date())
        let target = URL(fileURLWithPath: url.path + ".migrating-22-" + stamp)
        let copyName = url.lastPathComponent + ".schema-" + label + "-" + stamp
        _ = try await SQLiteMigration22.migrate(from: url, shape: shape, into: target,
                                                keepingSourceAs: copyName, canMigrate: canMigrate,
                                                availableSpace: migrationAvailableSpace ?? SQLiteMigration22.availableSpace,
                                                progress: progress)
        return Migration(fromVersion: version, toVersion: 22, copyName: copyName,
                         fromShape: label == "19" ? nil : label)
    }

    /// Keeps the opening error taxonomy used by corruption recovery, without writing the source family.
    private static func inspectOpeningSource(at url: URL) throws -> Inspection {
        do {
            let source = try SQLiteConnection(
                path: url.standardizedFileURL.absoluteString + "?mode=ro&readonly_shm=1",
                readOnly: true, mayCreate: false, uri: true
            )
            defer { source.close() }
            try source.disableAutomaticCloseCheckpoint()
            try source.execute("BEGIN")
            let found = try inspect(source, expected: Expected())
            try source.execute("COMMIT")
            return found
        } catch {
            throw classified(error, phase: .bootstrap)
        }
    }

    /// Restores a retained source and keeps all later schema 22 writes under their own name.
    public nonisolated static func rollBack(at url: URL, to copyName: String) throws {
        try SQLiteMigration22.rollBack(live: url, to: copyName)
    }
}
