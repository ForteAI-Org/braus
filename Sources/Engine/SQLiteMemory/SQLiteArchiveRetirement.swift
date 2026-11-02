import CryptoKit
import Darwin
import Foundation

/// RetirementReport describes a closed archive family, including recoverable partial effects.
public struct RetirementReport: Sendable, Equatable {
    public enum State: String, Sendable, Codable {
        case retired, unchanged, incomplete, needsReview, deferred
    }

    public let state: State
    public let memberCount: Int
    public let byteCount: UInt64
    public let manifestURL: URL?
    public let reason: String?
}

/// SQLiteArchiveRetirement preserves closed archive families without overwriting or deleting members.
/// Callers must close every connection first. A dedicated process lock serializes retirement;
/// synced manifests allow the next caller to complete an interrupted family after validating every byte.
public enum SQLiteArchiveRetirement {
    private static let suffixes = ["", "-wal", "-shm", "-journal"]

    private struct Member: Codable {
        let name: String
        let bytes: UInt64
        let digest: String
    }

    private struct Manifest: Codable {
        let version: Int
        let base: String
        let residues: Bool
        let members: [Member]
    }

    package enum Phase: Sendable { case beforeMove, afterMove, rollback }
    package struct Interruption: Error { package init() {} }
    @TaskLocal package static var fault: (@Sendable (Phase, Int) throws -> Void)?

    /// Retires a family into `.retired/<base-name>/`, keeping internal names unchanged.
    /// Defers lock contention without moving members; callers may retry the closed family later.
    /// Throws only before any member moves. Later failures retain a manifest and answer a report.
    public static func retire(_ base: URL, into directory: URL) throws -> RetirementReport {
        try retire(base, into: directory, residues: false)
    }

    /// Retires journals left after a verified copy has been published, as non-restorable residues.
    package static func retireResidues(_ base: URL, into directory: URL) throws -> RetirementReport {
        try retire(base, into: directory, residues: true)
    }

    private static func retire(_ base: URL, into directory: URL, residues: Bool) throws -> RetirementReport {
        let parent = base.deletingLastPathComponent().standardizedFileURL
        guard directory.deletingLastPathComponent().standardizedFileURL == parent,
              directory.lastPathComponent == ".retired" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if !exists(directory), !suffixes.contains(where: { exists(URL(fileURLWithPath: base.path + $0)) }) {
            return report(.unchanged, members: [], manifest: nil)
        }
        try privateDirectory(directory)
        try exclude(directory)
        try sync(parent)
        let lock = try descriptor(directory.appendingPathComponent(".retirement.lock"), flags: O_RDWR | O_CREAT, mode: 0o600)
        defer { close(lock) }
        guard fchmod(lock, 0o600) == 0 else { throw posixError() }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EWOULDBLOCK || code == EINTR {
                return report(.deferred, members: [], manifest: nil,
                              reason: "retirementDeferred: retirement lock is unavailable")
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { flock(lock, LOCK_UN) }

        var didRecover = false
        do {
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            var recovered: RetirementReport?
            for pending in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where pending.lastPathComponent.hasPrefix(".pending-") {
                let report = resume(pending, parent: parent, directory: directory)
                guard report.state == .retired else { return report }
                didRecover = true
                if pendingManifestBase(report.manifestURL) == base.lastPathComponent { recovered = report }
            }
            if let recovered { return recovered }
            let names = (residues ? Array(suffixes.dropFirst()) : suffixes).map { base.lastPathComponent + $0 }
            let members = try names.compactMap { name -> Member? in
                let file = parent.appendingPathComponent(name)
                guard exists(file) else { return nil }
                return try inspect(file)
            }
            if members.isEmpty { return report(.unchanged, members: [], manifest: nil) }
            let manifest = Manifest(version: 1, base: base.lastPathComponent, residues: residues, members: members)
            let final = directory.appendingPathComponent(manifest.base)
            guard !exists(final), residues || members.first?.name == manifest.base else {
                return report(.needsReview, members: members, manifest: nil, reason: "retirementNeedsReview: split family or destination collision")
            }
            let pending = directory.appendingPathComponent(".pending-\(UUID().uuidString)")
            try privateDirectory(pending)
            let manifestURL = pending.appendingPathComponent("manifest.json")
            let data = try JSONEncoder().encode(manifest)
            let fd = try descriptor(manifestURL, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
            do {
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(fd, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                        guard count > 0 else { throw posixError() }
                        offset += count
                    }
                }
                guard fsync(fd) == 0 else { throw posixError() }
            } catch {
                close(fd)
                throw error
            }
            close(fd)
            try sync(pending)
            try sync(directory)
            return transfer(manifest, pending: pending, parent: parent, directory: directory)
        } catch {
            if didRecover {
                return report(.incomplete, members: [], manifest: nil,
                              reason: "retirementIncomplete after recovery: \(error)")
            }
            throw error
        }
    }

    /// Identifies copies that must not be offered to recovery while a family is unresolved.
    package static func unavailableCopies(in directory: URL) throws -> Set<String> {
        var names: Set<String> = []
        for entry in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if entry.lastPathComponent.hasPrefix(".pending-") {
                let manifest = try JSONDecoder().decode(
                    Manifest.self, from: Data(contentsOf: entry.appendingPathComponent("manifest.json"))
                )
                guard manifest.version == 1, safeName(manifest.base), !manifest.members.isEmpty,
                      Set(manifest.members.map(\.name)).count == manifest.members.count,
                      manifest.members.allSatisfy({ suffixes.map { manifest.base + $0 }.contains($0.name) }),
                      manifest.residues || manifest.members.contains(where: { $0.name == manifest.base }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let entries = Set(try FileManager.default.contentsOfDirectory(atPath: entry.path))
                guard entries.isSubset(of: Set(manifest.members.map(\.name)).union(["manifest.json"])) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                names.insert(manifest.base)
            } else {
                names.insert(entry.lastPathComponent)
            }
        }
        return names
    }

    private static func pendingManifestBase(_ url: URL?) -> String? {
        guard let url else { return nil }
        return url.deletingLastPathComponent().lastPathComponent
    }

    private static func resume(_ pending: URL, parent: URL, directory: URL) -> RetirementReport {
        let url = pending.appendingPathComponent("manifest.json")
        do {
            try privateDirectory(pending)
            try privateFile(url)
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            guard manifest.version == 1, safeName(manifest.base), !manifest.members.isEmpty,
                  Set(manifest.members.map(\.name)).count == manifest.members.count,
                  manifest.members.allSatisfy({ suffixes.map { manifest.base + $0 }.contains($0.name) }),
                  manifest.residues || manifest.members.contains(where: { $0.name == manifest.base }) else {
                return report(.needsReview, members: [], manifest: url, reason: "retirementNeedsReview: invalid manifest")
            }
            return transfer(manifest, pending: pending, parent: parent, directory: directory)
        } catch {
            return report(.needsReview, members: [], manifest: url, reason: "retirementNeedsReview: \(error)")
        }
    }

    private static func transfer(_ manifest: Manifest, pending: URL, parent: URL, directory: URL) -> RetirementReport {
        let manifestURL = pending.appendingPathComponent("manifest.json")
        let final = directory.appendingPathComponent(manifest.base)
        var moved: [Member] = []
        do {
            guard !exists(final) else { throw CocoaError(.fileWriteFileExists) }
            let expected = Set(manifest.members.map(\.name))
            let actual = Set(try FileManager.default.contentsOfDirectory(atPath: pending.path))
            guard actual == expected.filter({ exists(pending.appendingPathComponent($0)) }).union(["manifest.json"]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for suffix in suffixes where !expected.contains(manifest.base + suffix) {
                guard !exists(parent.appendingPathComponent(manifest.base + suffix)) else {
                    throw CocoaError(.fileWriteFileExists)
                }
            }
            // Preflight every location and digest before moving any member, including recovery.
            for member in manifest.members {
                let source = parent.appendingPathComponent(member.name)
                let target = pending.appendingPathComponent(member.name)
                guard exists(source) != exists(target), try matches(member, at: exists(source) ? source : target) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        } catch {
            return report(.needsReview, members: manifest.members, manifest: manifestURL,
                          reason: "retirementNeedsReview: \(error)")
        }
        do {
            for (index, member) in manifest.members.enumerated() {
                let target = pending.appendingPathComponent(member.name)
                if exists(target) { continue }
                try fault?(.beforeMove, index + 1)
                let source = parent.appendingPathComponent(member.name)
                try privateFile(source)
                try move(source, target)
                moved.append(member)
                try sync(parent)
                try sync(pending)
                try fault?(.afterMove, index + 1)
            }
            for member in manifest.members {
                guard !exists(parent.appendingPathComponent(member.name)),
                      try matches(member, at: pending.appendingPathComponent(member.name)) else {
                    throw CocoaError(.fileWriteFileExists)
                }
            }
            for suffix in suffixes where !manifest.members.contains(where: { $0.name == manifest.base + suffix }) {
                guard !exists(parent.appendingPathComponent(manifest.base + suffix)) else {
                    throw CocoaError(.fileWriteFileExists)
                }
            }
            try move(pending, final)
            try sync(directory)
            return report(.retired, members: manifest.members, manifest: final.appendingPathComponent("manifest.json"))
        } catch {
            let primary = String(describing: error)
            var failures: [String] = []
            if !(error is Interruption), exists(pending) {
                for (index, member) in moved.reversed().enumerated() {
                    do {
                        try fault?(.rollback, index + 1)
                        try move(pending.appendingPathComponent(member.name), parent.appendingPathComponent(member.name))
                        try sync(pending)
                        try sync(parent)
                    } catch { failures.append(String(describing: error)) }
                }
            }
            return report(.incomplete, members: manifest.members,
                          manifest: exists(pending) ? manifestURL : final.appendingPathComponent("manifest.json"),
                          reason: "retirementIncomplete: \(primary); rollback: \(failures)")
        }
    }

    private static func report(
        _ state: RetirementReport.State,
        members: [Member],
        manifest: URL?,
        reason: String? = nil
    ) -> RetirementReport {
        RetirementReport(state: state, memberCount: members.count,
                         byteCount: members.reduce(0) { $0 + $1.bytes }, manifestURL: manifest, reason: reason)
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func inspect(_ file: URL) throws -> Member {
        let fd = try descriptor(file, flags: O_RDONLY, mode: 0o600)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnsupportedScheme) }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var size: UInt64 = 0
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw posixError() }
            hash.update(data: Data(buffer.prefix(count)))
            size += UInt64(count)
        }
        return Member(name: file.lastPathComponent, bytes: size,
                      digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func matches(_ member: Member, at file: URL) throws -> Bool {
        let found = try inspect(file)
        return member.bytes == found.bytes && member.digest == found.digest
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        // An inaccessible path is occupied, never a destination safe to overwrite.
        return errno != ENOENT && errno != ENOTDIR
    }

    private static func move(_ source: URL, _ target: URL) throws {
        guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
    }

    private static func descriptor(_ file: URL, flags: Int32, mode: mode_t) throws -> Int32 {
        let fd = open(file.path, flags | O_CLOEXEC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw posixError() }
        return fd
    }

    private static func sync(_ directory: URL) throws {
        let fd = try descriptor(directory, flags: O_RDONLY, mode: 0o700)
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    package static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = try descriptor(url, flags: O_RDONLY | O_DIRECTORY, mode: 0o700)
        defer { close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw posixError() }
    }

    package static func privateFile(_ url: URL) throws {
        let fd = try descriptor(url, flags: O_RDONLY, mode: 0o600)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadCorruptFile) }
        guard fchmod(fd, 0o600) == 0 else { throw posixError() }
    }

    package static func protectFamily(_ base: URL) throws {
        for suffix in suffixes {
            let member = URL(fileURLWithPath: base.path + suffix)
            if exists(member) { try privateFile(member) }
        }
    }

    package static func excludeFamily(_ base: URL) throws {
        for suffix in suffixes {
            let member = URL(fileURLWithPath: base.path + suffix)
            if exists(member) { try exclude(member) }
        }
    }

    package static func exclude(_ url: URL) throws {
        var file = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }
}
