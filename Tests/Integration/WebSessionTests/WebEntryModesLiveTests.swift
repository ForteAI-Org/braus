//
//  WebEntryModesLiveTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Router
import Testing
import WebDriver
import WebSession

/// I01-W: one task on the web route, given by two of Braus's entries rebuilt in front of `AutomationTools`, on a real
/// headless Chrome with a new temporary profile and archive per mode: the app worker's mode (its loop calls the tools
/// directly) and the external MCP client's (JSON-RPC to an `MCPRouter` over the tools), each with its own producer and
/// channels `[.web]`. It compares two rebuilt modes, not the real entries (`WorkerAgentHost`, `ExternalMCPSession`).
/// `braus chat` is not a mode here: it refuses the web channel before any turn (`ChatSession`), a coherent outcome
/// but not the same effect.
///
/// The effect is what the page asked of the local shop server (`ShopFixtureServer`, 127.0.0.1): read without the
/// browser, Braus's perception or its answers. The oracles: one search for `lamps` from each mode and none from a stale
/// session ID; the same answers once identifiers are set aside; the same calls in each archive with the mode's own
/// producer; the same web identity; a declared secret in no answer and no file of the archive.
///
/// Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in `/Applications`. No network beyond 127.0.0.1, no
/// personal profile or session. Each session is closed on every path, which ends its Chrome by Chrome's own process
/// group (W14); the server is stopped and the folders removed on every path; every wait has a deadline.
@MainActor
@Suite(
    "One web task from two rebuilt entry modes (I01-W)",
    .serialized,
    .timeLimit(.minutes(3)),
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct WebEntryModesLiveTests {

    typealias Value = LocalMCP.JSONValue

    nonisolated static let secret = "Sentinel-I01W-R7m2"

    /// How long one wait may last.
    nonisolated static let patience: Duration = .seconds(15)

    enum Mode: String, CaseIterable {
        case app, mcp

        var source: MemoryEventSource { self == .app ? .app : .mcp }
        var stream: String { self == .app ? "worker-i01w" : "mcp-i01w" }
    }

    enum Outcome: Equatable, CustomStringConvertible {
        case answer(String)
        case refused(String)

        var description: String {
            switch self {
                case .answer(let text): "answer \(text)"
                case .refused(let text): "refused \(text)"
            }
        }
    }

    struct Run {
        var outcomes: [Outcome] = []
        var searches: [String]  = []
        var calls   : [String]  = []
        var apps    : [String]  = []
        var read    : [String]  = []
    }

    static func eventually(_ condition: () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + patience
        while !(await condition()) {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    static func json(_ text: String) -> Value {
        (try? JSONDecoder().decode(Value.self, from: Data(text.utf8))) ?? .null
    }

    /// A tool result's value as the model reads it: the JSON text of its one content item.
    static func payload(_ result: Value) -> Value {
        guard let text = result["content"].array?.first?["text"].string else { return result }
        return json(text) == .null ? result : json(text)
    }

    static func text(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    /// `text` with what is each run's own set aside: UUIDs, a candidate's digest (of its calls' event identifiers) and
    /// an observation's instant. Nothing else is.
    static func identifiersAside(_ text: String) -> String {
        text.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                                  with: "<id>", options: .regularExpression)
            .replacingOccurrences(of: "candidate-<id>-[0-9a-f]+", with: "candidate-<id>-<digest>",
                                  options: .regularExpression)
            .replacingOccurrences(of: #""observedAt":"[^"]*""#, with: #""observedAt":"<instant>""#,
                                  options: .regularExpression)
    }

    /// The searches the server received since `start`.
    static func searches(_ server: ShopFixtureServer, since start: Int) async -> [String] {
        await server.targets.dropFirst(start).filter { $0.hasPrefix("/search") }
    }

    /// The task in `mode` on the shop `server` serves: open the shop, begin with a declared secret (required begun),
    /// type the query, press Go, a call with a stale session ID, end (required ended, completed).
    static func run(_ mode: Mode, on server: ShopFixtureServer) async throws -> Run {
        let temporary = URL.temporaryDirectory.appending(path: "braus-i01-web-\(mode.rawValue)-\(UUID().uuidString)",
                                                         directoryHint: .isDirectory)
        let knowledge = temporary.appending(path: "Knowledge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let web = WebAutomationSession(
            knowledgeDirectory: knowledge,
            launchOptions     : ChromeLaunchOptions(userDataDirectory: temporary.appending(path: "profile"))
        )
        let tools = AutomationTools(session: RoutingAutomationSession(desktop: DesktopProbe(), web: web),
                                    channels: [.web])
        tools.producer = CallProducer(source: mode.source, streamID: mode.stream, traceID: "message-1",
                                      messageRef: "message-1")
        let router = MCPRouter(tools: tools.toolDefinitions) { name, arguments in
            try await tools.call(name, arguments)
        }
        let start = await server.targets.count
        var run = Run()

        // The value the model reads, recorded as an outcome. The worker's loop reads a result marked `isError` as a
        // failure (`ModelToolLoop`), so the direct call is classified by that mark too, as the router's answer is.
        func call(_ name: String, _ arguments: String) async -> Value {
            let outcome: Outcome
            let value: Value
            if mode == .app {
                do {
                    let result = try await tools.call(name, json(arguments))
                    run.read.append(text(result))
                    value = payload(result)
                    outcome = result["isError"].bool == true
                        ? .refused(identifiersAside(value["message"].string ?? text(value)))
                        : .answer(identifiersAside(text(value)))
                } catch {
                    run.read.append(String(describing: error))
                    value = .object(["thrown": .string(String(describing: error))])
                    outcome = .refused(identifiersAside(String(describing: error)))
                }
            } else {
                let request: Value = .object([
                    "jsonrpc": .string("2.0"), "id": .number(Double(run.outcomes.count + 1)),
                    "method": .string("tools/call"),
                    "params": .object(["name": .string(name), "arguments": json(arguments)]),
                ])
                let answer = await router.handle(request) ?? .null
                run.read.append(text(answer))
                let result = answer["result"]
                value = payload(result)
                outcome = result["isError"].bool == true
                    ? .refused(identifiersAside(value["message"].string ?? text(result)))
                    : .answer(identifiersAside(text(value)))
            }
            run.outcomes.append(outcome)
            return value
        }

        // The session and the archive are closed on every path, so Chrome never outlives the test and the folder is
        // removed with nothing open in it.
        do {
            // The page first: the routing session's memory is the web route's, there once the route is open
            // (`DesktopProbe` has none). A task begun before it answers no_memory (Codex's run of `6a198ad9`).
            func answered(_ what: String) {
                if case .refused(let words)? = run.outcomes.last { Issue.record("\(mode): \(what) refused: \(words)") }
            }
            _ = await call("open_session", #"{"app":"\#(server.url.absoluteString)"}"#)
            answered("open_session")
            let id = try #require(web.id, "\(mode): \(run.outcomes)").uuidString
            let begun = await call("memory_task", #"""
                {"operation":"begin","goal":"Search lamps on the shop","recall":false,
                 "inputs":[{"name":"query","value":"lamps"},{"name":"access_code","value":"\#(secret)","secret":true}]}
                """#)
            try #require(begun["status"].string == "begun", "\(mode): the task did not begin: \(begun)")
            _ = await call("type_text", #"{"session":"\#(id)","target":"Search","text":"lamps"}"#)
            answered("type_text")
            _ = await call("act", #"{"session":"\#(id)","target":"Go"}"#)
            answered("act")
            try #require(try await eventually { await !searches(server, since: start).isEmpty },
                         "\(mode): the shop received no search: \(run.outcomes)")
            let searched = await searches(server, since: start)
            _ = await call("act", #"{"session":"\#(UUID().uuidString)","target":"Go"}"#)
            if case .answer(let answered)? = run.outcomes.last {
                Issue.record("\(mode): a stale session ID was answered: \(answered)")
            }
            try await Task.sleep(for: .milliseconds(500))
            #expect(await searches(server, since: start) == searched, "\(mode): a search after the stale call")
            let ended = await call("memory_task", #"{"operation":"end","outcome":"completed"}"#)
            try #require(ended["status"].string == "ended" && ended["outcome"].string == "completed",
                         "\(mode): the task did not end completed: \(ended)")
        } catch {
            await web.close()
            await MemoryService.shared(for: knowledge).close()
            MemoryService.forget(knowledge)
            throw error
        }
        await web.close()

        run.searches = await searches(server, since: start)
        // The archive closed first, so what its queue held is written before it is read.
        await MemoryService.shared(for: knowledge).close()
        MemoryService.forget(knowledge)
        let archive = knowledge.appendingPathComponent("memory.sqlite")
        run.calls = try WebSessionLiveTests.rows("""
            SELECT e.source || ' ' || e.source_stream_id || ' ' || a.tool_kind || ' ' || a.execution_status || ' '
                   || ifnull(a.result_kind, '-')
            FROM memory_events e JOIN memory_agent_actions a ON a.event_id = e.event_id ORDER BY e.local_order
            """, at: archive)
        run.apps = try WebSessionLiveTests.rows("SELECT bundle_id FROM brain_apps ORDER BY bundle_id", at: archive)

        // The declared secret, whole or its tail, in no file of the archive.
        var files = 0
        let walk = FileManager.default.enumerator(at: knowledge, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = walk?.nextObject() as? URL {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = try Data(contentsOf: file)
            files += 1
            for form in [secret, "R7m2"] {
                #expect(data.range(of: Data(form.utf8)) == nil, "\(mode): \(file.lastPathComponent) holds \(form)")
            }
        }
        #expect(files > 0, "\(mode): no file in the archive")
        return run
    }

    @Test("I01-W: the same web task from the worker's mode and the MCP client's: one search each on the local shop, none from a stale ID, the same answers and calls, each call its mode's own")
    func sameWebTaskFromTwoModes() async throws {
        let server = try await ShopFixtureServer.start()
        var runs: [Mode: Run] = [:]
        do {
            for mode in Mode.allCases { runs[mode] = try await Self.run(mode, on: server) }
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()

        let app = try #require(runs[.app]), mcp = try #require(runs[.mcp])
        print("searches:", app.searches, mcp.searches)
        print("calls:", app.calls)
        print("apps:", app.apps)
        #expect(app.searches == ["/search?q=lamps"] && mcp.searches == ["/search?q=lamps"],
                "one search each: \(app.searches) \(mcp.searches)")
        #expect(mcp.outcomes.count == app.outcomes.count)
        for (index, pair) in zip(mcp.outcomes, app.outcomes).enumerated() {
            #expect(pair.0 == pair.1, "call \(index + 1): \(pair.0) against \(pair.1)")
        }
        let mine = mcp.calls.map { $0.replacingOccurrences(of: "mcp \(Mode.mcp.stream) ", with: "") }
        let apps = app.calls.map { $0.replacingOccurrences(of: "app \(Mode.app.stream) ", with: "") }
        #expect(!apps.isEmpty && mine == apps, "\(mcp.calls) against \(app.calls)")
        #expect(app.calls.allSatisfy { $0.hasPrefix("app \(Mode.app.stream) ") }, "\(app.calls)")
        #expect(mcp.calls.allSatisfy { $0.hasPrefix("mcp \(Mode.mcp.stream) ") }, "\(mcp.calls)")
        #expect(app.apps == mcp.apps && app.apps.count == 1 && app.apps.first?.hasPrefix("web:") == true,
                "\(app.apps) \(mcp.apps)")
        for (mode, run) in runs {
            for text in run.read {
                #expect(!text.contains(Self.secret) && !text.contains("R7m2"), "\(mode): \(text.prefix(300))")
            }
        }
    }
}
