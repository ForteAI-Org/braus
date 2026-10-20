import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// P2-02, P2-03 and P2-05 through the tools: an adapter call's arguments and result are kept as leaves, a later call of
/// the same attempt that names the identifier an earlier result produced is recorded as a reference to that result, two
/// runs with their own identifiers each refer to their own, an adapter's oracle is a check of its own apart from the
/// command's acceptance, and the data context names the account only as a minimal identifier.
///
/// Offline: `AutomationTools` over a session stub and a scripted adapter in place of Notes'. No app or account.
@MainActor
@Suite("P2-02/03/05: structured arguments and results, an adapter's evidence, a call's data context", .serialized)
struct StructuredCallFactsTests {

    /// A notes adapter whose created note gets a fresh identifier, read back after the change, and whose append names it.
    final class NotesFake: AppAdapting, @unchecked Sendable {
        let name = "notes"
        let appNames = ["Notes"]
        let bundleIDs: Set<String> = ["com.apple.Notes"]
        let verbs = [
            AdapterVerb("create_note", "Create a note.",
                        parameters: [AdapterParameter("title", .string, "title", confidential: .content),
                                     AdapterParameter("folder", .string, "folder", required: false)],
                        safety: .write, readBack: "the new note", results: .identifiersAndDates),
            AdapterVerb("append_to_note", "Append.",
                        parameters: [AdapterParameter("id", .string, "the note's id"),
                                     AdapterParameter("text", .string, "text", confidential: .content)],
                        safety: .write, readBack: "the note", results: .identifiersAndDates),
            AdapterVerb("send_copy", "Send a copy from an account.",
                        parameters: [AdapterParameter("id", .string, "the note's id"),
                                     AdapterParameter("from", .string, "account", required: false, confidential: .sensitiveMetadata)],
                        safety: .write, readBack: "nothing", results: .identifiersAndDates, account: "from"),
        ]
        private(set) var created: [String] = []

        func availability() async -> AdapterAvailability { .ready }
        func requestPermission() async -> AdapterAvailability { .ready }
        func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
            switch verb {
                case "create_note":
                    let id = "x-coredata://note/p\(UUID().uuidString.prefix(8))"
                    created.append(id)
                    return await .afterChange("Notes took the note", look: "Read it") {
                        .confirmed("Created.", .object(["id": .string(id), "title": arguments["title"], "folder": .string("Notes")]))
                    }
                case "append_to_note":
                    return await .afterChange("Notes took the text", look: "Read it") {
                        .confirmed("Added.", .object(["id": arguments["id"]]))
                    }
                default:
                    return AdapterOutcome(.actedUnverified, "Sent, not read back.", result: .object(["id": arguments["id"]]))
            }
        }
    }

    static func knowledge() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("braus-p202-\(UUID().uuidString)")
    }

    static func answered(_ result: JSONValue) -> JSONValue {
        if result["structuredContent"] != .null { return result["structuredContent"] }
        let text = result["content"].array?.first?["text"].string ?? ""
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    /// One run: a task, a note created and appended to by the identifier it was given, and the task ended.
    func run(_ tools: AutomationTools, _ adapter: NotesFake, title: String) async throws -> (create: JSONValue, append: JSONValue) {
        _ = try await tools.call("memory_task", .object(["operation": .string("begin"), "goal": .string("Note a title"),
                                                         "remaining": .string("Note a title")]))
        let created = try await tools.call("app_call", .object(["app": .string("Notes"), "verb": .string("create_note"),
                                                                "arguments": .object(["title": .string(title)])]))
        let id = try #require(Self.answered(created)["result"]["id"].string)
        let appended = try await tools.call("app_call", .object(["app": .string("Notes"), "verb": .string("append_to_note"),
                                                                 "arguments": .object(["id": .string(id), "text": .string("more")])]))
        _ = try await tools.call("memory_task", .object(["operation": .string("end"), "outcome": .string("completed")]))
        return (Self.answered(created), Self.answered(appended))
    }

    @Test("two runs create a note and append to it by the identifier each run produced: each reference names its own run's result, the adapter's check is its own, the content is withheld")
    func dynamicResultsPerRun() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let session = CallDispatchRecordTests.RouteFake(.desktop, memory: knowledge)
        let tools = AutomationTools(session: session)
        let adapter = NotesFake()
        tools.adapters = AppAdapters([adapter])
        tools.producer = CallProducer(source: .app, streamID: "p202", traceID: "fields")
        let first = try await run(tools, adapter, title: "SYNTH-TITLE-ONE")
        let second = try await run(tools, adapter, title: "SYNTH-TITLE-TWO")
        #expect(adapter.created.count == 2 && adapter.created[0] != adapter.created[1])

        // P2-03: the answer separates the command's acceptance from the effect its oracle read back.
        let evidence = first.append["evidence"]
        #expect(evidence["command"] == .string("accepted"), "\(first.append)")
        #expect(evidence["effect"]["condition"] == .string("adapter_effect") && evidence["effect"]["verdict"] == .string("passed")
                && evidence["effect"]["method"] == .string("adapter_read_back") && evidence["effect"]["version"] == .string("adapter-oracle-1"),
                "\(evidence)")

        let memory = MemoryService.shared(for: knowledge)
        _ = await memory.flush(within: .seconds(5))
        let calls = try await memory.calls(inTrace: "fields").filter { $0.request.tool == .appCall }
        #expect(calls.count == 4, "\(calls.map(\.request))")
        let creates = [calls[0], calls[2]].map(\.event.eventID), appends = [calls[1], calls[3]].map(\.event.eventID)
        for (index, append) in appends.enumerated() {
            let fields = try await memory.perform { try await $0.facts.argumentFields(of: append) }
            let id = try #require(fields.first { $0.field.path == "/id" })
            #expect(id.kind == .resultReference && id.sourceEventID == creates[index] && id.sourcePath == "/id",
                    "run \(index + 1)'s reference names its own create: \(id)")
            #expect(id.field.text == adapter.created[index])
            let text = try #require(fields.first { $0.field.path == "/text" })
            #expect(text.field.withheld == .confidentialContent && text.field.text == nil, "\(text)")
            let checks = try await memory.perform { try await $0.facts.verifications(of: append) }
            #expect(checks.map(\.check.condition) == [.adapterEffect] && checks.first?.check.verdict == .passed)
            let effect = try await memory.perform { try await $0.facts.effect(of: append) }
            #expect(effect?.performed == .requested && effect?.checked == true)
        }
        for create in creates {
            let results = try await memory.perform { try await $0.facts.resultFields(of: create) }
            #expect(results.first { $0.path == "/id" }?.text != nil, "an identifier is kept")
            #expect(results.first { $0.path == "/title" }?.withheld == .confidentialContent, "a title is withheld")
            #expect(results.first { $0.path == "/folder" }?.withheld == .confidentialContent, "a folder's name is withheld")
            let context = try await memory.perform { try await $0.facts.dataContext(of: create) }
            #expect(context?.service == "notes" && context?.route == .adapter && context?.accountSource == .unknown
                    && context?.resourceKind == "note" && context?.resource != nil, "\(String(describing: context))")
        }
        #expect(second.create["result"]["id"].string == adapter.created[1])
        await MemoryService.closeAll()
        let bytes = try FileManager.default.contentsOfDirectory(atPath: knowledge.path).filter { $0.hasPrefix("memory.sqlite") }
            .map { String(decoding: try Data(contentsOf: knowledge.appendingPathComponent($0)), as: UTF8.self) }.joined()
        #expect(!bytes.contains("SYNTH-TITLE-ONE") && !bytes.contains("SYNTH-TITLE-TWO"), "the titles stay out of the archive")
    }

    @Test("an account the call names is kept only as a minimal identifier; a verb with an account parameter and none named says the default; an unverified change is uncertain")
    func accountAsMinimalIdentifier() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let session = CallDispatchRecordTests.RouteFake(.desktop, memory: knowledge)
        let tools = AutomationTools(session: session)
        tools.adapters = AppAdapters([NotesFake()])
        tools.producer = CallProducer(source: .app, streamID: "p205", traceID: "account")
        let account = "synth.owner@example.invalid"
        let named = try await tools.call("app_call", .object(["app": .string("Notes"), "verb": .string("send_copy"),
                                                              "arguments": .object(["id": .string("n1"), "from": .string(account)])]))
        _ = try await tools.call("app_call", .object(["app": .string("Notes"), "verb": .string("send_copy"),
                                                      "arguments": .object(["id": .string("n2")])]))
        #expect(Self.answered(named)["evidence"]["command"] == .string("uncertain"))
        let memory = MemoryService.shared(for: knowledge)
        _ = await memory.flush(within: .seconds(5))
        let calls = try await memory.calls(inTrace: "account")
        let contexts = try await calls.asyncMap { call in try await memory.perform { try await $0.facts.dataContext(of: call.event.eventID) } }
        #expect(contexts[0]?.accountSource == .argument && contexts[0]?.accountRef?.count == 16, "\(String(describing: contexts[0]))")
        #expect(contexts[1]?.accountSource == .default && contexts[1]?.accountRef == nil, "\(String(describing: contexts[1]))")
        let effect = try await memory.perform { try await $0.facts.effect(of: calls[0].event.eventID) }
        #expect(effect?.performed == .uncertain, "an unverified change may have happened")
        await MemoryService.closeAll()
        let bytes = try FileManager.default.contentsOfDirectory(atPath: knowledge.path).filter { $0.hasPrefix("memory.sqlite") }
            .map { String(decoding: try Data(contentsOf: knowledge.appendingPathComponent($0)), as: UTF8.self) }.joined()
        #expect(!bytes.contains(account), "the account's address is never stored")
    }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var mapped: [T] = []
        for element in self { mapped.append(try await transform(element)) }
        return mapped
    }
}
