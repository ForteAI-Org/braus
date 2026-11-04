import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import ChatCore
import LocalMCP
import Memory
import Router
import SQLiteMemory
import Testing
@testable import braus

/// P12 exercises files through compact `call` requests from a synthetic provider over the chat's MCP bridge.
/// Each adapter call belongs to the real plan's task, with its dispatch and minimized arguments in the archive.
/// The injected files adapter, provider script and replies use temporary folders outside the chat's own data.
/// No app, Seat, account, personal file or network is used.
@MainActor
@Suite("P12: files through the chat's router, on the record")
struct ChatFilesTests {

    static let written = "braus p12 chat nonce: a quiet line for the chat\n"

    static func text(_ result: LocalMCP.JSONValue) -> String { result["content"].array?.first?["text"].string ?? "" }

    static func answer(_ result: LocalMCP.JSONValue) -> LocalMCP.JSONValue {
        if result["structuredContent"] != .null { return result["structuredContent"] }
        return (try? JSONDecoder().decode(LocalMCP.JSONValue.self, from: Data(text(result).utf8))) ?? .null
    }

    /// The files under `folder` holding `text`'s bytes.
    static func files(under folder: URL, holding text: String) throws -> [String] {
        let needle = Data(text.utf8)
        var holding: [String] = []
        for case let item as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])! {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            do {
                if try Data(contentsOf: item).range(of: needle) != nil { holding.append(item.path) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // SQLite can remove a temporary snapshot sidecar between enumeration and reading it.
                continue
            }
        }
        return holding
    }

    @Test("adapters: write, read, edit and trash through tools/call land on the disk, are recorded under the open task with their dispatch, and leave the content in no file of the chat's")
    func filesThroughTheRouter() async throws {
        let home = URL.temporaryDirectory.appending(path: "braus-chat-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        let trash = home.appending(path: "Trash", directoryHint: .isDirectory)
        let root = home.appending(path: "Home", directoryHint: .isDirectory)
        for folder in [root.appending(path: "Library"), trash] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: home) }
        func request(_ name: String, _ arguments: [String: LocalMCP.JSONValue]) -> LocalMCP.JSONValue {
            .object(["name": .string(name), "arguments": .object(arguments)])
        }
        func capability(_ verb: String, _ arguments: [String: LocalMCP.JSONValue], writes: Bool = true) -> LocalMCP.JSONValue {
            request("call", ["name": .string("files." + verb), "arguments": .object(arguments.merging(
                writes ? ["step": .string("r1")] : [:], uniquingKeysWith: { _, value in value }))])
        }
        let requests = [
            request("plan", ["request": .string("Write a note"), "rows": .array([.object(["title": .string("Write and check the note")])])]),
            capability("write", ["path": .string("~/note.txt"), "text": .string(Self.written)]),
            capability("read", ["path": .string("~/note.txt")], writes: false),
            capability("edit", ["path": .string("~/note.txt"), "find": .string("quiet"), "replace": .string("loud")]),
            capability("write", ["path": .string("~/note.txt"), "text": .string("gone\n")]),
            capability("move_to_trash", ["path": .string("~/note.txt")]),
            request("end", ["outcome": .string("completed")])
        ]
        let provider = try ChatChannelsTests.Chat.provider(in: home, requests: requests)
        let adapters = AppAdapters([FilesAdapter(root: root, trash: { url in
            let moved = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: moved)
            return moved
        })], approver: ChatFileWriteApproval())
        let chat = try ChatChannelsTests.Chat(["--channels", "adapters"], provider: provider, adapters: adapters)
        let replies: [LocalMCP.JSONValue]
        do { replies = try await chat.runProvider(in: home) }
        catch { await chat.end(); throw error }
        try #require(replies.count == requests.count)
        for reply in replies { #expect(reply["error"] == .null, "\(reply)") }
        let task = try #require(Self.answer(replies[0]["result"])["task"].string)
        let trace = try #require(chat.session.current?.conversation.id.uuidString)
        #expect(Self.answer(replies[6]["result"])["status"] == .string("ended"))
        #expect(chat.session.tools.openTask == nil)

        let wrote = Self.answer(replies[1]["result"])
        #expect(wrote["outcome"] == .string("found_acted"), "\(wrote)")
        let read = Self.answer(replies[2]["result"])
        #expect(read["result"]["text"] == .string(Self.written), "\(read)")
        let edited = Self.answer(replies[3]["result"])
        #expect(edited["outcome"] == .string("found_acted"), "\(edited)")
        let refused = Self.answer(replies[4]["result"])
        #expect(refused["outcome"] == .string("refused"), "\(refused)")
        let trashed = Self.answer(replies[5]["result"])
        #expect(trashed["outcome"] == .string("found_acted"), "\(trashed)")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "note.txt").path))
        #expect(try Data(contentsOf: trash.appending(path: "note.txt"))
                == Data(Self.written.replacingOccurrences(of: "quiet", with: "loud").utf8))

        // The record, under the task, each call dispatched to files.<verb>, content the marker.
        let memory = MemoryService.shared(for: chat.root.appending(path: "Knowledge"))
        _ = await memory.flush(within: .seconds(5))
        var verbs: [String] = [], arguments: [String] = [], attributed = true, dispatched = true
        for record in try await memory.calls(inTrace: trace) {
            guard case .appCall(_, let verb, let values) = record.request else { continue }
            let id = record.event.eventID
            verbs.append(verb)
            arguments.append(values)
            if try await memory.perform({ try await $0.facts.attribution(of: id) })?.taskID != task { attributed = false }
            if try await memory.perform({ try await $0.facts.adapterDispatch(of: id) }) != AdapterDispatch(adapter: "files", verb: verb) {
                dispatched = false
            }
        }
        #expect(verbs == ["write", "read", "edit", "write", "move_to_trash"] && attributed && dispatched, "\(verbs)")
        #expect(arguments.allSatisfy { !$0.contains("quiet line") && !$0.contains("loud") }, "\(arguments)")
        #expect(arguments.first?.contains(ValueMinimization.marker) == true && arguments.dropFirst().first == #"{"path":"~/note.txt"}"#, "\(arguments)")

        // No file of the chat's (memory, history, support) holds the content, with the memory open and once it is
        // closed, its WAL folded in; the disk does, outside them.
        for nonce in ["quiet line", "a loud line"] {
            #expect(try Self.files(under: chat.root, holding: nonce).isEmpty, "the chat's folders hold \(nonce)")
        }
        await chat.session.finish()
        await MemoryService.closeAll()
        for nonce in ["quiet line", "a loud line"] {
            #expect(try Self.files(under: chat.root, holding: nonce).isEmpty, "the closed chat's folders hold \(nonce)")
        }
        await chat.end()
    }
}

/// Only synthetic fixture writes receive this per-call approval.
private struct ChatFileWriteApproval: AdapterApproving {
    func approve(_ consent: AdapterConsent) async -> Bool { true }
}
