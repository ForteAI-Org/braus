import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Router
import SQLiteMemory
import TestScratch
import Testing
import WindowServerListing

/// The router before the drivers, on stub sessions: which session each `open` goes to, and that the
/// later calls follow it.
@MainActor
@Suite("Router")
struct RouterTests {

    @Test("a native app goes to the native session when it takes it, else to the desktop by bundle id")
    func routesNativeApps() async throws {
        let native = SessionStub()
        let desktop = SessionStub()
        let routing = RoutingAutomationSession(native: native, desktop: desktop)
        _ = try await routing.open(application: "Notes", window: nil)
        #expect(native.opened == ["Notes"] && desktop.opened.isEmpty)
        #expect(routing.lastHandoff == nil)

        let giving = SessionStub(handoff: HandoffStub(bundleID: "com.example.canvas"))
        let seat = SessionStub()
        let routed = RoutingAutomationSession(native: giving, desktop: seat)
        _ = try await routed.open(application: "Canvas", window: nil)
        #expect(seat.opened == ["com.example.canvas"])
        #expect(routed.lastHandoff?.bundleID == "com.example.canvas")
        _ = try await routed.observe()
        #expect(seat.observed == 1, "later calls go to the session that opened")
    }

    @Test("a native session giving the app back at a later call: the desktop opens it and the same call runs there")
    func handoffMidSession() async throws {
        let native = SessionStub()
        let desktop = SessionStub()
        let routing = RoutingAutomationSession(native: native, desktop: desktop)
        _ = try await routing.open(application: "Notes", window: "Note")
        native.laterHandoff = HandoffStub(bundleID: "com.apple.Notes")
        let outcome = try await routing.act(target: "Nuova nota", verb: .click, section: nil, desiredState: nil)
        #expect(outcome.message == "desktop acted on 'Nuova nota'")
        #expect(desktop.opened == ["com.apple.Notes"] && desktop.windows == ["Note"])
        #expect(native.acted.isEmpty && routing.lastHandoff?.bundleID == "com.apple.Notes")
        #expect(routing.id == desktop.id)
        _ = try await routing.observe()
        #expect(desktop.observed == 1, "later calls stay on the desktop session")
    }

    @Test("M05: each call's record keeps the route it was dispatched on, and the MacDriver's reason when it gave the app back; a call that reached no session keeps none")
    func routesRecorded() async throws {
        let directory = Scratch.directory("router-routes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = MemoryService(directory: directory)
        let brain = BrainMemory(brains: memory, applications: memory, relations: memory,
                                clock: { memory.clock.brainNow() })
        let native = SessionStub(), desktop = SessionStub(), web = SessionStub()
        let routing = RoutingAutomationSession(native: native, desktop: desktop, web: web)
        var traces = 0
        // A text the task declared secret and one a call classified, which a hand-back's reason may name.
        let declared = "Sentinel-Declared-M05", classified = "Sentinel-Classified-M05"
        let withheld = ValueMinimization(secrets: [declared], classified: [classified: .secureField])
        // One call through its recorder, as the tools make it: begun, run with the recorder current, ended.
        func recorded(_ request: AgentCallRequest, _ body: () async throws -> Void) async throws -> CallRoute? {
            try await call(request, body).route
        }
        // The call's route and state as the archive reads them back.
        func call(_ request: AgentCallRequest,
                  _ body: () async throws -> Void) async throws -> (route: CallRoute?, status: AgentCallStatus?) {
            traces += 1
            let recorder = CallRecorder(memory: memory, brain: brain, context: ActionContext(
                source: .app, streamID: "router", traceID: "t\(traces)", sessionID: "s1"), minimization: withheld)
            try await recorder.begin(request, app: AppContextIdentity(bundleID: "com.example"))
            do {
                try await CallRecorder.$current.withValue(recorder) { try await body() }
                // An action answers an outcome; an open or an observation whose rows were not recorded is a gap.
                try await recorder.end(.completed,
                                       result: request.tool.answersOutcome ? .outcome(.foundActed, message: "acted") : nil,
                                       tool: request.tool,
                                       check: request.tool.isOperation ? .unchecked(performed: .requested) : nil)
            } catch {
                try await recorder.end(.failed, result: .error(message: "\(error)"), tool: request.tool,
                                       check: request.tool.isOperation ? .unchecked(performed: .uncertain) : nil)
            }
            let route = try await memory.perform { try await $0.facts.route(of: recorder.eventID) }
            return (route, try await memory.call(recorder.eventID)?.progress.status)
        }
        let click = AgentCallRequest.act(target: "Nuova nota", verb: .click, value: nil, section: nil)

        #expect(try await recorded(.openSession(app: "Notes", window: "Note")) {
            _ = try await routing.open(application: "Notes", window: "Note")
        } == CallRoute(.native))
        #expect(try await recorded(click) {
            _ = try await routing.act(target: "Nuova nota", verb: .click, section: nil, desiredState: nil)
        } == CallRoute(.native))
        // The MacDriver gives Notes back at the next call: the record says the desktop ran it, and why.
        native.laterHandoff = HandoffStub(bundleID: "com.apple.Notes")
        #expect(try await recorded(click) {
            _ = try await routing.act(target: "Nuova nota", verb: .click, section: nil, desiredState: nil)
        } == CallRoute(.desktop, handoffReason: "stub"))
        #expect(try await recorded(.observe(full: false)) { _ = try await routing.observe() } == CallRoute(.desktop),
                "a later call on the desktop was not handed back")
        #expect(try await recorded(.openSession(app: "web:example.com", window: nil)) {
            _ = try await routing.open(application: "web:example.com", window: nil)
        } == CallRoute(.web))
        // A call the desktop session fails keeps the route it ran on.
        let failing = RoutingAutomationSession(desktop: SessionStub(handoff: HandoffStub(bundleID: "com.example.x")))
        #expect(try await recorded(.openSession(app: "X", window: nil)) {
            _ = try await failing.open(application: "X", window: nil)
        } == CallRoute(.desktop))
        #expect(try await recorded(.openSession(app: "Notes", window: nil)) {} == nil, "nothing was dispatched")
        // The dispatch attempted, not an effect: the MacDriver gives the app back at its open and the desktop's open
        // fails, so the call failed on the desktop, with the reason; the reason's withheld texts are not kept.
        let reason = "Window \(declared) of \(classified) shows the MacDriver nothing it can read."
        let attempted = RoutingAutomationSession(
            native : SessionStub(handoff: HandoffStub(bundleID: "com.example.y", text: reason)),
            desktop: SessionStub(handoff: HandoffStub(bundleID: "com.example.y")))
        let failed = try await call(.openSession(app: "Y", window: nil)) {
            _ = try await attempted.open(application: "Y", window: nil)
        }
        #expect(failed.status == .failed, "\(String(describing: failed.status))")
        #expect(failed.route?.route == .desktop, "\(String(describing: failed.route))")
        let kept = try #require(failed.route?.handoffReason)
        #expect(!kept.contains(declared) && !kept.contains(classified) && kept.contains(ValueMinimization.marker), "\(kept)")
        await memory.close()
        // Nothing of either text in any file the archive wrote.
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var read = 0
        while let file = files?.nextObject() as? URL {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = try Data(contentsOf: file)
            read += 1
            for text in [declared, classified] {
                #expect(data.range(of: Data(text.utf8)) == nil, "\(file.lastPathComponent) holds \(text)")
            }
        }
        #expect(read > 0, "the archive's files were read")
    }

    @Test("a handoff from the desktop session itself is not routed again")
    func desktopHandoffPropagates() async throws {
        let desktop = SessionStub()
        let routing = RoutingAutomationSession(desktop: desktop)
        _ = try await routing.open(application: "Finder", window: nil)
        desktop.laterHandoff = HandoffStub(bundleID: "com.apple.finder")
        await #expect(throws: HandoffStub.self) { try await routing.observe() }
        #expect(desktop.opened == ["Finder"])
    }

    @Test("without a native session a native app goes to the desktop")
    func withoutNative() async throws {
        let desktop = SessionStub()
        let routing = RoutingAutomationSession(desktop: desktop, web: SessionStub())
        _ = try await routing.open(application: "Finder", window: nil)
        #expect(desktop.opened == ["Finder"])
        #expect(routing.id == desktop.id)
    }

    @Test("an address goes to the web session and closes the open native one; an app closes the web one")
    func movesBetweenSessions() async throws {
        let native = SessionStub()
        let web = SessionStub()
        let routing = RoutingAutomationSession(native: native, desktop: SessionStub(), web: web)
        _ = try await routing.open(application: "Notes", window: nil)
        _ = try await routing.open(application: "file:///tmp/page.html", window: nil)
        #expect(web.opened == ["file:///tmp/page.html"])
        #expect(native.id == nil && routing.id == web.id)
        _ = try await routing.open(application: "Notes", window: nil)
        #expect(web.id == nil && routing.id == native.id)
    }

    @Test("a web address is refused with the reason when the router has no web session")
    func webWithoutWebSession() async throws {
        let native = SessionStub()
        let routing = RoutingAutomationSession(native: native, desktop: SessionStub())
        await #expect(throws: AutomationFailure.self) { try await routing.open(application: "web:google.com/maps", window: nil) }
        #expect(native.opened.isEmpty)
    }

    @Test("a web address is told from an application name, whatever its case or spacing")
    func webAddresses() {
        for word in ["web:example.com", " WEB:maps", "https://example.com", "HTTP://x", "file:///tmp/a.html"] {
            #expect(RoutingAutomationSession.isWebAddress(word), "\(word)")
        }
        for word in ["Safari", "Google Chrome", "Finder", "webex", "com.apple.Safari"] {
            #expect(!RoutingAutomationSession.isWebAddress(word), "\(word)")
        }
    }
}

struct HandoffStub: RouteHandoff, Equatable {
    let bundleID: String
    var text = "stub"
    var reason: String { text }
}

/// A session that records what it opened and gives `handoff` back when it has one.
@MainActor
final class SessionStub: AutomationSessionOperating {
    let handoff: HandoffStub?
    var id: UUID? = nil
    var opened: [String] = []
    var windows: [String?] = []
    var observed = 0
    var acted: [String] = []
    /// Given back at the start of the next call after `open`, as the MacDriver does after a front steal.
    var laterHandoff: HandoffStub?

    init(handoff: HandoffStub? = nil) { self.handoff = handoff }

    static let scene = SceneSnapshot(bundleID: "com.example", appName: "Example", windowTitle: "Example",
                                     viewportPixelSize: ViewportPixelSize(width: 800, height: 600), elements: [])

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        if let handoff { throw handoff }
        opened.append(application)
        windows.append(window)
        id = UUID()
        return Self.scene
    }
    func observe() async throws -> SceneSnapshot {
        if let laterHandoff { await close(); throw laterHandoff }
        observed += 1
        return Self.scene
    }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        if let laterHandoff { await close(); throw laterHandoff }
        acted.append(target)
        return ActOutcome(.foundActed, "desktop acted on '\(target)'")
    }
    func select(control: String, item: String) async throws -> ActOutcome { ActOutcome(.refused, "stub") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { ActOutcome(.refused, "stub") }
    func close() async { id = nil }
    func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] { [] }
}
