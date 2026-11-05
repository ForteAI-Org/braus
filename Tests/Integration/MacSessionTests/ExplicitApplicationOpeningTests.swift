import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Router
import Testing

@MainActor
struct ExplicitApplicationOpeningTests {
    @Test(arguments: ["Maps", "Calendario", "Mail"])
    func explicitAppOpensExactlyOnceWithoutNamed(_ app: String) async throws {
        let native = SessionStub(handoff: nil), desktop = SessionStub(handoff: nil), web = SessionStub(handoff: nil)
        let routing = RoutingAutomationSession(native: native, desktop: desktop, web: web)
        let adapter = CountingOpeningAdapter()
        let tools = AutomationTools(session: routing, channels: [.web, .adapters], adapters: AppAdapters([adapter]))
        for named in [false, true] {
            await #expect(throws: AutomationFailure.self) {
                try await tools.call("open_session", .object(["app": .string(app), "named": .bool(named)]))
            }
        }
        #expect(native.opened.isEmpty && desktop.opened.isEmpty && web.opened.isEmpty)
        let result = try await tools.call("open_session", .object(["app": .string(app)]))
        #expect(result["isError"].bool != true)
        #expect(native.opened == [app])
        #expect(desktop.opened.isEmpty && web.opened.isEmpty)
        #expect(routing.id == native.id && routing.id != nil)
        #expect(await adapter.calls == 0)
        await routing.close()
    }
    @Test(arguments: [false, true])
    func interruptionReportsOnlyANewAdoption(_ adopted: Bool) async throws {
        let native = SessionStub(handoff: nil), desktop = SessionStub(handoff: nil)
        let routing = RoutingAutomationSession(native: native, desktop: desktop)
        let tools = AutomationTools(session: routing)
        _ = try await tools.call("open_session", .object(["app": .string("App A")]))
        let original = try #require(routing.id)
        native.openingError = CancellationError()
        native.adoptsBeforeError = adopted
        let interruption = AutomationCallInterruption()
        do {
            let answer = try await AutomationCallInterruption.$current.withValue(interruption) {
                try await tools.call("open_session", .object(["app": .string("App B")]))
            }
            #expect(adopted, "A's retained ID must not be reported as B opened")
            let text = try #require(answer["content"].array?.first?["text"].string)
            #expect(text.contains("\"opened\":true") && !text.contains("\"scene\":"))
        } catch is CancellationError { #expect(!adopted) }
        #expect(adopted ? routing.id != original : routing.id == original)
        #expect(native.opened == (adopted ? ["App A", "App B"] : ["App A"]))
        await routing.close()
    }

}

/// A ready adapter with an executable verb; opening its app must never execute it.
private actor CountingOpeningAdapter: AppAdapting {
    nonisolated let name = "calendar"
    nonisolated let appNames = ["Calendar"]
    nonisolated let bundleIDs: Set<String> = ["com.apple.iCal"]
    nonisolated let verbs = [AdapterVerb("touch", "Synthetic operation.", parameters: [],
        safety: .write, readBack: "none, synthetic")]
    private(set) var calls = 0

    func availability() async -> AdapterAvailability { .ready }

    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        calls += 1
        return AdapterOutcome(.foundActed, "Synthetic operation executed.")
    }
}
