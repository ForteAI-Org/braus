//
//  CrossRouteRecallTests.swift
//  Braus
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Testing

/// M08: one site reached by two routes, the seat's Chrome (`com.google.Chrome`) and Braus's browser engine
/// (`web:shop.example`), is two identities, and a procedure learned through one is the procedure of that identity: the
/// Recall selects it for a need on its own identity, delivered under that identity, and never qualifies it for a need
/// the person set on the other.
@MainActor
@Suite("A procedure stays its route's own (M08)", .serialized, .automaticSelection)
struct CrossRouteRecallTests {

    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests

    nonisolated static let chrome  = "com.google.Chrome"
    nonisolated static let web     = "web:shop.example"
    nonisolated static let appHost = "web:shop.app"

    /// A shop's search page, as every route shows it.
    static func session(_ directory: URL) -> LearningSession {
        let page = LearningSession.Window(elements: [
            SceneElement(id: "field|search", kind: .control, label: "Search",
                         bounds: NormalizedRect(x: 0.3, y: 0.05, width: 0.3, height: 0.04), role: "AXTextField",
                         labelOrigin: .description),
            LearningSession.button("Go", x: 0.7),
        ], title: "Shop")
        let session = LearningSession(directory: directory)
        for app in [chrome, web, appHost] { session.windows[app] = page }
        return session
    }

    static let interpretation = """
        "procedure":{"label":"Search <query> on the shop"},
        "parts":[{"part":"b1","label":"Search <query> on the shop","outcome":"completed"}],
        "steps":[{"step":1,"label":"Type <query> in Search"},{"step":2,"label":"Run the search"}],
        "parameters":[{"name":"query","role":"text searched for on the shop","kind":"text"}],
        "uses":[{"step":1,"argument":"text","template":"{query}"}]
        """

    /// Searches the shop through `app`, ends the task, interprets the candidate, and waits for the Recall's index.
    static func learn(on app: String, _ session: LearningSession) async throws {
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        let tools = P.tools(session, stream: "learn")
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Search lamps on the shop","recall":false,
             "inputs":[{"name":"query","value":"lamps"}]}
            """#)
        _ = try await P.call(tools, "open_session", #"{"app":"\#(app)"}"#)
        let id = try #require(session.id).uuidString
        _ = try await P.call(tools, "type_text", #"{"session":"\#(id)","target":"Search","text":"lamps"}"#)
        _ = try await P.call(tools, "act", #"{"session":"\#(id)","target":"Go"}"#)
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string, "\(ended)")
        let interpreted = try await P.task(tools, #"{"operation":"interpret","candidate":"\#(candidate)","#
                                                  + Self.interpretation + "}")
        #expect(interpreted["status"].string != "error", "\(interpreted)")
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
    }

    /// A new task on the same search, its need set on `app`.
    static func need(on app: String, _ session: LearningSession) async throws -> JSONValue {
        let begun = try await P.task(P.tools(session, stream: "ask-\(app)"), #"""
            {"operation":"begin","goal":"Search lamps on the shop","remaining":"Search lamps on the shop",
             "inputs":[{"name":"query","value":"lamps"}],
             "needs":[{"text":"Search lamps on the shop","app":"\#(app)"}]}
            """#)
        return begun["recall"]["needs"].array?.first ?? .null
    }

    @Test("M08: learned on one route, the procedure is selected on its own identity, delivered under it, and never qualified for the other route",
          arguments: [(chrome, web, "Chrome"), (web, chrome, web), (appHost, chrome, "web:shop.app"),
                      (chrome, appHost, "Chrome")])
    func procedureStaysItsRoutesOwn(learned: String, other: String, delivered: String) async throws {
        let session = Self.session(try W.directory())
        try await Self.learn(on: learned, session)

        // On its own identity: selected, and every step and its entry condition name that identity, a web one whole
        // (`delivered`, written out here, never derived from the code under test).
        let own = try await Self.need(on: learned, session)
        #expect(own["coverage"].string == "complete" && own["app"].string == learned, "\(own)")
        let steps = own["selection"]["steps"].array ?? []
        #expect(!steps.isEmpty, "\(own)")
        for step in steps {
            #expect(step["app"].string == delivered, "\(step)")
        }
        let entry = (own["selection"]["conditions"].array ?? []).compactMap { $0["detail"].string }
        #expect(entry.contains { $0.contains("start in \(delivered) ") }, "\(entry)")

        // On the other route's identity: the need keeps it, and the procedure is not selected for it.
        let crossed = try await Self.need(on: other, session)
        #expect(crossed["app"].string == other, "\(crossed)")
        #expect(crossed["coverage"].string != "complete" && crossed["coverage"].string != "partial", "\(crossed)")
        #expect((crossed["selection"]["steps"].array ?? []).isEmpty,
                "nothing of the other route's procedure: \(crossed)")
        await L.close(session)
    }

    @Test("M08: a web identity resolves whole, a host ending in .app included, known or not; a native name drops .app")
    func webIdentityResolvesWhole() {
        let known = [RecallApplications.Known(bundleID: "web:shop.app", names: ["App"]),
                     RecallApplications.Known(bundleID: "com.apple.Preview", names: ["Preview"])]
        #expect(RecallApplications.resolve("web:shop.app", among: []) == .resolved("web:shop.app"))
        #expect(RecallApplications.resolve("web:shop.app", among: known) == .resolved("web:shop.app"))
        #expect(RecallApplications.resolve("Preview.app", among: known) == .resolved("com.apple.Preview"))
    }
}
