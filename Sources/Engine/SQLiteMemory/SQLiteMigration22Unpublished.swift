import Darwin
import Foundation
import Memory

extension SQLiteMigration22 {
    /// Retains unrecorded construction families before a fresh attempt, under the caller's reservation.
    /// Every destination is checked before the first rename. A filesystem failure reports retained partial effects.
    static func retainUnpublished(from source: URL, admission: Admission) throws -> [URL] {
        guard admission.isHeld, admission.source == source.standardizedFileURL else { throw Refusal.sourceInUse }
        if let pending = SQLiteMemoryRecovery.pending(of: source) {
            throw MemoryStoreError.unavailable(.interruptedRecovery(pending))
        }
        let directory = source.deletingLastPathComponent()
        let prefixes = [source.lastPathComponent + ".migrating-22-", source.lastPathComponent + ".migration-work-22-"]
        let suffixes = ["-wal", "-shm", "-journal"]
        var bases: Set<String> = []
        for entry in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            guard prefixes.contains(where: entry.hasPrefix) else { continue }
            let base = suffixes.first(where: entry.hasSuffix).map { String(entry.dropLast($0.count)) } ?? entry
            guard ![".used", ".abandoned", ".refused"].contains(where: base.hasSuffix) else { continue }
            bases.insert(base)
        }
        let families = bases.sorted().map { directory.appendingPathComponent($0) }
        for family in families {
            for suffix in [""] + suffixes {
                let target = family.path + ".abandoned" + suffix
                var info = stat()
                if lstat(target, &info) == 0 { throw Refusal.nameTaken(family.lastPathComponent + ".abandoned" + suffix) }
                guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if lstat(family.path + suffix, &info) == 0 {
                    guard info.st_mode & S_IFMT == S_IFREG else {
                        throw Refusal.verificationFailed(["unpublished family is not a regular file"])
                    }
                } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        var retained: [URL] = []
        for family in families {
            let abandoned = URL(fileURLWithPath: family.path + ".abandoned")
            try SQLiteMigration22File.retain(family, as: abandoned)
            retained.append(abandoned)
        }
        return retained
    }
}
