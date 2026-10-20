//
//  ThreeEntriesTests.swift
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

/// I01 at L0: one task given to Braus by its three entries, each as production composes it in front of
/// `AutomationTools`: an app worker's loop calls the tools directly (`WorkerAgentHost`'s `call`), `braus chat` and an
/// external MCP client speak JSON-RPC to an `MCPRouter` over the tools (`ChatSession`, `ExternalMCPSession`), each with
/// its own producer. Each entry drives its own session double and archive, the same shop page.
///
/// The oracles: the effect, read from the session's own record of gestures and never from the answers, is the same
/// from every entry; so is the policy (a stale session ID refused before any gesture, a declared secret in no answer
/// and no file of the archive); the outcomes agree (each answer the same once its identifiers are set aside, each
/// refusal the same words); and the archive records the same calls with each entry's own producer.
///
/// What is not proved here: the entries' compositions themselves (`WorkerAgentHost`, `ChatSession` and
/// `ExternalMCPSession` need the app, a Seat or a provider), their transports (`LocalMCPHost`, the bridge), and any
/// live route.
@MainActor
@Suite("One task from the three entries (I01)", .serialized)
struct ThreeEntriesTests {

    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests

    nonisolated static let shop   = "com.example.Shop"
    nonisolated static let secret = "Sentinel-I01-K4v8"

    /// An entry: who it is to the archive, and whether its calls cross a JSON-RPC router.
    enum Entry: String, CaseIterable {
        case app, cli, mcp

        var source: MemoryEventSource {
            switch self {
                case .app: .app
                case .cli: .cli
                case .mcp: .mcp
            }
        }

        var stream: String {
            switch self {
                case .app: "worker-i01"
                case .cli: "chat-i01"
                case .mcp: "mcp-i01"
            }
        }
    }

    /// What one call came back as: the tool's answer, or the refusal's words.
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

    /// One entry's run: its calls' outcomes, the session's gestures, the archive's calls and every text the entry read.
    struct Run {
        var outcomes: [Outcome] = []
        var gestures: [String]  = []
        var calls   : [String]  = []
        var read    : [String]  = []
    }

    /// The search page: a field and a button.
    static func session(_ directory: URL) -> LearningSession {
        let session = LearningSession(directory: directory)
        session.windows[shop] = LearningSession.Window(elements: [
            SceneElement(id: "field|search", kind: .control, label: "Search",
                         bounds: NormalizedRect(x: 0.3, y: 0.05, width: 0.3, height: 0.04), role: "AXTextField",
                         labelOrigin: .description),
            LearningSession.button("Go", x: 0.7),
        ], title: "Shop")
        return session
    }

    /// `text` with what is each run's own set aside: every UUID (session, task, call and event identifiers), a
    /// candidate's digest (of its calls' event identifiers, `ProcedureSegmentation.digest`) and the instant of an
    /// observation. Nothing else is.
    static func identifiersAside(_ text: String) -> String {
        text.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                                  with: "<id>", options: .regularExpression)
            .replacingOccurrences(of: "candidate-<id>-[0-9a-f]+", with: "candidate-<id>-<digest>",
                                  options: .regularExpression)
            .replacingOccurrences(of: #""observedAt":"[^"]*""#, with: #""observedAt":"<instant>""#,
                                  options: .regularExpression)
    }

    /// `value`'s JSON with its keys in order, so two answers compare by content.
    static func text(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    /// The task through `entry`: begin with a declared secret, open the shop, type the query and the secret, search, a
    /// call with a stale session ID, end.
    static func run(_ entry: Entry) async throws -> Run {
        let session = Self.session(try W.directory())
        let tools = P.tools(session, source: entry.source, stream: entry.stream)
        let router = MCPRouter(tools: tools.toolDefinitions) { name, arguments in
            try await tools.call(name, arguments)
        }
        var run = Run()

        func call(_ name: String, _ arguments: String) async -> Outcome {
            let outcome: Outcome
            if entry == .app {
                do {
                    let value = try await tools.call(name, P.json(arguments))
                    run.read.append(text(value))
                    outcome = .answer(identifiersAside(text(value.payload)))
                } catch {
                    run.read.append(String(describing: error))
                    outcome = .refused(identifiersAside(String(describing: error)))
                }
            } else {
                let request: JSONValue = .object([
                    "jsonrpc": .string("2.0"), "id": .number(Double(run.outcomes.count + 1)),
                    "method": .string("tools/call"),
                    "params": .object(["name": .string(name), "arguments": P.json(arguments)]),
                ])
                let answer = await router.handle(request) ?? .null
                run.read.append(text(answer))
                let result = answer["result"]
                outcome = result["isError"].bool == true
                    ? .refused(identifiersAside(result.payload["message"].string ?? text(result)))
                    : .answer(identifiersAside(text(result.payload)))
            }
            run.outcomes.append(outcome)
            return outcome
        }

        _ = await call("memory_task", #"""
            {"operation":"begin","goal":"Search lamps on the shop","recall":false,
             "inputs":[{"name":"query","value":"lamps"},{"name":"access_code","value":"\#(secret)","secret":true}]}
            """#)
        _ = await call("open_session", #"{"app":"\#(shop)"}"#)
        let id = try #require(session.id, "\(run.outcomes)").uuidString
        _ = await call("type_text", #"{"session":"\#(id)","target":"Search","text":"lamps"}"#)
        _ = await call("type_text", #"{"session":"\#(id)","target":"Search","text":"\#(secret)"}"#)
        _ = await call("act", #"{"session":"\#(id)","target":"Go"}"#)
        let before = session.gestures
        let stale = await call("act", #"{"session":"\#(UUID().uuidString)","target":"Go"}"#)
        #expect(session.gestures == before, "\(entry): a stale ID reached the session")
        if case .answer = stale { Issue.record("\(entry): a stale session ID was answered: \(stale)") }
        _ = await call("memory_task", #"{"operation":"end","outcome":"completed"}"#)

        run.gestures = session.gestures
        run.calls = try P.rows("""
            SELECT e.source || ' ' || e.source_stream_id || ' ' || a.tool_kind || ' ' || a.execution_status || ' '
                   || ifnull(a.result_kind, '-')
            FROM memory_events e JOIN memory_agent_actions a ON a.event_id = e.event_id ORDER BY e.local_order
            """, in: session)
        await L.close(session)

        // The declared secret, whole or its tail, in no file of the archive.
        var files = 0
        let walk = FileManager.default.enumerator(at: session.directory,
                                                  includingPropertiesForKeys: [.isRegularFileKey])
        while let file = walk?.nextObject() as? URL {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = try Data(contentsOf: file)
            files += 1
            for form in [secret, "K4v8"] {
                #expect(data.range(of: Data(form.utf8)) == nil, "\(entry): \(file.lastPathComponent) holds \(form)")
            }
        }
        #expect(files > 0, "\(entry): no file in the archive")
        return run
    }

    @Test("I01: the same task from an app worker, braus chat and an MCP client: the same gestures, policy and outcomes, each call its entry's own")
    func sameTaskFromEachEntry() async throws {
        var runs: [Entry: Run] = [:]
        for entry in Entry.allCases { runs[entry] = try await Self.run(entry) }
        let app = try #require(runs[.app])
        print("gestures:", app.gestures)
        print("outcomes:", app.outcomes.map { String($0.description.prefix(160)) })
        print("calls:", app.calls)

        #expect(app.gestures.contains { $0.contains("Go") }, "the search was carried out: \(app.gestures)")
        for entry in [Entry.cli, .mcp] {
            let run = try #require(runs[entry])
            #expect(run.gestures == app.gestures, "\(entry): \(run.gestures) against \(app.gestures)")
            #expect(run.outcomes.count == app.outcomes.count, "\(entry)")
            for (index, pair) in zip(run.outcomes, app.outcomes).enumerated() {
                #expect(pair.0 == pair.1, "\(entry), call \(index + 1): \(pair.0) against \(pair.1)")
            }
            // The archive records the same calls, each with the entry's own producer.
            let mine = run.calls.map { $0.replacingOccurrences(of: "\(entry.rawValue) \(entry.stream) ", with: "") }
            let apps = app.calls.map { $0.replacingOccurrences(of: "app \(Entry.app.stream) ", with: "") }
            #expect(mine == apps, "\(entry): \(run.calls) against \(app.calls)")
            #expect(run.calls.allSatisfy { $0.hasPrefix("\(entry.rawValue) \(entry.stream) ") }, "\(run.calls)")
        }
        #expect(!app.calls.isEmpty && app.calls.allSatisfy { $0.hasPrefix("app \(Entry.app.stream) ") }, "\(app.calls)")
        // The secret in nothing any entry read.
        for (entry, run) in runs {
            for text in run.read {
                #expect(!text.contains(Self.secret) && !text.contains("K4v8"), "\(entry): \(text.prefix(300))")
            }
        }
    }
}
