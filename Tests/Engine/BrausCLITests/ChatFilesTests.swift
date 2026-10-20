import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import Router
import SQLiteMemory
import Testing
@testable import braus

/// P12 through `braus chat --channels adapters`: the `files` adapter reached by `app_call` over the chat's own router,
/// as a provider's child sends it, with the chat's memory in front. The test reads the disk itself; the memory holds
/// each call under the task open when it was made, with its dispatch and arguments whose content is the marker; no
/// file of the chat's folders (the memory, the history) holds a byte of what was written or read.
///
/// Offline: the real `ChatSession` on temporary folders, never started, its adapter replaced by one on a temporary
/// root with a Trash of the test's. No app, Seat, account, personal file or network.
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
        let chat = try ChatChannelsTests.Chat(["--channels", "adapters"])
        let home = URL.temporaryDirectory.appending(path: "braus-chat-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        let trash = home.appending(path: "Trash", directoryHint: .isDirectory)
        let root = home.appending(path: "Home", directoryHint: .isDirectory)
        for folder in [root.appending(path: "Library"), trash] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: home) }
        chat.session.tools.adapters = AppAdapters([FilesAdapter(root: root, trash: { url in
            let moved = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: moved)
            return moved
        })], approver: ChatFileWriteApproval())
        let trace = "p12-chat-\(UUID().uuidString)"
        chat.session.tools.producer = CallProducer(source: .cli, streamID: "p12-chat", traceID: trace)
        chat.session.router.resume()
        var number = 0
        func call(_ verb: String, _ arguments: [String: LocalMCP.JSONValue]) async throws -> LocalMCP.JSONValue {
            number += 1
            let response = await chat.session.router.handle(.object([
                "jsonrpc": .string("2.0"), "id": .number(Double(number)), "method": .string("tools/call"),
                "params": .object(["name": .string("app_call"), "arguments": .object([
                    "app": .string("files"), "verb": .string(verb), "arguments": .object(arguments),
                ])]),
            ]))
            return try #require(response?["result"], "\(String(describing: response))")
        }

        _ = try await chat.session.tools.call("memory_task", .object([
            "operation": .string("begin"), "goal": .string("Write a note"), "remaining": .string("Write a note"),
        ]))
        let task = try #require(chat.session.tools.openTask?.taskID)

        let wrote = Self.answer(try await call("write", ["path": .string("~/note.txt"), "text": .string(Self.written)]))
        #expect(wrote["outcome"] == .string("found_acted"), "\(wrote)")
        #expect(try Data(contentsOf: root.appending(path: "note.txt")) == Data(Self.written.utf8))
        let read = Self.answer(try await call("read", ["path": .string("~/note.txt")]))
        #expect(read["result"]["text"] == .string(Self.written), "\(read)")
        let edited = Self.answer(try await call("edit", ["path": .string("~/note.txt"), "find": .string("quiet"), "replace": .string("loud")]))
        #expect(edited["outcome"] == .string("found_acted"), "\(edited)")
        #expect(try Data(contentsOf: root.appending(path: "note.txt")) == Data(Self.written.replacingOccurrences(of: "quiet", with: "loud").utf8))
        let refused = Self.answer(try await call("write", ["path": .string("~/note.txt"), "text": .string("gone\n")]))
        #expect(refused["outcome"] == .string("refused"), "\(refused)")
        let trashed = Self.answer(try await call("move_to_trash", ["path": .string("~/note.txt")]))
        #expect(trashed["outcome"] == .string("found_acted"), "\(trashed)")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "note.txt").path)
                && FileManager.default.fileExists(atPath: trash.appending(path: "note.txt").path))
        chat.session.router.pause()

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
        #expect(arguments[0].contains(ValueMinimization.marker) && arguments[1] == #"{"path":"~/note.txt"}"#, "\(arguments)")

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
