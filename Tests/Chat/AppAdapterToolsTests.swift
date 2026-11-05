import AppAdapters
@testable import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Synchronization
import Testing

@Suite("The app adapters through the tools")
@MainActor
struct AppAdapterToolsTests {

    @Test
    func keepsCuratedAdapterAnswers() async throws {
        do {
            try await contentParametersWithheld()
            try await contentResultsWithheldFromTheTranscriptOnly()
            try await capabilitiesAsText()
        }
    }

    @Test func discoveredAdapterUsesItsRealName() async throws {
        do {
            let tools = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([ScribeAdapter()]))
            var lines: [String] = []
            tools.record = { lines.append($0) }
            let answer = try await tools.call("call", .object([
                "name": .string("scribe.read"), "arguments": .object(["path": .string("notes.txt")])]))
            #expect(answer.answerText.contains("Read it."))
            #expect(lines.first?.hasPrefix("→ scribe.read") == true)
            #expect(lines.last?.hasPrefix("← scribe.read") == true)
            #expect(!lines.contains { $0.hasPrefix("→ call") || $0.hasPrefix("→ app_call") })
        }
    }

    private static let adapterTools: Set<String> = ["scribe.read", "scribe.write"]
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
        #expect(Self.names(with.toolDefinitions) == Self.names(without.toolDefinitions))
        #expect(Set(with.dispatcher.entries.map { $0.contract.id.rawValue }).isSuperset(of: Self.adapterTools))
        #expect(Set(without.dispatcher.entries.map { $0.contract.id.rawValue }).isDisjoint(with: Self.adapterTools))
        #expect(without.instructions == AutomationTools.instructions)
        #expect(!AutomationTools.instructions.contains("app_capabilities"))
        #expect(with.instructions.contains("prefer that verb over driving the app's interface"))
        #expect(with.instructions.contains("never through Finder, TextEdit"))
        #expect(with.instructions.contains("use find") && with.instructions.contains("through call"))
        #expect(!with.instructions.contains("app_capabilities") && !with.instructions.contains("use app_call"))
    }

    @Test("scripted adapters remain discoverable behind the canonical delegation surface")
    func adapterSessionGuidance() throws {
        let tools = AutomationTools(session: HoldingSession(HoldLog()),
            adapters: AppAdapters([ScriptedAdapter(HoldLog())]))
        #expect(tools.capabilityDefinitions.contains { $0["name"].string == "scripted.write" })
        #expect(!tools.toolDefinitions.contains { ["app_capabilities", "app_call"].contains($0["name"].string ?? "") })
        #expect(tools.instructions.contains("use find") && tools.instructions.contains("through call"))
    }

    @Test("without adapters an app_call is refused and reaches nothing")
    func refusedWithoutAdapters() async {
        let tools = AutomationTools(session: AdapterOnlySession())
        await #expect(throws: AutomationFailure.self) {
            try await tools.capabilityCall("scribe.write", .object([
                "path": .string("notes.txt"), "text": .string("draft")]))
        }
    }

    @Test("a discovered adapter verb needs no session and withholds content only from its records")
    func contentParametersWithheld() async throws {
        let scribe = ScribeAdapter()
        let tools = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([scribe]))
        var records: [String] = []
        tools.record = { records.append($0) }
        let answer = try await tools.capabilityCall("scribe.write", .object([
            "path": .string("notes.txt"), "text": .string("Zoë's private draft")]))
        #expect(answer.answerText == "ok Wrote notes.txt.")
        #expect(await scribe.written == ["Zoë's private draft"])
        #expect(records.count == 2)
        #expect(records.allSatisfy { !$0.contains("private draft") }, "\(records)")
        #expect(records[0].hasPrefix("→ scribe.write") && records[0].contains("notes.txt") && records[0].contains(Self.marker))
    }

    @Test("a verb's content result reaches the model whole, as text, and its transcript line as the marker in JSON")
    func contentResultsWithheldFromTheTranscriptOnly() async throws {
        let tools = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([ScribeAdapter()]))
        var records: [String] = []
        tools.record = { records.append($0) }
        let answer = try await tools.capabilityCall("scribe.read", .object(["path": .string("notes.txt")]))
        #expect(answer.answerText == "ok Read it.\nsize: 19\ntext: the file's own words")
        let line = try #require(records.last)
        #expect(line.hasPrefix("← scribe.read") && !line.contains("the file's own words"))
        #expect(line.contains(Self.marker) && line.contains("\"size\""))
    }

    @Test("find delivers adapter schemas without executing any adapter")
    func capabilitiesAsText() async throws {
        let scribe = ScribeAdapter()
        let tools = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([scribe]))
        var records: [String] = []
        tools.record = { records.append($0) }
        let answer = try await tools.call("find", .object(["query": .string("scribe read write")]))
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(answer.answerText.utf8))
        let capabilities = try #require(payload["capabilities"].array)
        let names = Set(capabilities.compactMap { $0["name"].string })
        #expect(names.isSuperset(of: Self.adapterTools))
        let write = try #require(capabilities.first { $0["name"].string == "scribe.write" })
        #expect(write["inputSchema"]["properties"]["path"]["type"].string == "string")
        #expect(write["inputSchema"]["properties"]["text"]["type"].string == "string")
        #expect(write["strict"] == .bool(true))
        #expect(await scribe.invocationCount == 0)
        #expect(records.first?.hasPrefix("→ find") == true && records.last?.hasPrefix("← find") == true)
    }

    @Test("an unlisted adapter name is refused without exposing its unclassified arguments")
    func unresolvedVerbWithholdsEveryText() async throws {
        let scribe = ScribeAdapter()
        let tools = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([scribe]))
        var records: [String] = []
        tools.record = { records.append($0) }
        let router = MCPRouter(tools: tools.toolDefinitions, instructions: nil, call: tools.call)
        let answer = try #require(await router.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
            "params": .object(["name": .string("call"), "arguments": .object([
                "name": .string("scribe.erase"), "arguments": .object([
                    "text": .string("never shown"), "nested": .array([.string("nor this")]), "count": .number(2)])])])])))
        #expect(answer["result"]["isError"] == .bool(true))
        let encoded = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        #expect(!encoded.contains("never shown") && !encoded.contains("nor this"))
        #expect(records.isEmpty, "The unknown name is refused before recording unclassified arguments")
        #expect(await scribe.invocationCount == 0)
    }

    @Test("an app_call runs off the main actor, after its call line and before its answer line")
    func runsOffTheMainActor() async throws {
        let adapter    = BlockingAdapter()
        let tools      = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([adapter]))
        let transcript = Transcript()
        tools.record   = { transcript.lines.append($0) }
        // Released from the main actor while the verb holds its thread: only a verb run elsewhere lets that happen.
        let probe = Task { @MainActor in
            while !adapter.hasStarted { try? await Task.sleep(for: .milliseconds(1)) }
            let during = transcript.lines
            adapter.release()
            return during
        }
        let answer = try await tools.capabilityCall("blocking.wait", .object([:]))
        let during = await probe.value
        #expect(answer.answerText == "ok Waited.\nreleased: true", "the main actor waited for the verb")
        #expect(during.count == 1 && during.first?.hasPrefix("→ blocking.wait") == true, "\(during)")
        #expect(transcript.lines.count == 2 && transcript.lines.last?.hasPrefix("← blocking.wait") == true)
    }

    // MARK: Holding the application on the seat

    private static func write(_ app: String) -> JSONValue {
        .object(["app": .string(app), "verb": .string("write"),
                 "arguments": .object(["path": .string("notes.txt"), "text": .string("draft")])])
    }

    @Test("an adapter that scripts its app holds it on the seat before it runs, as an activity of the session")
    func scriptedAdapterHoldsItsApp() async throws {
        let log     = HoldLog()
        let session = HoldingSession(log)
        let tools   = AutomationTools(session: session, adapters: AppAdapters([ScriptedAdapter(log)]))
        let first   = try await tools.capabilityCall("scripted.write", .object(["path": .string("notes.txt"), "text": .string("draft")]))
        #expect(log.events == ["begin", "seat test.scripted", "run write", "end"])
        let id = try #require(session.id).uuidString
        #expect(first.answerText == "ok Wrote.\nsession: \(id)")
        #expect(first["structuredContent"]["session"] == .string(id))
        let again = try await tools.capabilityCall("scripted.write", .object(["path": .string("notes.txt"), "text": .string("draft")]))
        #expect(log.events.suffix(3) == ["begin", "run write", "end"], "a held app is not opened again")
        #expect(again["structuredContent"]["session"] == .null && session.id?.uuidString == id)
    }

    @Test("an adapter that scripts its app closes the other app the session holds before holding its own")
    func differentHeldAppClosedFirst() async throws {
        let log     = HoldLog()
        let session = HoldingSession(log)
        session.held = "com.apple.iCal"
        session.id   = UUID()
        let tools = AutomationTools(session: session, adapters: AppAdapters([ScriptedAdapter(log)]))
        _ = try await tools.capabilityCall("scripted.write", .object(["path": .string("notes.txt"), "text": .string("draft")]))
        #expect(log.events == ["begin", "close", "seat test.scripted", "run write", "end"])
        #expect(session.held == "test.scripted")
    }

    @Test("a hold that fails answers the reason and runs nothing")
    func failedHoldRunsNothing() async throws {
        let log     = HoldLog()
        let session = HoldingSession(log)
        session.refusal = "Another worker holds Scripted."
        let tools  = AutomationTools(session: session, adapters: AppAdapters([ScriptedAdapter(log)]))
        let answer = try await tools.capabilityCall("scripted.write", .object(["path": .string("notes.txt"), "text": .string("draft")])).answerText
        #expect(answer.hasPrefix("refused Braus could not hold test.scripted on the seat, so nothing was done"))
        #expect(answer.contains("Another worker holds Scripted."))
        #expect(log.events == ["begin", "seat test.scripted", "end"])
    }

    @Test("without a Seat an adapter that scripts its app runs unheld, as before, and the hook runs with noSeat")
    func noSeatRunsUnheld() async throws {
        let log     = HoldLog()
        let session = HoldingSession(log)
        session.hasSeat = false
        let tools  = AutomationTools(session: session, adapters: AppAdapters([ScriptedAdapter(log)]))
        let answer = try await tools.capabilityCall("scripted.write", .object(["path": .string("notes.txt"), "text": .string("draft")]))
        #expect(answer.answerText == "ok Wrote.")
        #expect(log.events == ["begin", "run write", "end"], "nothing opened")
        let bare = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([ScriptedAdapter(log)]))
        #expect(try await bare.capabilityCall("scripted.write", .object(["path": .string("notes.txt"), "text": .string("draft")])).answerText == "ok Wrote.")
        session.id = UUID()
        let observed = JSONValue.string(try #require(session.id).uuidString)
        _ = try await tools.call("observe", .object([:]))
        let hold = try await tools.holding("test.daw") { hold in
            log.add("unheld")
            return hold
        }
        #expect(hold == .noSeat)
        #expect(log.events.suffix(3) == ["begin", "unheld", "end"], "nothing opened or closed")
        #expect(try await tools.call("observe", .object([:])).payload["changes"] == .null,
                "a command that may change the app makes the scene stale without a Seat too")
    }

    @Test("an open that does not land the app on the Seat refuses the call, and runs nothing")
    func openOffTheSeatRefuses() async throws {
        let log     = HoldLog()
        let session = HoldingSession(log)
        session.landsOnSeat = false
        let tools  = AutomationTools(session: session, adapters: AppAdapters([ScriptedAdapter(log)]))
        let answer = try await tools.capabilityCall("scripted.write", .object(["path": .string("notes.txt"), "text": .string("draft")])).answerText
        #expect(answer.hasPrefix("refused Braus opened test.scripted but the seat does not hold it"), "\(answer)")
        #expect(log.events == ["begin", "seat test.scripted", "end"])
    }

    @Test("an adapter on the app the session holds runs; one that scripts no app seats nothing")
    func storeAdapterSeatsNothing() async throws {
        let log     = HoldLog()
        let scribe  = ScribeAdapter()
        let session = HoldingSession(log)
        session.held = "test.scribe"
        session.id   = UUID()
        let tools = AutomationTools(session: session, adapters: AppAdapters([scribe]))
        #expect(try await tools.capabilityCall("scribe.write", .object(["path": .string("notes.txt"), "text": .string("draft")])).answerText == "ok Wrote notes.txt.")
        #expect(await scribe.written == ["draft"])
        #expect(log.events == ["begin", "end"], "nothing opened or closed")
    }

    @Test("after a verb that may change the app, the next scene is answered whole; after a read, as changes")
    func writingVerbMakesTheSceneStale() async throws {
        let session = HoldingSession(HoldLog())
        session.held = "test.scribe"
        session.id   = UUID()
        let tools = AutomationTools(session: session, adapters: AppAdapters([ScribeAdapter()]))
        let id    = JSONValue.string(try #require(session.id).uuidString)
        _ = try await tools.call("observe", .object([:]))
        _ = try await tools.capabilityCall("scribe.read", .object(["path": .string("notes.txt")]))
        let afterRead = try await tools.call("observe", .object([:])).payload
        #expect(afterRead["changes"] == .string("r2 unchanged since r1"))
        _ = try await tools.capabilityCall("scribe.write", .object(["path": .string("notes.txt"), "text": .string("draft")]))
        let afterWrite = try await tools.call("observe", .object([:])).payload
        #expect(afterWrite["changes"] == .null && afterWrite["scene"].string != nil)
        let next = try await tools.call("observe", .object([:])).payload
        #expect(next["changes"] == .string("r4 unchanged since r3"), "a scene answered whole is the new baseline")
    }

    @Test("another tool family holds an app through the hook, as an activity, and learns when it cannot")
    func hookHoldsAndReports() async throws {
        let log     = HoldLog()
        let session = HoldingSession(log)
        let tools   = AutomationTools(session: session)
        let value   = try await tools.holding("test.daw") { hold -> Int in
            log.add("body")
            return hold == .held ? 7 : 0
        }
        #expect(value == 7)
        #expect(log.events == ["begin", "seat test.daw", "body", "end"])
        let id = JSONValue.string(try #require(session.id).uuidString)
        _ = try await tools.call("observe", .object([:]))
        _ = try await tools.holding("test.daw", mayChange: false) { _ in log.add("read") }
        #expect(try await tools.call("observe", .object([:])).payload["changes"] != .null)
        _ = try await tools.holding("test.daw") { _ in log.add("write") }
        #expect(try await tools.call("observe", .object([:])).payload["changes"] == .null)

        session.refusal = "No seat here."
        let refused = await #expect(throws: AutomationTools.HoldRefused.self) {
            try await tools.holding("test.other") { _ in log.add("never") }
        }
        #expect(refused?.reason.contains("No seat here.") == true)
        #expect(!log.events.contains("never") && log.events.suffix(4) == ["begin", "close", "seat test.other", "end"])
    }

    @Test("an app_call on an app another session holds on the seat is refused, and reaches nothing")
    func refusedOnAnAppHeldElsewhere() async throws {
        let ledger = LedgerAdapter()
        let tools = AutomationTools(session: RoutingSession(), adapters: AppAdapters([ledger]))
        let other = UUID()
        SeatHolds.set("TEST.LEDGER", for: other)
        defer { SeatHolds.set(nil, for: other) }
        let refused = try await tools.capabilityCall("ledger.touch", .object([:])).answerText
        #expect(refused.hasPrefix("refused Another session is driving Ledger"), "\(refused)")
        #expect(ledger.touches == 0)
        SeatHolds.set(nil, for: other)
        #expect(try await tools.capabilityCall("ledger.touch", .object([:])).answerText.hasPrefix("ok "))
        #expect(ledger.touches == 1)
    }

    // MARK: open_session and the task router

    /// The retired selector must be absent from every composed opening schema.
    private static func namedProperty(of tools: AutomationTools) -> JSONValue {
        tools.toolDefinitions.first { $0["name"].string == "open_session" }?["inputSchema"]["properties"]["named"] ?? .null
    }

    private static func open(_ tools: AutomationTools, _ app: String, named: Bool? = nil) async throws -> JSONValue {
        var arguments: [String: JSONValue] = ["app": .string(app)]
        if let named { arguments["named"] = .bool(named) }
        return try await tools.call("open_session", .object(arguments)).payload
    }

    @Test("open_session opens the requested app even when its adapter is ready")
    func explicitOpeningDoesNotSubstituteTheAdapter() async throws {
        let session = RoutingSession()
        let tools   = AutomationTools(session: session, adapters: AppAdapters([CalendarStub(.ready)]))
        let answer  = try await Self.open(tools, "Calendario")
        #expect(answer["session"].string == session.id?.uuidString)
        #expect(answer["route"] == .null && answer["routeNote"] == .null)
        #expect(session.resolved == ["Calendario"] && session.opened == ["Calendario"])
        #expect(Self.namedProperty(of: tools) == .null)
    }

    @Test("open_session rejects the retired named selector without effects, then opens as asked")
    func retiredNamedIsRejectedBeforeOpening() async throws {
        let session = RoutingSession()
        let tools   = AutomationTools(session: session, adapters: AppAdapters([CalendarStub(.ready)]))
        for named in [false, true] {
            await #expect(throws: AutomationFailure.self) {
                try await Self.open(tools, "Calendario", named: named)
            }
        }
        #expect(session.opened.isEmpty && session.resolved.isEmpty)
        _ = try await Self.open(tools, "Calendario")
        #expect(session.opened == ["Calendario"] && session.resolved == ["Calendario"])
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
        await #expect(throws: AutomationFailure.self) {
            _ = try await tools.call("open_session", .object([
                "app": .string("Calendario"), "named": .bool(false)]))
        }
        #expect(session.opened == ["Calendario"])
        #expect(Self.namedProperty(of: tools) == .null)
    }

    @Test("with the web composed, explicit app opening never substitutes the website or accepts named")
    func explicitOpeningDoesNotSubstituteTheWeb() async throws {
        let session = RoutingSession()
        let tools   = AutomationTools(session: session, offersWeb: true)
        let answer  = try await Self.open(tools, "Mappe")
        #expect(answer["session"].string == session.id?.uuidString)
        #expect(answer["route"] == .null && answer["routeNote"] == .null)
        #expect(session.opened == ["Mappe"])
        #expect(Self.namedProperty(of: tools) == .null)
        for named in [false, true] {
            await #expect(throws: AutomationFailure.self) {
                try await Self.open(tools, "Mappe", named: named)
            }
        }
        #expect(session.opened == ["Mappe"])
        _ = try await Self.open(AutomationTools(session: session), "Mappe")
        #expect(session.opened == ["Mappe", "Mappe"])
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
        return ["Calendario": "com.apple.iCal", "Calendar": "com.apple.iCal", "Mappe": "com.apple.Maps"][application]
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
    private(set) var invocationCount = 0

    func availability() async -> AdapterAvailability { .ready }

    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        invocationCount += 1
        if verb == "write" {
            written.append(arguments["text"].string ?? "")
            return .confirmed("Wrote \(arguments["path"].string ?? "").")
        }
        return .confirmed("Read it.", .object(["text": .string("the file's own words"), "size": .number(19)]))
    }
}

extension JSONValue {

    /// A tool result's one text item as the model reads it, empty when it has none.
    fileprivate var answerText: String { self["content"].array?.first?["text"].string ?? "" }
}

/// Transcript keeps the lines the tools record, on the main actor where they are written.
@MainActor
private final class Transcript {
    var lines: [String] = []
}

/// LedgerAdapter counts its one verb's calls; its bundle id is its own, so no other test's hold refuses it.
private final class LedgerAdapter: AppAdapting {
    let name                 = "ledger"
    let appNames             = ["Ledger"]
    let bundleIDs: Set<String> = ["test.ledger"]
    let verbs = [AdapterVerb("touch", "Counts a call.", safety: .read, readBack: "none, a fake")]

    private let count = Mutex(0)

    var touches: Int { count.withLock { $0 } }

    func availability() async -> AdapterAvailability { .ready }

    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        count.withLock { $0 += 1 }
        return .confirmed("Touched.")
    }
}

/// BlockingAdapter's one verb holds its thread, as a script does, until `release` or two seconds pass, and answers
/// whether it was released: a task on the main actor can release it only while the verb runs elsewhere.
private final class BlockingAdapter: AppAdapting {
    let name                 = "blocking"
    let appNames             = ["Blocking"]
    let bundleIDs: Set<String> = ["test.blocking"]
    let verbs = [AdapterVerb("wait", "Holds its thread.", safety: .read, readBack: "none, a fake")]

    private let started = Mutex(false)
    private let gate    = DispatchSemaphore(value: 0)

    var hasStarted: Bool { started.withLock { $0 } }

    func release() { gate.signal() }

    func availability() async -> AdapterAvailability { .ready }

    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        started.withLock { $0 = true }
        return .confirmed("Waited.", .object(["released": .bool(waitForRelease())]))
    }

    private func waitForRelease() -> Bool {
        gate.wait(timeout: .now() + 2) == .success
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

@MainActor
private extension AutomationTools {
    func capabilityCall(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        try await call("call", .object(["name": .string(name), "arguments": arguments]))
    }
}


extension AppAdapterToolsTests {
    @Test func removedGenericAdapterNamesCannotReachAComposedAdapter() async throws {
        let scribe = ScribeAdapter()
        let tools = AutomationTools(session: AdapterOnlySession(), adapters: AppAdapters([scribe]))
        for name in ["app_call", "app_capabilities"] {
            do {
                _ = try await tools.capabilityCall(name, .object([
                    "app": .string("scribe"), "verb": .string("write"),
                    "arguments": .object(["path": .string("notes.txt"), "text": .string("never written")])]))
                Issue.record("A removed generic adapter name was accepted")
            } catch let failure as AutomationFailure {
                #expect(failure.cause == "unknown_tool")
            }
        }
        #expect(await scribe.invocationCount == 0)
        #expect(await scribe.written.isEmpty)
    }
}

/// HoldLog keeps the order of what a session and an adapter did, from any thread.
nonisolated private final class HoldLog: Sendable {
    private let lines = Mutex<[String]>([])

    var events: [String] { lines.withLock { $0 } }

    func add(_ event: String) { lines.withLock { $0.append(event) } }
}

/// HoldingSession opens whatever it is asked, unless it has a refusal, and logs its opens, closes and activity, so
/// the order of a hold and the adapter's run can be read.
@MainActor
private final class HoldingSession: AutomationSessionOperating {
    var id: UUID?
    var held: String?
    var refusal: String?
    private let log: HoldLog
    /// Twenty rows, so a scene with no change answers as changes, which are shorter than half of it.
    private let scene = SceneSnapshot(
        bundleID         : "test.scribe",
        appName          : "Scribe",
        windowTitle      : "Notes",
        viewportPixelSize: ViewportPixelSize(width: 400, height: 200),
        elements         : (0..<20).map { index in
            SceneElement(id: "row\(index)", kind: .control, label: "Note \(index)",
                         bounds: NormalizedRect(x: 0.1, y: 0.04 * Double(index), width: 0.2, height: 0.03))
        }
    )

    init(_ log: HoldLog) { self.log = log }

    var hasSeat = true
    /// Whether an open lands on the Seat; false stands for a route that opened it elsewhere.
    var landsOnSeat = true
    var memoryApplication: String? { held }
    var holdsOnSeat: Bool { held != nil && landsOnSeat }

    func openOnSeat(application: String) async throws -> SceneSnapshot {
        log.add("seat \(application)")
        return try await opened(application)
    }

    func beginActivity() -> UUID {
        log.add("begin")
        return UUID()
    }

    func endActivity(_ token: UUID) { log.add("end") }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        log.add("open \(application)")
        return try await opened(application)
    }

    private func opened(_ application: String) async throws -> SceneSnapshot {
        if let refusal { throw AutomationFailure(refusal) }
        held = application
        id   = UUID()
        return scene
    }

    func observe() async throws -> SceneSnapshot { scene }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("unused") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }

    func close() async {
        log.add("close")
        held = nil
        id   = nil
    }
}

/// ScriptedAdapter scripts its own app, as Mail's adapter does on the Mac, and logs each run of its one verb.
private final class ScriptedAdapter: AppAdapting {
    let name                 = "scripted"
    let appNames             = ["Scripted"]
    let bundleIDs: Set<String> = ["test.scripted"]
    let scriptedApplication: String? = "test.scripted"
    let verbs = [AdapterVerb("write", "Writes.",
                             parameters: [AdapterParameter("path", .string, "path"),
                                          AdapterParameter("text", .string, "text", content: true)],
                             safety: .write, readBack: "none, a fake")]
    private let log: HoldLog

    init(_ log: HoldLog) { self.log = log }

    func availability() async -> AdapterAvailability { .ready }

    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        log.add("run \(verb)")
        return .confirmed("Wrote.")
    }
}
