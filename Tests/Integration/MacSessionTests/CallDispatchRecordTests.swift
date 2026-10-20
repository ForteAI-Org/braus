import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import MacDriver
@testable import MacSession
import Memory
import PerceptionCore
import Router
@testable import SQLiteMemory
import TaskRouting
import Testing

/// M05 on the record: each call keeps the path it was dispatched on, as the tools made it and the archive reads it
/// back. A session no routing session fronts records its own route where the call reaches it; a routing session's
/// route and hand-back reason are kept as it reported them; an adapter verb is recorded right before the adapter runs,
/// failures included, and never for a call refused before it; a call that reached no session or adapter records none.
///
/// Offline: `AutomationTools` over the MacDriver on fakes, whose knowledge folder is the call's memory, and adapters in
/// place of the Mac's. No app, Seat, account or network.
@MainActor
@Suite("M05: the path each call took, on the record", .serialized)
struct CallDispatchRecordTests {

    /// An adapter whose `ok` verb answers, whose `boom` verb throws once invoked, and whose irreversible `purge` verb
    /// its policy refuses before it runs; every invocation counted.
    final class ScriptedAdapter: AppAdapting, @unchecked Sendable {
        let name = "scripted"
        let appNames = ["Scripted"]
        let bundleIDs: Set<String> = ["test.scripted"]
        let verbs = [
            AdapterVerb("ok", "Answers.", safety: .read, readBack: "nothing"),
            AdapterVerb("boom", "Throws once invoked.", safety: .read, readBack: "nothing"),
            AdapterVerb("purge", "Purges everything.", safety: .irreversible, readBack: "the store emptied",
                        confirms: .readBack),
        ]
        private(set) var invoked: [String] = []

        func availability() async -> AdapterAvailability { .ready }
        func requestPermission() async -> AdapterAvailability { .ready }
        func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
            invoked.append(verb)
            if verb == "boom" { throw AdapterFailure("the adapter failed after it was invoked") }
            return AdapterOutcome(.foundActed, "done")
        }
    }

    /// An adapter of the catalogue's Calendar line that cannot run now: the router opens the app with the reason.
    struct NotReadyAdapter: AppAdapting {
        let reason: String
        var name: String { "calendar" }
        var appNames: [String] { ["Calendar"] }
        var bundleIDs: Set<String> { ["com.apple.iCal"] }
        var verbs: [AdapterVerb] { [] }
        func availability() async -> AdapterAvailability { .needsPermission(reason) }
        func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
            AdapterOutcome(.refused, "no verbs")
        }
    }

    /// A session that is the route `dispatchRoute` says, with a memory, counting the opens that reach it; `failsOpen`,
    /// when set, is thrown by the next open after it was counted, as an application that shows no window.
    final class RouteFake: AutomationSessionOperating {
        let dispatchRoute: CallRoute.Route?
        let memoryDirectory: URL?
        private(set) var id: UUID?
        private(set) var opened: [String] = []
        var failsOpen: (any Error)?

        init(_ route: CallRoute.Route, memory: URL) {
            dispatchRoute   = route
            memoryDirectory = memory
        }

        func resolvedBundleID(of application: String) async -> String? {
            ["Calendar": "com.apple.iCal", "Calendario": "com.apple.iCal", "Maps": "com.apple.Maps",
             "Mail": "com.apple.mail", "Messages": "com.apple.MobileSMS", "Finder": "com.apple.finder", "Notes": "com.apple.Notes"][application]
        }

        func open(application: String, window: String?) async throws -> SceneSnapshot {
            opened.append(application)
            if let failure = failsOpen { throw failure }
            id = UUID()
            return SessionStub.scene
        }
        func observe() async throws -> SceneSnapshot { SessionStub.scene }
        func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws
            -> ActOutcome { ActOutcome(.refused, "fake") }
        func select(control: String, item: String) async throws -> ActOutcome { ActOutcome(.refused, "fake") }
        func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
            ActOutcome(.refused, "fake")
        }
        func close() async { id = nil }
    }

    /// What the archive holds of each call of `trace`, in order: its tool, its status, its route, its adapter verb,
    /// attribution and its event id.
    struct Recorded: Equatable {
        let tool    : String
        let status  : AgentCallStatus?
        let route   : CallRoute?
        let dispatch: AdapterDispatch?
        var advice     : CallRouteAdvice? = nil
        var rung       : CallRung? = nil
        var performed  : OperationCheck.Performed? = nil
        var samples    : Int = 0
        var attribution: TaskCallAttribution? = nil
        var eventID    : String = ""
    }

    static func recorded(_ trace: String, in knowledge: URL) async throws -> [Recorded] {
        let memory = MemoryService.shared(for: knowledge)
        _ = await memory.flush(within: .seconds(5))
        var found: [Recorded] = []
        for call in try await memory.calls(inTrace: trace) {
            let id = call.event.eventID
            let route = try await memory.perform { try await $0.facts.route(of: id) }
            let dispatch = try await memory.perform { try await $0.facts.adapterDispatch(of: id) }
            let advice = try await memory.perform { try await $0.facts.advice(of: id) }
            let rung = try await memory.perform { try await $0.facts.rung(of: id) }
            let performed = try await memory.perform { try await $0.facts.effect(of: id) }?.performed
            let attribution = try await memory.perform { try await $0.facts.attribution(of: id) }
            found.append(Recorded(tool: call.request.tool.rawValue, status: call.progress.status, route: route,
                                  dispatch: dispatch, advice: advice, rung: rung, performed: performed,
                                  samples: try Self.samples(of: id, in: knowledge), attribution: attribution, eventID: id))
        }
        return found
    }

    /// How many samples the archive holds for the call, read from the file beside the open store.
    static func samples(of eventID: String, in knowledge: URL) throws -> Int {
        let archive = try SQLiteConnection(path: knowledge.appendingPathComponent("memory.sqlite").path, readOnly: true)
        defer { archive.close() }
        return Int(try archive.query("SELECT count(*) FROM memory_event_observations WHERE event_id = ?", [.text(eventID)]) {
            $0.integer(0) ?? 0
        }.first ?? 0)
    }

    /// The answer's JSON, decoded from the tool result's text.
    static func answered(_ result: JSONValue) -> JSONValue {
        if result["structuredContent"] != .null { return result["structuredContent"] }
        let text = result["content"].array?.first?["text"].string ?? ""
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    static func text(_ result: JSONValue) -> String { result["content"].array?.first?["text"].string ?? "" }

    final class Transcript: @unchecked Sendable { var lines: [String] = [] }

    static func knowledge() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("braus-m05-\(UUID().uuidString)")
    }

    static func native(_ tree: MacTreeNode, knowledge: URL) -> MacAutomationSession {
        let reader = TreeStub(tree)
        let roles = MacRoles(reader: reader, actor: reader, delivery: NoDelivery(), person: nil,
                             notifications: QuietNotifications(), controls: NoControls(),
                             serverWindows: { _ in [(number: 7, frame: MacSessionTests.frame)] })
        return MacAutomationSession(knowledgeDirectory: knowledge, roles: roles, workspace: WorkspaceStub(),
                                    leases: MacAppLeases())
    }

    static func sessionID(_ answer: JSONValue) -> String? {
        guard let text = answer["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        return value["session"].string
    }

    @Test("a session no routing session fronts records its own route where a call reaches it; a call refused before it, or that reaches no session, records none")
    func standaloneRoutes() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let tools = AutomationTools(session: RouteFake(.native, memory: knowledge))
        tools.producer = CallProducer(source: .app, streamID: "m05", traceID: "standalone")
        let id = try #require(Self.sessionID(try await tools.call("open_session", .object(["app": .string("Notes")]))))
        _ = try? await tools.call("act", .object(["session": .string(id), "target": .string("B3")]))
        _ = try await tools.call("status", .object([:]))
        await #expect(throws: (any Error).self) {
            _ = try await tools.call("act", .object(["session": .string("stale"), "target": .string("B3")]))
        }
        let calls = try await Self.recorded("standalone", in: knowledge)
        #expect(calls.map(\.tool) == ["open_session", "act", "status", "act"], "\(calls)")
        #expect(calls.map(\.route) == [CallRoute(.native), CallRoute(.native), nil, nil], "\(calls)")
        #expect(calls.allSatisfy { $0.dispatch == nil })
        await MemoryService.closeAll()
    }

    @Test("the seat's and the browser engine's sessions, with no routing session in front, record theirs where the call reaches them", arguments: [CallRoute.Route.desktop, .web])
    func standaloneSeatAndWeb(_ route: CallRoute.Route) async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let fake = RouteFake(route, memory: knowledge)
        let tools = AutomationTools(session: fake)
        tools.producer = CallProducer(source: .app, streamID: "m05", traceID: "fake-\(route.rawValue)")
        _ = try await tools.call("open_session", .object(["app": .string(route == .web ? "web:example.com" : "Notes")]))
        let calls = try await Self.recorded("fake-\(route.rawValue)", in: knowledge)
        #expect(calls.count == 1 && calls.first?.route == CallRoute(route), "\(calls)")
        await MemoryService.closeAll()
    }

    @Test("an open_session the router answers with another route or a question reaches no session and records no dispatch")
    func redirectAndAskDispatchNothing() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let fake = RouteFake(.desktop, memory: knowledge)
        let tools = AutomationTools(session: fake, channels: [.web])
        tools.producer = CallProducer(source: .app, streamID: "m05", traceID: "redirect")
        tools.router = TaskRouter(catalogue: RouteCatalogue(RouteCatalogue.standard.entries.map { entry in
            entry.kind == .mail ? RouteEntry(.mail, .webMail, replaces: entry.replaces, needsLogin: true) : entry
        }))
        let maps = try await tools.call("open_session", .object(["app": .string("Maps")]))
        let mail = try await tools.call("open_session", .object(["app": .string("Mail")]))
        func text(_ answer: JSONValue) -> String { answer["content"].array?.first?["text"].string ?? "" }
        #expect(text(maps).contains("\"route\"") && text(mail).contains("\"ask\""), "\(text(maps)) \(text(mail))")
        #expect(fake.opened.isEmpty, "no session was opened")
        let calls = try await Self.recorded("redirect", in: knowledge)
        #expect(calls.count == 2 && calls.allSatisfy { $0.status == .completed }, "\(calls)")
        #expect(calls.allSatisfy { $0.route == nil && $0.dispatch == nil }, "\(calls)")
        await MemoryService.closeAll()
    }


    @Test("a routing session's route and the MacDriver's hand-back reason are kept as it reported them")
    func routedHandBackKept() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        // The MacDriver gives the app back with its reason; the desktop behind the router keeps the memory. The tools
        // note no route of their own: the router's, with the reason, is the one kept.
        let native = SessionStub(handoff: .dialogInFront(bundleID: "com.example"))
        let routing = RoutingAutomationSession(native: native, desktop: RouteFake(.desktop, memory: knowledge))
        let tools = AutomationTools(session: routing)
        tools.producer = CallProducer(source: .app, streamID: "m05", traceID: "routed")
        _ = try await tools.call("open_session", .object(["app": .string("Notes")]))
        let calls = try await Self.recorded("routed", in: knowledge)
        #expect(calls.count == 1 && calls.first?.route?.route == .desktop, "\(calls)")
        #expect(calls.first?.route?.handoffReason != nil, "the MacDriver's reason, as the routing session reported it")
        await MemoryService.closeAll()
    }

    @Test("an adapter verb is recorded right before the adapter runs, as resolved: kept when the adapter throws after, never for a call refused before it")
    func adapterDispatches() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let adapter = ScriptedAdapter()
        let tools = AutomationTools(session: Self.native(MacSessionTests.rich, knowledge: knowledge))
        tools.adapters = AppAdapters([adapter])
        tools.producer = CallProducer(source: .app, streamID: "m05", traceID: "adapters")
        func call(_ verb: String) async { _ = try? await tools.call("app_call", .object(["app": .string("Scripted"),
                                                                                         "verb": .string(verb)])) }
        await call("scripted.ok")
        await call("boom")
        await call("purge")
        await call("missing")
        #expect(adapter.invoked == ["ok", "boom"], "the policy refused purge before it ran: \(adapter.invoked)")
        let calls = try await Self.recorded("adapters", in: knowledge)
        #expect(calls.map(\.tool) == ["app_call", "app_call", "app_call", "app_call"], "\(calls)")
        #expect(calls.map(\.dispatch) == [AdapterDispatch(adapter: "scripted", verb: "ok"),
                                          AdapterDispatch(adapter: "scripted", verb: "boom"), nil, nil], "\(calls)")
        #expect(calls[1].status == .failed, "the invocation is kept on the failed call: \(calls[1])")
        #expect(calls.allSatisfy { $0.route == nil }, "an adapter is not a session route")
        await MemoryService.closeAll()
    }

    // MARK: M05: a redirect's advice on the record

    @Test("M05 RA-1: an open_session the router answers with another route or a question records the decision, its route and its words with the end, under the task's real attribution while it is open and under none after it ended, each call its own row; nothing else: no route, adapter, sample, effect or rung, nothing opened; a declared secret in the route's address and the words is withheld from the archive open and closed, the transcript and the answer")
    func redirectAdviceRecorded() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let fake  = RouteFake(.desktop, memory: knowledge)
        let tools = AutomationTools(session: fake, channels: [.web])
        tools.producer = CallProducer(source: .app, streamID: "m05", traceID: "advice")
        tools.router = TaskRouter(catalogue: RouteCatalogue(RouteCatalogue.standard.entries.map { entry in
            entry.kind == .mail ? RouteEntry(.mail, .webMail, replaces: entry.replaces, needsLogin: true) : entry
        }))
        let transcript = Transcript()
        tools.record = { transcript.lines.append($0) }
        // A task that declares the route's host a secret; its attribution as the tools hold it.
        let secret = "google.com/maps"
        _ = try await tools.call("memory_task", .object([
            "operation": .string("begin"), "goal": .string("Find the place"), "remaining": .string("Find the place"),
            "inputs": .array([.object(["name": .string("place"), "value": .string(secret), "secret": .bool(true)])]),
        ]))
        let attribution = try #require(tools.openTask?.attribution, "the task is open")
        let maps = try await tools.call("open_session", .object(["app": .string("Maps")]))
        let mail = try await tools.call("open_session", .object(["app": .string("Mail")]))
        _ = try await tools.call("memory_task", .object(["operation": .string("end"), "outcome": .string("completed")]))
        #expect(tools.openTask == nil, "the task ended")
        // After the end, the same decisions again on the same tools: their own rows, under no task.
        let mapsAfter = try await tools.call("open_session", .object(["app": .string("Maps")]))
        let mailAfter = try await tools.call("open_session", .object(["app": .string("Mail")]))
        #expect(fake.opened.isEmpty, "nothing opened")
        for answer in [maps, mail, mapsAfter, mailAfter] {
            #expect(Self.answered(answer)["opened"] == .bool(false) && !Self.text(answer).contains(secret), Comment(rawValue: Self.text(answer)))
        }
        #expect(Self.text(maps).contains(ValueMinimization.marker) && Self.answered(maps)["route"].string?.hasPrefix("web:") == true)
        #expect(transcript.lines.allSatisfy { !$0.contains(secret) }, "the transcript holds the secret")

        let calls = try await Self.recorded("advice", in: knowledge)
        let opens = calls.filter { $0.tool == "open_session" }
        #expect(opens.count == 4 && Set(opens.map(\.eventID)).count == 4, "four open_session calls, four event ids: \(opens.map(\.eventID))")
        for open in opens {
            #expect(open.status == .completed && open.route == nil && open.dispatch == nil
                    && open.rung == nil && open.performed == nil && open.samples == 0, "\(open)")
        }
        // The advice is exactly what was answered (both minimized under the same secret), the decision typed.
        func expected(_ answer: JSONValue) -> CallRouteAdvice? {
            let value = Self.answered(answer)
            if let question = value["ask"].string { return CallRouteAdvice(decision: .ask, route: nil, message: question) }
            guard let route = value["route"].string, let message = value["message"].string else { return nil }
            return CallRouteAdvice(decision: .use, route: route, message: message)
        }
        #expect(opens[0].advice == expected(maps) && opens[0].advice?.decision == .use
                && opens[0].advice?.route?.contains(ValueMinimization.marker) == true && opens[0].advice?.route?.contains(secret) == false
                && opens[0].advice?.message.contains(secret) == false, "\(String(describing: opens[0].advice))")
        #expect(opens[1].advice == expected(mail) && opens[1].advice?.decision == .ask && opens[1].advice?.route == nil
                && opens[1].advice?.message.isEmpty == false, "\(String(describing: opens[1].advice))")
        #expect(opens[2].advice == expected(mapsAfter) && opens[3].advice == expected(mailAfter))
        // Under the task while open, under none after it ended.
        #expect(opens[0].attribution == attribution && opens[1].attribution == attribution, "\(opens.map(\.attribution))")
        #expect(opens[2].attribution == nil && opens[3].attribution == nil, "\(opens.map(\.attribution))")
        // The archive's files, its WAL among them, while it is open (after the flush in `recorded`) and once closed.
        #expect(try CallRungRecordTests.files(under: knowledge, holding: secret).isEmpty, "the open archive holds the secret")
        await MemoryService.closeAll()
        #expect(try CallRungRecordTests.files(under: knowledge, holding: secret).isEmpty, "the closed archive holds the secret")
    }

    @Test("M05 RA-2: an open_session that opens records its route as today and no advice; the next, redirected, records its own and leaves the earlier call's none; one the tools refuse before the router records neither; counts exact, nothing replayed")
    func openKeepsItsDispatchAndNoAdvice() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let fake  = RouteFake(.desktop, memory: knowledge)
        let tools = AutomationTools(session: fake, channels: [.web])
        tools.producer = CallProducer(source: .app, streamID: "m05", traceID: "advice-open")
        let opened = try await tools.call("open_session", .object(["app": .string("Maps"), "named": .bool(true)]))
        let id = try #require(Self.sessionID(opened))
        #expect(fake.opened == ["Maps"])
        let redirected = Self.answered(try await tools.call("open_session", .object(["app": .string("Maps")])))
        #expect(redirected["opened"] == .bool(false) && redirected["route"].string == "web:google.com/maps", "\(redirected)")
        await #expect(throws: AutomationFailure.self, "refused by the tools before the router") {
            _ = try await tools.call("open_session", .object(["app": .string("Maps"), "named": .string("yes")]))
        }
        _ = try await tools.call("close_session", .object(["session": .string(id)]))
        #expect(fake.opened == ["Maps"], "opened once, never again")
        let calls = try await Self.recorded("advice-open", in: knowledge)
        #expect(calls.map(\.tool) == ["open_session", "open_session", "open_session", "close_session"], "\(calls.map(\.tool))")
        #expect(calls[0].status == .completed && calls[0].route == CallRoute(.desktop) && calls[0].advice == nil, "\(calls[0])")
        #expect(calls[1].status == .completed && calls[1].route == nil && calls[1].advice?.decision == .use
                && calls[1].advice?.route == "web:google.com/maps", "\(calls[1])")
        #expect(calls[2].status == .failed && calls[2].route == nil && calls[2].advice == nil, "\(calls[2])")
        #expect(calls[3].advice == nil && calls.allSatisfy { $0.dispatch == nil && $0.rung == nil
                                                                && $0.attribution == nil })
        #expect(calls[1].performed == nil && calls[1].samples == 0 && calls[2].performed == nil && calls[2].samples == 0)
        #expect(Set(calls.map(\.eventID)).count == 4, "four calls, each its own event")
        await MemoryService.closeAll()
    }

    // MARK: M05: the note of an open_session that opens as asked

    @Test("M05 ON-1: an open_session the router lets open with a note records the open decision and the exact note beside its real route, under the task's real attribution while open and under none after; an opening that fails after the decision keeps the note, once, with no observation, and the next open with no note records none; a refusal before the router records nothing of the router's; the contact's channel note is the open decision's advice, not a fallback; the declared secret is nowhere")
    func openNoteRecorded() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let fake  = RouteFake(.native, memory: knowledge)
        let tools = AutomationTools(session: fake, channels: [.web])
        tools.adapters = AppAdapters([ReadyAdapter()])
        tools.producer = CallProducer(source: .app, streamID: "m05", traceID: "open-note")
        let transcript = Transcript()
        tools.record = { transcript.lines.append($0) }
        let secret = "Finder"
        // The notes exactly as the router words them, minimized as the record and the answer minimize them.
        let finderNote = ValueMinimization(secrets: [secret])
            .minimize(text: "\(secret) has no files adapter in this build yet: driving its interface.").0
        let messagesNote = SharedRoutes.messageChannel + " " + SharedRoutes.whatsApp
        #expect(finderNote.contains(ValueMinimization.marker) && !finderNote.contains(secret))
        _ = try await tools.call("memory_task", .object([
            "operation": .string("begin"), "goal": .string("Tidy the folder"), "remaining": .string("Tidy the folder"),
            "inputs": .array([.object(["name": .string("app"), "value": .string(secret), "secret": .bool(true)])]),
        ]))
        let attribution = try #require(tools.openTask?.attribution)
        // Under the task: Finder opens with the fallback note (no files adapter in this build); Calendar is redirected.
        let finder = try await tools.call("open_session", .object(["app": .string(secret)]))
        #expect(Self.sessionID(finder) != nil && fake.opened.count == 1)
        #expect(Self.answered(finder)["routeNote"].string == finderNote && !Self.text(finder).contains(secret), Comment(rawValue: Self.text(finder)))
        let calendar = try await tools.call("open_session", .object(["app": .string("Calendar")]))
        #expect(Self.answered(calendar)["opened"] == .bool(false) && fake.opened.count == 1)
        _ = try await tools.call("memory_task", .object(["operation": .string("end"), "outcome": .string("completed")]))
        #expect(tools.openTask == nil)
        // After the task: a refusal before the router; an opening that fails right after the decision with the note;
        // then at once a named open with no note; then the contact's channel note, advice and not a fallback.
        await #expect(throws: AutomationFailure.self) {
            _ = try await tools.call("open_session", .object(["app": .string("Maps"), "named": .string("yes")]))
        }
        #expect(fake.opened.count == 1, "refused before the router: not invoked")
        fake.failsOpen = AutomationFailure("Finder showed no window.")
        await #expect(throws: AutomationFailure.self) {
            _ = try await tools.call("open_session", .object(["app": .string(secret)]))
        }
        fake.failsOpen = nil
        #expect(fake.opened.count == 2, "the failing open was invoked once, never again")
        _ = try await tools.call("open_session", .object(["app": .string("Maps"), "named": .bool(true)]))
        #expect(fake.opened.count == 3, "the named open was invoked once")
        let messages = try await tools.call("open_session", .object(["app": .string("Messages")]))
        #expect(Self.answered(messages)["routeNote"].string == messagesNote && fake.opened.count == 4)
        // The session open now is the last one the fake opened (Messages): closed by its own id.
        _ = try await tools.call("close_session", .object(["session": .string(try #require(fake.id?.uuidString))]))
        #expect(transcript.lines.allSatisfy { !$0.contains(secret) }, "the transcript holds the secret")

        let calls = try await Self.recorded("open-note", in: knowledge)
        let opens = calls.filter { $0.tool == "open_session" }
        #expect(opens.count == 6 && Set(opens.map(\.eventID)).count == 6, "\(opens.map(\.eventID))")
        // 1. Finder opened with the fallback note: the real route, the open decision with exactly the note, the task.
        #expect(opens[0].status == .completed && opens[0].route == CallRoute(.native) && opens[0].attribution == attribution, "\(opens[0])")
        #expect(opens[0].advice == CallRouteAdvice(decision: .open, route: nil, message: finderNote), "\(String(describing: opens[0].advice))")
        // 2. Calendar redirected: a use, no route, the task.
        #expect(opens[1].advice?.decision == .use && opens[1].advice?.route == "app_call(calendar)" && opens[1].route == nil
                && opens[1].attribution == attribution, "\(opens[1])")
        // 3. Refused before the router: failed, nothing of the router's, no task.
        #expect(opens[2].status == .failed && opens[2].route == nil && opens[2].advice == nil && opens[2].attribution == nil, "\(opens[2])")
        // 4. The opening failed after the decision: the same note kept as the call's fact, the route row of the dispatch that
        //    was attempted, the call failed with no observation sample, no task.
        #expect(opens[3].status == .failed && opens[3].advice == CallRouteAdvice(decision: .open, route: nil, message: finderNote)
                && opens[3].route == CallRoute(.native) && opens[3].samples == 0 && opens[3].attribution == nil, "\(opens[3])")
        // 5. Right after it, the named open with no note: the route, no advice (nothing of the failed call's), no task.
        //    (The fake's scene is not perceived through a recorder, so no open here keeps a sample; the failed one's
        //    zero samples above is the same fact, not a difference.)
        #expect(opens[4].status == .completed && opens[4].route == CallRoute(.native) && opens[4].advice == nil
                && opens[4].attribution == nil, "\(opens[4])")
        // 6. Messages: opened, the contact's channel note recorded exactly as the open decision's advice, its own routeNote.
        #expect(opens[5].status == .completed && opens[5].route == CallRoute(.native)
                && opens[5].advice == CallRouteAdvice(decision: .open, route: nil, message: messagesNote)
                && opens[5].advice?.message == Self.answered(messages)["routeNote"].string, "\(opens[5])")
        for open in opens {
            #expect(open.dispatch == nil && open.rung == nil && open.performed == nil
                    && open.route?.handoffReason == nil, "\(open)")
        }
        #expect(try CallRungRecordTests.files(under: knowledge, holding: secret).isEmpty, "the open archive holds the secret")
        await MemoryService.closeAll()
        #expect(try CallRungRecordTests.files(under: knowledge, holding: secret).isEmpty, "the closed archive holds the secret")
    }

    @Test("M05 ON-2: an adapter that cannot run: the app opens with the reason's words as the open decision's note, withheld when the reason is a declared secret; the route row is the dispatch, the decision stays open")
    func openNoteCarriesTheReason() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let fake  = RouteFake(.native, memory: knowledge)
        let tools = AutomationTools(session: fake, channels: [.web])
        let reason = "Calendar access is off for Braus in Privacy & Security"
        tools.adapters = AppAdapters([NotReadyAdapter(reason: reason)])
        tools.producer = CallProducer(source: .app, streamID: "m05", traceID: "open-reason")
        let transcript = Transcript()
        tools.record = { transcript.lines.append($0) }
        _ = try await tools.call("memory_task", .object([
            "operation": .string("begin"), "goal": .string("Add the meeting"), "remaining": .string("Add the meeting"),
            "inputs": .array([.object(["name": .string("why"), "value": .string(reason), "secret": .bool(true)])]),
        ]))
        let attribution = try #require(tools.openTask?.attribution)
        // The note exactly as the router words it, minimized as the record and the answer minimize it.
        let expectedNote = ValueMinimization(secrets: [reason])
            .minimize(text: "The calendar adapter cannot run (\(reason)): driving Calendar's interface instead.").0
        #expect(expectedNote.contains(ValueMinimization.marker) && !expectedNote.contains(reason))
        let calendar = try await tools.call("open_session", .object(["app": .string("Calendar")]))
        #expect(fake.opened == ["Calendar"])
        let note = Self.answered(calendar)["routeNote"].string ?? ""
        #expect(note == expectedNote, Comment(rawValue: note))
        _ = try await tools.call("memory_task", .object(["operation": .string("end"), "outcome": .string("completed")]))
        _ = try await tools.call("close_session", .object(["session": .string(try #require(Self.sessionID(calendar)))]))
        #expect(transcript.lines.allSatisfy { !$0.contains(reason) })
        let calls = try await Self.recorded("open-reason", in: knowledge)
        let opens = calls.filter { $0.tool == "open_session" }
        #expect(opens.count == 1, "\(opens)")
        let open = try #require(opens.first)
        #expect(open.status == .completed && open.route == CallRoute(.native) && open.attribution == attribution, "\(open)")
        #expect(open.advice == CallRouteAdvice(decision: .open, route: nil, message: expectedNote)
                && open.advice?.message == Self.answered(calendar)["routeNote"].string, "\(String(describing: open.advice))")
        #expect(open.dispatch == nil && open.rung == nil)
        #expect(try CallRungRecordTests.files(under: knowledge, holding: reason).isEmpty)
        await MemoryService.closeAll()
        #expect(try CallRungRecordTests.files(under: knowledge, holding: reason).isEmpty)
    }
}
