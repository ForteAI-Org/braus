//
//  MemoryExecutor.swift
//  Braus
//

import CryptoKit
import Darwin
import Foundation
import Memory
import SQLiteMemory
import Synchronization

/// MemoryExecutor is this process as the executor of the calls it records in one knowledge folder (P2-06): an instance
/// identifier made at its first call, and an exclusive lock on `<id>.lock` held for the process's life, in a folder of the
/// user's temporary directory named by a digest of the knowledge folder's path (`lockFolder`): never inside the knowledge
/// folder, whose files are the memory and its copies. Another process tells whether a call's executor still runs by trying that lock: taken means it ended, busy
/// means it runs, a lock it cannot try (no file, no folder) leaves it unknown, never ended. A process identifier alone
/// is never the test: it is reused.
///
/// `sweep` appends `executor_terminated` to every started call whose executor's lock is free, once per folder and
/// process; the call's own end is never written for it, so a late end stays possible and nothing is replayed.
nonisolated public final class MemoryExecutor: Sendable {

    public let record: ExecutorRecord
    private let descriptor: Int32

    private static let byFolder = Mutex<[String: MemoryExecutor]>([:])
    private static let swept = Mutex<Set<String>>([])

    private init(record: ExecutorRecord, descriptor: Int32) {
        self.record     = record
        self.descriptor = descriptor
    }

    /// This process's executor for `folder`, made and locked once; nil when its lock cannot be taken (the record then
    /// links no executor, and a later process reads the call's executor as unknown).
    public static func current(for folder: URL, source: MemoryEventSource) -> MemoryExecutor? {
        let key = folder.standardizedFileURL.path
        return byFolder.withLock { executors in
            if let known = executors[key] { return known }
            let id = UUID().uuidString.lowercased()
            guard case .success(let descriptor) = AppClaims.lock(id, in: lockFolder(of: folder)) else { return nil }
            let record = ExecutorRecord(executorID: id, source: source.rawValue, processID: getpid(),
                                        startedAtMS: Int64(Date().timeIntervalSince1970 * 1000))
            let executor = MemoryExecutor(record: record, descriptor: descriptor)
            executors[key] = executor
            return executor
        }
    }

    static func lockFolder(of folder: URL) -> URL {
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory.appending(path: "braus-executors", directoryHint: .isDirectory)
            .appending(path: digest, directoryHint: .isDirectory)
    }

    /// Whether the executor `id` of `folder` still runs: true while its lock is held, false once it is free, nil when its
    /// lock cannot be tried.
    public static func isRunning(_ id: String, in folder: URL) -> Bool? {
        let path = lockFolder(of: folder).appending(path: AppClaims.fileName(of: id)).path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let descriptor = Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK ? true : nil
    }

    /// Appends `executor_terminated` to the started calls of other executors whose lock is free, once per folder in this
    /// process; a running or unknown executor's calls are left as they are. Answers the calls it reconciled.
    @discardableResult
    public static func sweep(_ memory: MemoryService, folder: URL, current: MemoryExecutor) async -> [String] {
        let key = folder.standardizedFileURL.path
        guard swept.withLock({ $0.insert(key).inserted }) else { return [] }
        guard let started = try? await memory.perform({ try await $0.facts.startedCalls(excludingExecutor: current.record.executorID) })
        else { return [] }
        var reconciled: [String] = []
        for (eventID, executorID) in started where isRunning(executorID, in: folder) == false {
            guard let fact = try? CallReconciliation(callEventID: eventID, kind: .executorTerminated, declaredBy: .braus,
                                                     recordedAtMS: memory.clock.calendarMS(),
                                                     detail: "the process that started it ended before its end was written")
            else { continue }
            if (try? await memory.perform({ try await $0.facts.reconcile(fact) })) != nil { reconciled.append(eventID) }
        }
        return reconciled
    }

    deinit { Darwin.close(descriptor) }
}

extension MemoryService {

    /// Reads the retained argument fields for a repeat check without exposing the storage implementation.
    public func argumentFields(of callEventID: String) async throws -> [CallArgumentField] {
        try await perform { try await $0.facts.argumentFields(of: callEventID) }
    }

    /// Appends a reconciliation of an earlier call (P2-06), its own end untouched.
    public func reconcile(_ fact: CallReconciliation) async throws {
        _ = try await perform { try await $0.facts.reconcile(fact) }
    }

    /// The values an attempt would take from another attempt's results instead of its own (P2-02).
    public func historicalValues(_ values: [String], attemptID: String) async throws -> [String] {
        try await perform { try await $0.facts.historicalValues(values, attemptID: attemptID) }
    }

    /// The unresolved calls of a producer's stream (P2-06), the asking executor's own started calls left out.
    public func unresolvedCalls(source: MemoryEventSource, streamID: String, excludingExecutor executorID: String?)
        async throws -> [UnresolvedCall] {
        try await perform { try await $0.facts.unresolvedCalls(source: source, streamID: streamID, excludingExecutor: executorID) }
    }
}
