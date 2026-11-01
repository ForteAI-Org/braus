import Darwin
import Foundation
import Testing
@testable import AutomationRuntime

@Suite("Prudent memory backups")
struct MemoryServiceBackupTests {
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

    private func service() throws -> MemoryService {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("braus-ra1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MemoryService(directory: directory, configuration: .init(backupInterval: .zero))
    }

    @Test func backupSkippedOnLowSpace() async throws {
        let service = try service()
        await service.setBackupEnvironment(now: { Date(timeIntervalSince1970: 2_000_000) }, capacity: { _ in 0 })
        _ = try await service.ready()
        await service.waitForBackup()
        #expect(await service.status().backupState == .skipped(.lowSpace))
        #expect(await service.status().lastBackup == nil)
        await service.close()
    }

    @Test func backupBacksOffAfterFailure() async throws {
        let service = try service()
        let start = Date(timeIntervalSince1970: 2_000_000)
        await service.setBackupEnvironment(now: { start }, capacity: { _ in Int64.max })
        await service.setBeforeBackup { throw CocoaError(.fileWriteUnknown) }
        _ = try await service.ready()
        await service.waitForBackup()
        #expect(await service.status().backupRetryAt == start.addingTimeInterval(3_600))
        await service.setBackupEnvironment(now: { start.addingTimeInterval(3_600) }, capacity: { _ in Int64.max })
        await service.runBackupIfDue()
        #expect(await service.status().backupRetryAt == start.addingTimeInterval(10_800))
        await service.setBeforeBackup(nil)
        await service.setBackupEnvironment(now: { start.addingTimeInterval(10_800) }, capacity: { _ in Int64.max })
        await service.runBackupIfDue()
        #expect(await service.status().backupState == .verified)
        #expect(await service.status().backupRetryAt == nil)
        await service.setBeforeBackup { throw CocoaError(.fileWriteUnknown) }
        await service.setBackupEnvironment(now: { start.addingTimeInterval(10_801) }, capacity: { _ in Int64.max })
        await service.runBackupIfDue()
        #expect(await service.status().backupRetryAt == start.addingTimeInterval(14_401))
        await service.close()
    }

    @Test(arguments: [false, true])
    func backupRequiresOneAndAHalfArchiveBytes(_ enough: Bool) async throws {
        let service = try service()
        await service.setBackupEnvironment(now: { Date() }, capacity: { directory in
            var bytes: UInt64 = 0
            for suffix in ["", "-wal"] {
                let path = directory.appendingPathComponent("memory.sqlite").path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: path)
                    bytes += try #require(attributes[.size] as? NSNumber).uint64Value
                }
            }
            return Int64(ceil(Double(bytes) * 1.5)) - (enough ? 0 : 1)
        })
        _ = try await service.ready()
        await service.waitForBackup()
        #expect(await service.status().backupState == (enough ? .verified : .skipped(.lowSpace)))
        await service.close()
    }

    @Test func backupWaitIsCappedAtOneDay() async throws {
        let service = try service()
        var now = Date(timeIntervalSince1970: 3_000_000)
        let start = now
        await service.setBackupEnvironment(now: { start }, capacity: { _ in Int64.max })
        await service.setBeforeBackup { throw CocoaError(.fileWriteUnknown) }
        _ = try await service.ready()
        await service.waitForBackup()
        for hours in [1, 2, 4, 8, 16, 24, 24] {
            let retry = try #require(await service.status().backupRetryAt)
            #expect(retry.timeIntervalSince(now) == Double(hours * 3_600))
            now = retry
            let next = now
            await service.setBackupEnvironment(now: { next }, capacity: { _ in Int64.max })
            await service.runBackupIfDue()
        }
        await service.close()
    }

    @Test func onlyOneSchemaCopyKept() async throws {
        let service = try service()
        let now = Date()
        for day in [1, 2, 3] {
            let stamp = MemoryService.copyStamp(now.addingTimeInterval(-Double(day) * 86_400))
            let file = service.directory.appendingPathComponent("memory.sqlite.schema-19-\(stamp)")
            try Data("old schema".utf8).write(to: file)
        }
        await service.maintainCopies(now: now, verifiedBackupAt: nil)
        #expect(try activeSchemas(service).count == 1)
        await service.maintainCopies(now: now, verifiedBackupAt: now)
        #expect(try activeSchemas(service).isEmpty)
    }

    @Test(arguments: [29, 30])
    func schemaAgeUsesCreationStamp(_ days: Int) async throws {
        let service = try service()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = MemoryService.copyStamp(now.addingTimeInterval(-Double(days) * 86_400))
        let file = service.directory.appendingPathComponent("memory.sqlite.schema-19-\(stamp)")
        try Data("old schema".utf8).write(to: file)
        await service.maintainCopies(now: now, verifiedBackupAt: nil)
        #expect(try activeSchemas(service).count == (days == 29 ? 1 : 0))
    }

    @Test func rotationMovesNeverDeletes() async throws {
        let service = try service()
        let now = Date()
        var originals: [String: Data] = [:]
        for day in 1...5 {
            let name = "memory.sqlite.backup-" + MemoryService.copyStamp(now.addingTimeInterval(-Double(day) * 86_400))
            originals[name] = Data("copy \(day)".utf8)
        }
        originals["memory.sqlite.refused-closed"] = Data("refused".utf8)
        originals["memory.sqlite.abandoned-closed"] = Data("abandoned".utf8)
        for name in Array(originals.keys) {
            for suffix in ["-wal", "-shm", "-journal"] { originals[name + suffix] = Data(suffix.utf8) }
        }
        for (name, bytes) in originals {
            try bytes.write(to: service.directory.appendingPathComponent(name))
        }
        await service.maintainCopies(now: now, verifiedBackupAt: nil)
        let files = try FileManager.default.contentsOfDirectory(at: service.directory, includingPropertiesForKeys: nil)
        #expect(files.filter { $0.lastPathComponent.hasPrefix("memory.sqlite.backup-")
            && $0.lastPathComponent.hasSuffix("Z") }.count == 3)
        for (name, bytes) in originals {
            let active = service.directory.appendingPathComponent(name)
            let base = ["-wal", "-shm", "-journal"].first(where: name.hasSuffix).map { String(name.dropLast($0.count)) } ?? name
            let saved = service.directory.appendingPathComponent(".retired").appendingPathComponent(base)
                .appendingPathComponent(name)
            let location = FileManager.default.fileExists(atPath: active.path) ? active : saved
            #expect(try Data(contentsOf: location) == bytes)
        }
        let status = await service.status()
        #expect(status.retirement.count == 4)
        #expect(status.retirement.bytes > 0)
    }

    @Test func orphanedSidecarsNeedReview() async throws {
        let service = try service()
        let name = "memory.sqlite.backup-" + MemoryService.copyStamp(Date()) + "-wal"
        let file = service.directory.appendingPathComponent(name)
        let bytes = Data("orphaned log".utf8)
        try bytes.write(to: file)
        await service.maintainCopies(now: Date(), verifiedBackupAt: nil)
        #expect(await service.status().retirement.collisions == 1)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func failedBackupDoesNotRetireNewestSchema() async throws {
        let service = try service()
        let now = Date()
        let file = service.directory.appendingPathComponent("memory.sqlite.schema-19-" + MemoryService.copyStamp(now))
        try Data("schema".utf8).write(to: file)
        await service.setBackupEnvironment(now: { now }, capacity: { _ in Int64.max })
        await service.setBeforeBackup { throw CocoaError(.fileWriteUnknown) }
        _ = try await service.ready()
        await service.waitForBackup()
        #expect(try activeSchemas(service).count == 1)
        #expect(try explicitlyExcluded(file))
        await service.close()
    }

    private func activeSchemas(_ service: MemoryService) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: service.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains(".schema-") }
    }
}
