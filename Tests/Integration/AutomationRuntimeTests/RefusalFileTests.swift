import Foundation
import LocalMCP
import Testing
@testable import AutomationRuntime

/// P2-06: a person's refusal kept in a refusal file outlives the barrier that noted it, with a digest and never an
/// argument, and opens only when the same call is consented to.
@MainActor
@Suite("P2-06: refusals kept across a restart")
struct RefusalFileTests {

    @Test("a refusal kept in a refusal file closes a barrier made again for its context; the same call consented opens it")
    func refusalOutlivesTheBarrier() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("braus-refusals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let arguments: JSONValue = .object(["channel": .string("Synthetic"), "text": .string("SYNTH-SECRET-TEXT")])
        let first = ActionBarrier(persistingIn: folder, context: "conversation-1")
        first.note(.refusedByPerson(.null), of: "app_call", arguments)
        #expect(first.isClosed && !first.persistenceFailed)
        let stored = String(decoding: try Data(contentsOf: folder.appending(path: "refusals.json")), as: UTF8.self)
        #expect(!stored.contains("SYNTH-SECRET-TEXT") && !stored.contains("Synthetic"), "only a digest is written")
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appending(path: "refusals.json").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        // After a restart: the same context is closed, another is not.
        let again = ActionBarrier(persistingIn: folder, context: "conversation-1")
        #expect(again.isClosed && again.refusal(of: "app_call", .object([:])) != nil)
        #expect(again.refusal(of: "app_call", arguments) == nil, "the refused call itself may be decided again")
        #expect(!ActionBarrier(persistingIn: folder, context: "conversation-2").isClosed)
        again.note(.consented(.null), of: "app_call", arguments)
        #expect(!ActionBarrier(persistingIn: folder, context: "conversation-1").isClosed, "consented: opened, and kept so")
    }

    @Test("the app's store of external clients' barriers, made again on the same folder as at a restart, keeps each profile's refusal; without a folder nothing is kept")
    func storeOutlivesTheApp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("braus-refusals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let arguments: JSONValue = .object(["title": .string("SYNTH-TITLE")])
        ActionBarrier.Store(persistingIn: folder).barrier(for: "profile-a").note(.refusedByPerson(.null), of: "app_call", arguments)
        let restarted = ActionBarrier.Store(persistingIn: folder)
        #expect(restarted.barrier(for: "profile-a").isClosed, "the profile's refusal outlives the app's run")
        #expect(!restarted.barrier(for: "profile-b").isClosed, "another profile is not closed by it")
        let memoryOnly = ActionBarrier.Store()
        memoryOnly.barrier(for: "profile-a").note(.refusedByPerson(.null), of: "app_call", arguments)
        #expect(!ActionBarrier.Store().barrier(for: "profile-a").isClosed)
    }
    @Test("contexts initialized before either writes retain matching consent after restart")
    func sharedSalt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("braus-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let arguments: JSONValue = .object(["title": .string("SYNTH-AUDIT")])
        let first = ActionBarrier(persistingIn: folder, context: "first")
        let second = ActionBarrier(persistingIn: folder, context: "second")
        first.note(.refusedByPerson(.null), of: "app_call", arguments)
        second.note(.refusedByPerson(.null), of: "app_call", arguments)
        let restarted = ActionBarrier(persistingIn: folder, context: "second")
        #expect(restarted.isClosed)
        #expect(restarted.refusal(of: "app_call", arguments) == nil)
        restarted.note(.consented(.null), of: "app_call", arguments)
        #expect(!restarted.isClosed)
    }

    @Test("a barrier observes a refusal written by another owner of the same context")
    func sharedContextRefresh() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("braus-refusals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = ActionBarrier(persistingIn: folder, context: "shared")
        let second = ActionBarrier(persistingIn: folder, context: "shared")
        first.note(.refusedByPerson(.null), of: "app_call", .null)
        #expect(second.isClosed)
        #expect(second.refusal(of: "act", .null) != nil)
        second.note(.consented(.null), of: "app_call", .null)
        #expect(!first.isClosed)
    }

    @Test("a corrupt refusal file blocks actions without replacing its contents")
    func unreadableStoreFailsClosed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("braus-refusals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "refusals.json")
        let bytes = Data("not-json".utf8)
        try bytes.write(to: url)
        let barrier = ActionBarrier(persistingIn: folder, context: "shared")
        #expect(barrier.isClosed)
        #expect(barrier.refusal(of: "app_call", .null) != nil)
        #expect(barrier.refusal(of: "status", .null) == nil)
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test("concurrent owners preserve every context under the shared file lock")
    func concurrentWriters() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("braus-refusals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for n in 0..<12 {
                group.addTask {
                    let file = RefusalFile(folder: folder, context: "context-\(n)")
                    return file.save(ActionBarrier.Refused(tool: "synthetic", digest: "digest-\(n)"))
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(saved.allSatisfy { $0 })
        for n in 0..<12 {
            #expect(try RefusalFile(folder: folder, context: "context-\(n)").load()?.digest == "digest-\(n)")
        }
    }

}
