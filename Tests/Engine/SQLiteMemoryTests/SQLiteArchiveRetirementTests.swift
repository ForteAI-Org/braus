import Darwin
import Foundation
import Testing
@testable import SQLiteMemory

@Suite("Recoverable archive retirement")
struct SQLiteArchiveRetirementTests {
    // Check explicit metadata so a temporary directory's inherited exclusion cannot hide a missing flag.
    private func explicitlyExcluded(_ file: URL) throws -> Bool {
        let key = "com.apple.metadata:com_apple_backup_excludeItem"
        let size = getxattr(file.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return false }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes {
            getxattr(file.path, key, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard count == size else { throw CocoaError(.fileReadCorruptFile) }
        return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? String
            == "com.apple.backupd"
    }

    private func family() throws -> (URL, URL) {
        let base = try temporaryDatabase("copy")
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try Data("bytes\(suffix)".utf8).write(to: URL(fileURLWithPath: base.path + suffix))
        }
        return (base, base.deletingLastPathComponent().appendingPathComponent(".retired"))
    }

    @Test func rotationMovesNeverDeletes() throws {
        let (base, directory) = try family()
        let report = try SQLiteArchiveRetirement.retire(base, into: directory)
        #expect(report.state == .retired)
        #expect(report.memberCount == 4)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let saved = directory.appendingPathComponent(base.lastPathComponent)
                .appendingPathComponent(base.lastPathComponent + suffix)
            #expect(try Data(contentsOf: saved) == Data("bytes\(suffix)".utf8))
            #expect(!FileManager.default.fileExists(atPath: base.path + suffix))
        }
        #expect(try explicitlyExcluded(directory))
    }

    @Test(arguments: ["", "-wal", "-shm", "-journal"])
    func collisionPreservesWholeFamily(_ suffix: String) throws {
        let (base, directory) = try family()
        let destination = directory.appendingPathComponent(base.lastPathComponent)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("collision".utf8).write(to: destination.appendingPathComponent(base.lastPathComponent + suffix))
        let report = try SQLiteArchiveRetirement.retire(base, into: directory)
        #expect(report.state == .needsReview)
        for member in ["", "-wal", "-shm", "-journal"] {
            #expect(try Data(contentsOf: URL(fileURLWithPath: base.path + member)) == Data("bytes\(member)".utf8))
        }
    }

    @Test(arguments: 1...4)
    func resumesAfterEachMove(_ count: Int) throws {
        let (base, directory) = try family()
        let interrupted = try SQLiteArchiveRetirement.$fault.withValue({ phase, index in
            if phase == .afterMove && index == count { throw SQLiteArchiveRetirement.Interruption() }
        }) {
            try SQLiteArchiveRetirement.retire(base, into: directory)
        }
        #expect(interrupted.state == .incomplete)
        #expect(interrupted.manifestURL != nil)
        #expect(try SQLiteArchiveRetirement.unavailableCopies(in: directory).contains(base.lastPathComponent))
        let resumed = try SQLiteArchiveRetirement.retire(base, into: directory)
        #expect(resumed.state == .retired)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let saved = directory.appendingPathComponent(base.lastPathComponent)
                .appendingPathComponent(base.lastPathComponent + suffix)
            #expect(try Data(contentsOf: saved) == Data("bytes\(suffix)".utf8))
        }
    }

    @Test func failedRollbackResumes() throws {
        let (base, directory) = try family()
        let report = try SQLiteArchiveRetirement.$fault.withValue({ phase, index in
            if phase == .beforeMove && index == 2 || phase == .rollback { throw CocoaError(.fileWriteUnknown) }
        }) {
            try SQLiteArchiveRetirement.retire(base, into: directory)
        }
        #expect(report.state == .incomplete)
        #expect(try SQLiteArchiveRetirement.retire(base, into: directory).state == .retired)
    }

    @Test func rollbackPreservesEveryMemberAndCanResume() throws {
        let (base, directory) = try family()
        let report = try SQLiteArchiveRetirement.$fault.withValue({ phase, index in
            if phase == .beforeMove && index == 3 { throw CocoaError(.fileWriteUnknown) }
        }) {
            try SQLiteArchiveRetirement.retire(base, into: directory)
        }
        #expect(report.state == .incomplete)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            #expect(try Data(contentsOf: URL(fileURLWithPath: base.path + suffix)) == Data("bytes\(suffix)".utf8))
        }
        #expect(try SQLiteArchiveRetirement.retire(base, into: directory).state == .retired)
    }

    @Test func newCollisionDuringRecoveryNeedsReview() throws {
        let (base, directory) = try family()
        let report = try SQLiteArchiveRetirement.$fault.withValue({ phase, index in
            if phase == .afterMove && index == 1 { throw SQLiteArchiveRetirement.Interruption() }
        }) {
            try SQLiteArchiveRetirement.retire(base, into: directory)
        }
        try Data("different bytes".utf8).write(to: base)
        let resumed = try SQLiteArchiveRetirement.retire(base, into: directory)
        #expect(resumed.state == .needsReview)
        let saved = try #require(report.manifestURL).deletingLastPathComponent().appendingPathComponent(base.lastPathComponent)
        #expect(try Data(contentsOf: saved) == Data("bytes".utf8))
        #expect(try Data(contentsOf: base) == Data("different bytes".utf8))
    }

    @Test func archiveAndCopiesArePrivate() async throws {
        let base = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: base)
        let copy = base.deletingLastPathComponent().appendingPathComponent("copy.sqlite")
        _ = try await store.snapshot(to: copy)
        for path in [base.path, base.path + "-wal", base.path + "-shm", base.path + ".lock", copy.path] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: base.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try explicitlyExcluded(copy))
        #expect(try !explicitlyExcluded(base))
        await store.close()
    }

    @Test func splitWithoutManifestNeedsReview() throws {
        let (base, directory) = try family()
        let elsewhere = base.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.moveItem(at: base, to: elsewhere)
        #expect(try SQLiteArchiveRetirement.retire(base, into: directory).state == .needsReview)
        #expect(FileManager.default.fileExists(atPath: base.path + "-wal"))
    }
}
