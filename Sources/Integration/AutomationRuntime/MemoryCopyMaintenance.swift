import Dispatch
import Foundation
import OSLog
import SQLiteMemory

/// MemoryCopyMaintenance owns closed-copy maintenance and its diagnostics on a dedicated queue.
/// Filesystem locks, syncs and scans never hold the service actor or the cooperative executor.
actor MemoryCopyMaintenance {
    private nonisolated let executor = MemoryMaintenanceExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let directory: URL
    private let configuration: MemoryService.Configuration
    private var retirement = MemoryService.RetirementStatus()
    private static let log = Logger(subsystem: "dev.forte.Braus", category: "Memory")

    init(directory: URL, configuration: MemoryService.Configuration) {
        self.directory = directory
        self.configuration = configuration
    }

    func recordFailure(_ reason: String) { retirement.reason = reason }

    func status() -> MemoryService.RetirementStatus {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".retired").path) {
            do { try measureRetirement() }
            catch { retirement.reason = String(describing: error) }
        }
        return retirement
    }

    private nonisolated static func copyDate(_ name: String) -> Date? {
        guard name.count >= 22 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS'Z'"
        formatter.isLenient = false
        return formatter.date(from: String(name.suffix(22)))
    }

    /// Retires closed copies only. A failed or ambiguous family remains visible in diagnostics.
    func maintainCopies(now: Date, verifiedBackupAt: Date?) {
        let retired = directory.appendingPathComponent(".retired")
        retirement.collisions = 0
        retirement.incomplete = 0
        retirement.reason = nil
        do {
            // Recover pending manifests even when no new family is eligible.
            try SQLiteArchiveRetirement.privateDirectory(retired)
            try SQLiteArchiveRetirement.exclude(retired)
            let recovery = try SQLiteArchiveRetirement.retire(
                directory.appendingPathComponent(".retirement-recovery"), into: retired
            )
            recordRetirement(recovery)
            guard recovery.state == .retired || recovery.state == .unchanged else {
                try measureRetirement()
                return
            }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let sidecars = ["-wal", "-shm", "-journal"]
            let names = Set(files.map(\.lastPathComponent))
            let orphaned = Set(files.compactMap { file -> String? in
                let name = file.lastPathComponent
                guard name.hasPrefix(configuration.fileName + "."),
                      let suffix = sidecars.first(where: name.hasSuffix) else { return nil }
                let base = String(name.dropLast(suffix.count))
                guard !names.contains(base), base.hasPrefix(configuration.fileName + ".backup-")
                    || base.hasPrefix(configuration.fileName + ".schema-")
                    || base.contains(".refused") || base.contains(".abandoned") else { return nil }
                return base
            })
            for name in orphaned.sorted() {
                recordRetirement(try SQLiteArchiveRetirement.retire(directory.appendingPathComponent(name), into: retired))
            }
            let copies = files.filter { file in
                let name = file.lastPathComponent
                return name.hasPrefix(configuration.fileName + ".") && !sidecars.contains(where: name.hasSuffix)
            }
            for copy in copies where copy.lastPathComponent.hasPrefix(configuration.fileName + ".backup-")
                && Self.copyDate(copy.lastPathComponent) == nil {
                retirement.collisions += 1
                retirement.reason = "retirementNeedsReview: backup creation timestamp is unknown"
            }
            let schemas = copies.filter { $0.lastPathComponent.hasPrefix(configuration.fileName + ".schema-") }
                .sorted { $0.lastPathComponent.suffix(22) > $1.lastPathComponent.suffix(22) }
            let published = try Self.backups(in: directory, configuration: configuration)
            var candidates = Array(published.dropFirst(max(1, configuration.keptBackups))).map(\.url)
            for (index, copy) in schemas.enumerated() {
                guard let created = Self.copyDate(copy.lastPathComponent) else {
                    retirement.collisions += 1
                    retirement.reason = "retirementNeedsReview: schema creation timestamp is unknown"
                    continue
                }
                try SQLiteArchiveRetirement.protectFamily(copy)
                try SQLiteArchiveRetirement.excludeFamily(copy)
                if index > 0 || now.timeIntervalSince(created) >= 30 * 86_400
                    || verifiedBackupAt.map({ $0 > created }) == true {
                    candidates.append(copy)
                }
            }
            candidates += copies.filter {
                $0.lastPathComponent.contains(".refused") || $0.lastPathComponent.contains(".abandoned")
            }
            for copy in candidates {
                recordRetirement(try SQLiteArchiveRetirement.retire(copy, into: retired))
            }
            for copy in try Self.backups(in: directory, configuration: configuration) {
                try SQLiteArchiveRetirement.protectFamily(copy.url)
                try SQLiteArchiveRetirement.excludeFamily(copy.url)
            }
            try measureRetirement()
        } catch {
            retirement.reason = String(describing: error)
            Self.log.error("memory retirement failed: \(String(describing: error), privacy: .private)")
        }
    }

    func recordRetirement(_ report: RetirementReport) {
        if report.state == .needsReview { retirement.collisions += 1 }
        if report.state == .incomplete { retirement.incomplete += 1 }
        if let reason = report.reason { retirement.reason = reason }
    }

    private func measureRetirement() throws {
        let retired = directory.appendingPathComponent(".retired")
        let entries = try FileManager.default.contentsOfDirectory(at: retired, includingPropertiesForKeys: nil)
        let collisions = entries.filter {
            !$0.lastPathComponent.hasPrefix(".pending-")
                && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.lastPathComponent).path)
        }.count
        retirement.collisions = max(retirement.collisions, collisions)
        if collisions > 0 { retirement.reason = "retirementNeedsReview: active and retired names collide" }
        retirement.count = 0
        retirement.incomplete = entries.filter { $0.lastPathComponent.hasPrefix(".pending-") }.count
        retirement.bytes = 0
        var pending = entries
        for entry in entries where !entry.lastPathComponent.hasPrefix(".pending-") {
            if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                retirement.count += 1
            }
        }
        while let file = pending.popLast() {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else {
                throw MemoryUnavailable("retirementNeedsReview: symbolic link in retired directory")
            }
            if values.isRegularFile == true { retirement.bytes += UInt64(values.fileSize ?? 0) }
            if values.isDirectory == true {
                pending += try FileManager.default.contentsOfDirectory(at: file, includingPropertiesForKeys: nil)
            }
        }
    }

    /// Lists published backups, excluding copies named by pending or conflicting retired families.
    nonisolated static func backups(
        in directory: URL,
        configuration: MemoryService.Configuration
    ) throws -> [(url: URL, date: Date)] {
        let retired = directory.appendingPathComponent(".retired")
        let unavailable = FileManager.default.fileExists(atPath: retired.path)
            ? try SQLiteArchiveRetirement.unavailableCopies(in: retired) : []
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .compactMap { file -> (URL, Date)? in
                let name = file.lastPathComponent
                guard name.hasPrefix(configuration.fileName + ".backup-"), !unavailable.contains(name),
                      let date = Self.copyDate(name) else { return nil }
                return (file, date)
            }
            .sorted { $0.1 > $1.1 }
    }
}

/// MemoryMaintenanceExecutor keeps blocking filesystem work on one utility queue per service.
private final class MemoryMaintenanceExecutor: SerialExecutor {
    private let queue = DispatchSerialQueue(label: "dev.forte.Braus.memory.copies", qos: .utility)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}
