//
//  PersistentLogTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import CryptoKit
import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// PersistentLogTests prove, with the library compiled into Braus, the behaviour 7ebe2e5 gave every connection
/// (`SQLITE_FCNTL_PERSIST_WAL`, as Apple's library does by default): the write-ahead log and its index stay beside the
/// archive after the last close; every committed write, checkpointed or still in the log, is read back after a reopen; a
/// read-only connection to an archive with its log files changes neither the archive nor the log; and a copy made through
/// the store is one self-contained file. What a disk measure counts follows: the archive is its file and its two log files.
@Suite("The write-ahead log kept after the last close, with the compiled-in library")
struct PersistentLogTests {

    static func sha(_ path: String) throws -> String {
        SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))).map { String(format: "%02x", $0) }.joined()
    }

    @Test("the log files stay after the last close, and every commit, in the file or still in the log, is read back after a reopen")
    func logKeptAndReadBack() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        for index in 0..<10 { _ = try await record(EventRow(id: "c\(index)", key: "c-k\(index)"), in: store) }
        #expect(try await store.checkpoint().outcome == .complete)
        // Written after the checkpoint: still in the log when the store closes.
        for index in 0..<5 { _ = try await record(EventRow(id: "l\(index)", key: "l-k\(index)"), in: store) }
        await store.close()
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal") && FileManager.default.fileExists(atPath: url.path + "-shm"),
                "the log and its index stay beside the archive")

        let reopened = try await SQLiteMemoryStore.open(at: url, opening: .existingArchive)
        #expect(try await count("SELECT count(*) FROM memory_events", in: reopened) == 15)
        #expect(try await reopened.diagnostics().journalMode == "wal")
        await reopened.close()
    }

    @Test("a read-only connection to an archive with its log files leaves the archive and its log as they were and makes no file")
    func readerChangesNothing() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        for index in 0..<8 { _ = try await record(EventRow(id: "r\(index)", key: "r-k\(index)"), in: store) }
        await store.close()
        let folder = url.deletingLastPathComponent()
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let main = try Self.sha(url.path), log = try Self.sha(url.path + "-wal")

        let reader = try SQLiteConnection(path: url.path, readOnly: true, mayCreate: false)
        try reader.execute("BEGIN")
        #expect(try reader.query("SELECT count(*) FROM memory_events") { $0.integer(0) }.first == 8)
        try reader.execute("COMMIT")
        reader.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before, "no file made")
        #expect(try Self.sha(url.path) == main && Self.sha(url.path + "-wal") == log, "the archive and its log keep their bytes")
    }

    @Test("a copy made through the store is one file in rollback journal mode that opens with no log beside it, holding every commit")
    func copyIsSelfContained() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        for index in 0..<6 { _ = try await record(EventRow(id: "s\(index)", key: "s-k\(index)"), in: store) }
        let copy = url.deletingLastPathComponent().appendingPathComponent("copy-\(UUID().uuidString).sqlite")
        _ = try await store.snapshot(to: copy)
        await store.close()
        #expect(!FileManager.default.fileExists(atPath: copy.path + "-wal") && !FileManager.default.fileExists(atPath: copy.path + "-shm"))
        let connection = try SQLiteConnection(path: copy.path, readOnly: true, mayCreate: false)
        #expect(try connection.query("PRAGMA journal_mode") { try $0.text(0) ?? "" }.first == "delete")
        #expect(try connection.query("SELECT count(*) FROM memory_events") { $0.integer(0) }.first == 6)
        connection.close()
    }
}
