import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing

@Suite("The app adapters through the tools")
@MainActor
struct AppAdapterToolsTests {

    private static let adapterTools: Set<String> = ["app_capabilities", "app_call"]
    /// The memory's marker for a withheld value (`ValueMinimization.marker`).
    private static let marker = "[withheld]"

    private static func names(_ definitions: [JSONValue]) -> Set<String> {
        Set(definitions.compactMap { $0["name"].string })
    }

    @Test("the adapter tools and their lines exist only where the composition offers the adapters")
    func offeredOnlyWhenComposed() {
        let without = AutomationTools(session: AdapterOnlySession())
        let with    = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([ScribeAdapter()]))
        #expect(Self.names(without.toolDefinitions).isDisjoint(with: Self.adapterTools))
        #expect(without.toolDefinitions == AutomationTools.definitions)
        #expect(Self.names(with.toolDefinitions).subtracting(Self.names(without.toolDefinitions)) == Self.adapterTools)
        #expect(without.instructions == AutomationTools.instructions)
        #expect(!AutomationTools.instructions.contains("app_capabilities"))
        #expect(with.instructions.contains("prefer a verb there over driving the app's interface"))
        #expect(with.instructions.contains("never through Finder, TextEdit"))
    }

    @Test("without adapters an app_call is refused and reaches nothing")
    func refusedWithoutAdapters() async {
        let tools = AutomationTools(session: AdapterOnlySession())
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("app_call", .object(["app": .string("scribe"), "verb": .string("write")]))
        }
    }

    @Test("an app_call needs no session; its content parameters are withheld from the transcript, not from the verb")
    func contentParametersWithheld() async throws {
        let scribe  = ScribeAdapter()
        let tools   = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([scribe]))
        var records = [String]()
        tools.record = { records.append($0) }
        let answer = try await tools.call("app_call", .object([
            "app"      : .string("scribe"),
            "verb"     : .string("write"),
            "arguments": .object(["path": .string("notes.txt"), "text": .string("Zoë's private draft")]),
        ]))
        #expect(answer.payload["outcome"].string == "found_acted")
        #expect(await scribe.written == ["Zoë's private draft"])
        #expect(records.count == 2)
        #expect(records.allSatisfy { !$0.contains("private draft") }, "\(records)")
        #expect(records[0].contains("notes.txt") && records[0].contains(Self.marker))
    }

    @Test("a verb's content result reaches the model whole and its transcript line as the marker")
    func contentResultsWithheldFromTheTranscriptOnly() async throws {
        let tools   = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([ScribeAdapter()]))
        var records = [String]()
        tools.record = { records.append($0) }
        let answer = try await tools.call("app_call", .object([
            "app": .string("scribe"), "verb": .string("read"), "arguments": .object(["path": .string("notes.txt")]),
        ]))
        #expect(answer.payload["result"]["text"].string == "the file's own words")
        #expect(answer.payload["result"]["size"] == .number(19))
        let line = try #require(records.last)
        #expect(line.hasPrefix("← app_call") && !line.contains("the file's own words"))
        #expect(line.contains(Self.marker) && line.contains("\"size\""))
    }

    @Test("an app_call whose verb cannot be resolved withholds every text of its arguments")
    func unresolvedVerbWithholdsEveryText() async throws {
        let tools   = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([ScribeAdapter()]))
        var records = [String]()
        tools.record = { records.append($0) }
        _ = try? await tools.call("app_call", .object([
            "app"      : .string("scribe"),
            "verb"     : .string("erase"),
            "arguments": .object(["text": .string("never shown"), "nested": .array([.string("nor this")]),
                                  "count": .number(2)]),
        ]))
        let call = try #require(records.first)
        #expect(call.hasPrefix("→ app_call") && call.contains("erase") && call.contains("\"count\":2"), "\(call)")
        #expect(records.allSatisfy { !$0.contains("never shown") && !$0.contains("nor this") }, "\(records)")
    }
}

/// ScribeAdapter writes and reads one text, keeping what it was given, so the tools' withholding can be told apart
/// from what reached the verb.
private actor ScribeAdapter: AppAdapting {
    nonisolated let name                 = "scribe"
    nonisolated let appNames             = ["Scribe"]
    nonisolated let bundleIDs: Set<String> = ["test.scribe"]
    nonisolated let verbs = [
        AdapterVerb("write", "Write a text.",
                    parameters: [AdapterParameter("path", .string, "path"),
                                 AdapterParameter("text", .string, "text", content: true)],
                    safety: .write, readBack: "none, a fake"),
        AdapterVerb("read", "Read a text.", parameters: [AdapterParameter("path", .string, "path")],
                    safety: .read, readBack: "none, a fake", contentResults: ["text"]),
    ]

    private(set) var written: [String] = []

    func availability() async -> AdapterAvailability { .ready }

    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        if verb == "write" {
            written.append(arguments["text"].string ?? "")
            return .confirmed("Wrote \(arguments["path"].string ?? "").")
        }
        return .confirmed("Read it.", .object(["text": .string("the file's own words"), "size": .number(19)]))
    }
}

/// AdapterOnlySession has no session and no memory: the adapter tools need neither.
@MainActor
private final class AdapterOnlySession: AutomationSessionOperating {
    let id: UUID? = nil

    func open(application: String, window: String?) async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func observe() async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("unused") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func close() async {}
}
