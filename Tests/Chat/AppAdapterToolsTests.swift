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

    // MARK: open_session and the task router

    /// The `named` argument `open_session` takes from these tools, `.null` when it takes none.
    private static func namedProperty(of tools: AutomationTools) -> JSONValue {
        tools.toolDefinitions.first { $0["name"].string == "open_session" }?["inputSchema"]["properties"]["named"] ?? .null
    }

    private static func open(_ tools: AutomationTools, _ app: String, named: Bool? = nil) async throws -> JSONValue {
        var arguments: [String: JSONValue] = ["app": .string(app)]
        if let named { arguments["named"] = .bool(named) }
        return try await tools.call("open_session", .object(arguments)).payload
    }

    @Test("open_session on an app the resolver names as one with an adapter answers the adapter and opens nothing")
    func routedToTheAdapter() async throws {
        let session = RoutingSession()
        let tools   = AutomationTools(session: session, adapters: AppAdapters([CalendarStub(.ready)]))
        let answer  = try await Self.open(tools, "Calendario")
        #expect(answer["opened"] == .bool(false))
        #expect(answer["route"].string == "app_call(calendar)")
        #expect(answer["message"].string?.hasPrefix("Calendario: use app_call with app \"calendar\"") == true)
        #expect(session.resolved == ["Calendario"] && session.opened.isEmpty)
        #expect(Self.namedProperty(of: tools)["type"].string == "boolean")
    }

    @Test("open_session opens as asked when the person named the app, or the seat holds it already")
    func namedOrHeldOpens() async throws {
        let session = RoutingSession()
        let tools   = AutomationTools(session: session, adapters: AppAdapters([CalendarStub(.ready)]))
        _ = try await Self.open(tools, "Calendario", named: true)
        #expect(session.opened == ["Calendario"] && session.resolved.isEmpty)
        session.held = "com.apple.iCal"
        _ = try await Self.open(tools, "Calendar")
        #expect(session.opened == ["Calendario", "Calendar"])
    }

    @Test("without the adapters open_session opens as asked, routes nothing and takes no named")
    func notRoutedWithoutAdapters() async throws {
        let session = RoutingSession()
        let tools   = AutomationTools(session: session)
        _ = try await Self.open(tools, "Calendario")
        #expect(session.opened == ["Calendario"] && session.resolved.isEmpty)
        await #expect(throws: AutomationFailure.self) { try await Self.open(tools, "Calendario", named: false) }
        #expect(Self.namedProperty(of: tools) == .null)
    }

    @Test("an adapter that cannot run is skipped: the app opens, and the answer says why")
    func skippedAdapterOpensWithANote() async throws {
        let session = RoutingSession()
        let tools   = AutomationTools(session: session,
                                      adapters: AppAdapters([CalendarStub(.needsPermission("no Calendars access"))]))
        let answer  = try await Self.open(tools, "Calendario")
        #expect(session.opened == ["Calendario"])
        #expect(answer["routeNote"].string?.contains("no Calendars access") == true)
    }
}

/// CalendarStub is a calendar adapter with no verb, whose availability the test sets.
private struct CalendarStub: AppAdapting {
    let name                 = "calendar"
    let appNames             = ["Calendar"]
    let bundleIDs: Set<String> = ["com.apple.iCal"]
    let verbs: [AdapterVerb] = []
    let state: AdapterAvailability

    init(_ state: AdapterAvailability) { self.state = state }

    func availability() async -> AdapterAvailability { state }

    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        throw AdapterFailure("unused")
    }
}

/// RoutingSession resolves "Calendario" and "Calendar" to Calendar's bundle id, as the broker's resolver does on an
/// Italian Mac, and opens whatever it is asked, keeping both in order.
@MainActor
private final class RoutingSession: AutomationSessionOperating {
    var id: UUID?
    var held: String?
    var resolved: [String] = []
    var opened: [String] = []

    var memoryApplication: String? { held }

    func resolvedBundleID(of application: String) async -> String? {
        resolved.append(application)
        return ["Calendario", "Calendar"].contains(application) ? "com.apple.iCal" : nil
    }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        opened.append(application)
        id = UUID()
        return SceneSnapshot(bundleID: "com.apple.iCal", appName: "Calendario", windowTitle: "Calendario",
                             viewportPixelSize: ViewportPixelSize(width: 400, height: 200), elements: [])
    }

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
