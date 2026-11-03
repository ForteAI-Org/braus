import CryptoKit
import Darwin
import Foundation

extension SQLiteMigration22 {
    enum RecoveryResult: Equatable { case nothingPending, completed, restoredSource }

    private enum ExchangeKind: String, Codable {
        case migration, rollback
        var suffix: String { self == .migration ? ".migration-22" : ".rollback-22" }
    }

    private struct Member: Codable, Equatable {
        let suffix: String
        let bytes: Int64
        let digest: String
    }

    private struct ExchangeRecord: Codable {
        let version: Int
        let kind: ExchangeKind
        let live: String
        let kept: String
        let incoming: String
        let outgoingMembers: [Member]
        let incomingMembers: [Member]
    }

    /// Publishes a verified, closed, self-contained 22 and keeps the source with its WAL and SHM.
    /// The coordinator must have verified converted row counts and coherence before calling this.
    /// Every connection must be closed; participating processes are excluded until the record is done.
    static func swap(
        live: URL,
        built: URL,
        keepingSourceAs copyName: String,
        faults: MigrationFaults = .none,
        admission: Admission? = nil,
        beforePublication: () throws -> Void = {}
    ) throws {
        func perform() throws {
            try checkNames(live: live, incoming: built, kept: copyName, kind: .migration)
            try requireNoPending(live)
            try requireVacantFamily(sibling(live, copyName))
            try retainCompletedRecord(live: live, kind: .migration)
            try requireSchema22(built, selfContained: true)
            let record = try makeRecord(live: live, incoming: built, kept: copyName, kind: .migration)
            try fullSync(built, privateFile: true)
            try faults.hit(.beforeRecord)
            try beforePublication()
            try writeRecord(record, live: live)
            try faults.hit(.afterRecord)
            _ = try forward(record, live: live, faults: faults, recovering: false)
        }
        if let admission {
            guard admission.isHeld, admission.source == live.standardizedFileURL else { throw Refusal.sourceInUse }
            try perform()
        } else {
            try exclusive(live, perform)
        }
    }

    /// Restores a schema copy while retaining every later schema 22 write in its own closed family.
    static func rollBack(
        live: URL,
        to copyName: String,
        stamp: String? = nil,
        faults: MigrationFaults = .none
    ) throws {
        try exclusive(live) {
            let kept = live.lastPathComponent + ".schema-22-" + (stamp ?? timestamp())
            let incoming = sibling(live, copyName)
            try checkNames(live: live, incoming: incoming, kept: kept, kind: .rollback)
            try requireNoPending(live)
            try requireVacantFamily(sibling(live, kept))
            try retainCompletedRecord(live: live, kind: .rollback)
            try requireSchema22(live, selfContained: false)
            let expected = try SQLiteMemoryStore.Expected()
            try withSource(at: incoming) { db in
                let version = try db.query("PRAGMA user_version") { $0.integer(0) }.first ?? nil
                guard let version, version < 22,
                    try db.query("PRAGMA integrity_check", [], { try $0.text(0) }) == ["ok"],
                    try SQLiteMemoryStore.inspect(db, expected: expected) != .empty
                else {
                    throw Refusal.unknownShape("rollback copy is not a recognized earlier archive")
                }
            }
            let record = try makeRecord(live: live, incoming: incoming, kept: kept, kind: .rollback)
            try faults.hit(.beforeRecord)
            try writeRecord(record, live: live)
            try faults.hit(.afterRecord)
            _ = try forward(record, live: live, faults: faults, recovering: false)
        }
    }

    /// Resumes a recorded exchange, or restores its outgoing family if the incoming bytes are unsound.
    /// A second interruption is safe: every step has an exclusive destination and a synced directory.
    static func recover(live: URL, faults: MigrationFaults = .none) throws -> RecoveryResult {
        try exclusive(live) {
            let paths = try [ExchangeKind.migration, .rollback].filter { try exists(suffixed(live, $0.suffix)) }
            guard !paths.isEmpty else { return .nothingPending }
            guard paths.count == 1, let kind = paths.first else { throw invalid("two pending exchange records") }
            guard !(try exists(suffixed(live, ".recovering"))) else {
                throw invalid("archive recovery is also pending")
            }
            let path = suffixed(live, kind.suffix)
            let data = try readRegular(path, maximumBytes: 65_536)
            let record = try JSONDecoder().decode(ExchangeRecord.self, from: data)
            try validate(record, live: live, kind: kind)
            try retainCompletedRecord(live: live, kind: kind)
            try validateOutgoing(record, live: live)
            if try incomingIsSound(record, live: live) {
                return try forward(record, live: live, faults: faults, recovering: true)
            }
            return try reverse(record, live: live, faults: faults, abandonIncoming: true, recovering: true)
        }
    }

    /// Names owned by recorded schema 22 exchanges stay beside the archive for rollback and historical inspection.
    /// Corrupt records stop maintenance before any copy can be moved; completed records need no live-byte match.
    package static func retainedCopyNames(live: URL) throws -> Set<String> {
        let files = try FileManager.default.contentsOfDirectory(at: live.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        var names: Set<String> = []
        for kind in [ExchangeKind.migration, .rollback] {
            let base = live.lastPathComponent + kind.suffix
            for file in files where file.lastPathComponent == base || file.lastPathComponent == base + ".done"
                || file.lastPathComponent.hasPrefix(base + ".done-") {
                let record = try JSONDecoder().decode(ExchangeRecord.self,
                    from: readRegular(file, maximumBytes: 65_536))
                try validate(record, live: live, kind: kind)
                for name in [record.kept, record.incoming] where name.hasPrefix(live.lastPathComponent + ".schema-") {
                    names.insert(name)
                }
            }
        }
        return names
    }

    static func pendingExchange(of live: URL) -> String? {
        for suffix in [".migration-22", ".rollback-22"] {
            let path = live.path + suffix
            var info = stat()
            if lstat(path, &info) == 0 || errno != ENOENT {
                return "a schema 22 file exchange did not finish; every file is kept; its recovery record is \(path)"
            }
        }
        return nil
    }

    private static func forward(
        _ record: ExchangeRecord,
        live: URL,
        faults: MigrationFaults,
        recovering: Bool
    ) throws -> RecoveryResult {
        var step = 0
        func move(_ source: URL, _ destination: URL) throws {
            if recovering { try faults.hit(.recovery(step: step)) }
            step += 1
            try rename(source, to: destination)
        }
        let kept = sibling(live, record.kept)
        let incoming = sibling(live, record.incoming)
        try validateOutgoing(record, live: live)
        for member in record.outgoingMembers.sorted(by: { $0.suffix > $1.suffix }) {
            if member.suffix.isEmpty { try faults.hit(.afterRename(.sidecars)) }
            let destination = suffixed(kept, member.suffix)
            if !(try exists(destination)) {
                try requireMatch(suffixed(live, member.suffix), member)
                try move(suffixed(live, member.suffix), destination)
            }
            if member.suffix.isEmpty { try faults.hit(.afterRename(.source)) }
        }
        for suffix in ["-wal", "-shm", "-journal"] where try exists(suffixed(live, suffix)) {
            if let member = record.incomingMembers.first(where: { $0.suffix == suffix }),
                try matches(suffixed(live, suffix), member)
            {
                continue
            }
            _ = try reverse(record, live: live, faults: .none, abandonIncoming: false, recovering: false)
            throw invalid("an unexpected live sidecar appeared before publication")
        }
        for member in record.incomingMembers.sorted(by: { $0.suffix < $1.suffix }) {
            let source = suffixed(incoming, member.suffix)
            let destination = suffixed(live, member.suffix)
            if try exists(source) {
                try requireMatch(source, member)
                try requireVacant(destination)
                try move(source, destination)
            } else {
                try requireMatch(destination, member)
            }
        }
        try faults.hit(.afterRename(.built))
        try move(suffixed(live, record.kind.suffix), suffixed(live, record.kind.suffix + ".done"))
        return .completed
    }

    private static func reverse(
        _ record: ExchangeRecord,
        live: URL,
        faults: MigrationFaults,
        abandonIncoming: Bool,
        recovering: Bool
    ) throws -> RecoveryResult {
        var step = 0
        func move(_ source: URL, _ destination: URL) throws {
            if recovering { try faults.hit(.recovery(step: step)) }
            step += 1
            try rename(source, to: destination)
        }
        let kept = sibling(live, record.kept)
        let incoming = sibling(live, record.incoming)
        let abandoned = suffixed(incoming, ".abandoned")
        try validateOutgoing(record, live: live)
        // Park incoming or unexpected residues before restoring an original beside its own WAL.
        for suffix in ["-wal", "-shm", "-journal", ""] {
            let current = suffixed(live, suffix)
            guard try exists(current) else { continue }
            if let original = record.outgoingMembers.first(where: { $0.suffix == suffix }),
                !(try exists(suffixed(kept, suffix))), try matches(current, original)
            {
                continue
            }
            let belongsToIncoming = record.incomingMembers.contains { $0.suffix == suffix }
            let destination = belongsToIncoming ? suffixed(abandoned, suffix) : suffixed(current, ".abandoned")
            try move(current, destination)
        }
        if abandonIncoming {
            for suffix in ["-wal", "-shm", "-journal", ""] {
                let current = suffixed(incoming, suffix)
                if try exists(current) { try move(current, suffixed(abandoned, suffix)) }
            }
        }
        for member in record.outgoingMembers.sorted(by: { $0.suffix < $1.suffix }) {
            let source = suffixed(kept, member.suffix)
            let destination = suffixed(live, member.suffix)
            if try exists(source) {
                try requireMatch(source, member)
                try requireVacant(destination)
                try move(source, destination)
            } else {
                try requireMatch(destination, member)
            }
        }
        try move(suffixed(live, record.kind.suffix), suffixed(live, record.kind.suffix + ".done"))
        return .restoredSource
    }

    private static func makeRecord(
        live: URL,
        incoming: URL,
        kept: String,
        kind: ExchangeKind
    ) throws -> ExchangeRecord {
        guard !(try exists(suffixed(live, "-journal"))), !(try exists(suffixed(incoming, "-journal"))) else {
            throw invalid("an archive has a rollback journal")
        }
        return ExchangeRecord(
            version: 1,
            kind: kind,
            live: live.lastPathComponent,
            kept: kept,
            incoming: incoming.lastPathComponent,
            outgoingMembers: try members(live),
            incomingMembers: try members(incoming)
        )
    }

    private static func members(_ base: URL) throws -> [Member] {
        try ["", "-wal", "-shm"].compactMap { suffix in
            if suffix != "", !(try exists(suffixed(base, suffix))) { return nil }
            return try fingerprint(suffixed(base, suffix), suffix: suffix)
        }
    }

    private static func validate(_ record: ExchangeRecord, live: URL, kind: ExchangeKind) throws {
        guard record.version == 1, record.kind == kind, record.live == live.lastPathComponent,
            safeName(record.incoming), safeName(record.kept)
        else {
            throw invalid("exchange record identity differs")
        }
        try checkNames(live: live, incoming: sibling(live, record.incoming), kept: record.kept, kind: kind)
        for group in [record.incomingMembers, record.outgoingMembers] {
            guard group.filter({ $0.suffix.isEmpty }).count == 1,
                Set(group.map(\.suffix)).count == group.count,
                group.allSatisfy({
                    ["", "-wal", "-shm"].contains($0.suffix) && $0.bytes >= 0
                        && $0.digest.count == 64 && $0.digest.allSatisfy(\.isHexDigit)
                })
            else {
                throw invalid("invalid exchange member inventory")
            }
        }
        if kind == .migration, record.incomingMembers.count != 1 {
            throw invalid("a migration built file is not self-contained")
        }
    }

    private static func validateOutgoing(_ record: ExchangeRecord, live: URL) throws {
        let kept = sibling(live, record.kept)
        for member in record.outgoingMembers {
            let original = suffixed(live, member.suffix)
            let aside = suffixed(kept, member.suffix)
            if try exists(aside) {
                try requireMatch(aside, member)
                if try matches(original, member) { throw invalid("both names hold an outgoing member") }
            } else {
                try requireMatch(original, member)
            }
        }
    }

    private static func incomingIsSound(_ record: ExchangeRecord, live: URL) throws -> Bool {
        let incoming = sibling(live, record.incoming)
        for member in record.incomingMembers {
            let original = suffixed(incoming, member.suffix)
            if try exists(original) {
                if !(try matches(original, member)) { return false }
            } else if !(try matches(suffixed(live, member.suffix), member)) {
                return false
            }
        }
        return true
    }

    private static func requireSchema22(_ built: URL, selfContained: Bool) throws {
        if selfContained {
            for suffix in ["-wal", "-shm", "-journal"] where try exists(suffixed(built, suffix)) {
                throw invalid("the built file has a sidecar: \(suffix)")
            }
        }
        guard let resource = Bundle.module.url(forResource: "memory-schema-22", withExtension: "sql") else {
            throw invalid("schema 22 resource is missing")
        }
        let expected = try SQLiteMemorySchema.objects(of: String(contentsOf: resource, encoding: .utf8))
        try withSource(at: built) { db in
            guard try db.query("PRAGMA user_version", [], { $0.integer(0) }) == [22],
                try db.query("PRAGMA integrity_check", [], { try $0.text(0) }) == ["ok"],
                try db.query("PRAGMA foreign_key_check", [], { _ in 1 }).isEmpty
            else {
                throw invalid("the built file is not an intact, self-contained schema 22")
            }
            if selfContained, try db.query("PRAGMA journal_mode", [], { try $0.text(0) }) != ["delete"] {
                throw invalid("the built file is not in DELETE journal mode")
            }
            let differences = SQLiteMemorySchema.differences(
                found: try SQLiteMemorySchema.objects(in: db),
                expected: expected
            )
            guard differences.isEmpty else { throw Refusal.verificationFailed(differences) }
        }
    }

    private static func checkNames(live: URL, incoming: URL, kept: String, kind: ExchangeKind) throws {
        guard live.isFileURL, incoming.isFileURL,
            live.deletingLastPathComponent().standardizedFileURL
                == incoming.deletingLastPathComponent().standardizedFileURL,
            safeName(live.lastPathComponent), safeName(kept), safeName(incoming.lastPathComponent),
            Set([live.lastPathComponent, kept, incoming.lastPathComponent]).count == 3,
            kept.hasPrefix(live.lastPathComponent + ".schema-"),
            incoming.lastPathComponent.hasPrefix(
                live.lastPathComponent + (kind == .migration ? ".migrating-22-" : ".schema-")
            )
        else {
            throw invalid("exchange names must identify distinct sibling archives")
        }
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }

    private static func exclusive<T>(_ live: URL, _ body: () throws -> T) throws -> T {
        guard let presence = try SQLiteMemoryPresence.take(.exclusive, of: live) else { throw Refusal.sourceInUse }
        defer { presence.release() }
        return try body()
    }

    /// Keeps every completed exchange record under an exclusive, durable name before reusing its slot.
    /// Unknown files are still collisions; no archive family is removed or overwritten.
    private static func retainCompletedRecord(live: URL, kind: ExchangeKind) throws {
        let completed = suffixed(live, kind.suffix + ".done")
        guard try exists(completed) else { return }
        do {
            let record = try JSONDecoder().decode(ExchangeRecord.self,
                from: readRegular(completed, maximumBytes: 65_536))
            try validate(record, live: live, kind: kind)
        } catch {
            throw Refusal.nameTaken(completed.path)
        }
        try rename(completed, to: suffixed(completed, "-\(UUID())"))
    }

    private static func requireNoPending(_ live: URL) throws {
        if let pending = pendingExchange(of: live) { throw invalid(pending) }
        if FileManager.default.fileExists(atPath: live.path + ".recovering") {
            throw invalid("archive recovery is pending")
        }
    }

    private static func requireVacantFamily(_ base: URL) throws {
        for suffix in ["", "-wal", "-shm", "-journal"] { try requireVacant(suffixed(base, suffix)) }
    }

    private static func requireVacant(_ path: URL) throws {
        if try exists(path) { throw Refusal.nameTaken(path.path) }
    }

    private static func exists(_ path: URL) throws -> Bool {
        var info = stat()
        if lstat(path.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw systemError()
    }

    private static func matches(_ path: URL, _ member: Member) throws -> Bool {
        guard try exists(path) else { return false }
        return try fingerprint(path, suffix: member.suffix) == member
    }

    private static func requireMatch(_ path: URL, _ member: Member) throws {
        guard try matches(path, member) else {
            throw invalid("recorded bytes differ or are absent: \(path.lastPathComponent)")
        }
    }

    private static func fingerprint(_ path: URL, suffix: String) throws -> Member {
        let fd = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw systemError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw invalid("archive member is not a regular file") }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var bytes: Int64 = 0
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError()
            }
            if count == 0 { break }
            bytes += Int64(count)
            buffer.withUnsafeBytes { digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
        guard bytes == info.st_size else { throw invalid("archive member changed while being read") }
        return Member(
            suffix: suffix,
            bytes: bytes,
            digest: digest.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func readRegular(_ path: URL, maximumBytes: Int) throws -> Data {
        let member = try fingerprint(path, suffix: "")
        guard member.bytes <= maximumBytes else { throw invalid("exchange record is too large") }
        return try Data(contentsOf: path)
    }

    private static func writeRecord(_ record: ExchangeRecord, live: URL) throws {
        let destination = suffixed(live, record.kind.suffix)
        try requireVacant(destination)
        let temporary = suffixed(destination, ".writing-\(UUID())")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw systemError() }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw systemError() }
        let data = try JSONEncoder().encode(record)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                if count < 0 { throw systemError() }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw systemError() }
        try rename(temporary, to: destination)
    }

    private static func fullSync(_ path: URL, privateFile: Bool) throws {
        let fd = open(path.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw systemError() }
        defer { close(fd) }
        if privateFile, fchmod(fd, 0o600) != 0 { throw systemError() }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw systemError() }
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw Refusal.nameTaken(destination.path) }
            throw systemError()
        }
        let directory = destination.deletingLastPathComponent()
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw systemError() }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw systemError() }
    }

    private static func sibling(_ live: URL, _ name: String) -> URL {
        live.deletingLastPathComponent().appendingPathComponent(name)
    }
    private static func suffixed(_ base: URL, _ suffix: String) -> URL { URL(fileURLWithPath: base.path + suffix) }
    private static func invalid(_ reason: String) -> Refusal { .verificationFailed([reason]) }
    private static func systemError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS'Z'"
        return formatter.string(from: Date())
    }
}
