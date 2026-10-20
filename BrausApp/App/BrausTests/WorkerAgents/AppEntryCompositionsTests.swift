//
//  AppEntryCompositionsTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import LocalMCP
import Memory
import ModelTransports
import PerceptionCore
import Synchronization
import Testing
@testable import Braus

/// I01-A in the app: one task through two of the app's real compositions in front of `AutomationTools`: a worker's
/// `WorkerAgentHost`, whose `ModelToolLoop` runs the calls a scripted model transport issues, and an external client's
/// `ExternalMCPSession`, through its router. Each drives a session double of its own with a real archive in a
/// temporary folder; the desktop, a Seat and a provider are not used. `braus chat` is not part of the app, so the CLI
/// entry is not here.
///
/// The oracles: the double's record of gestures is the same from both; the task begins and ends completed in each;
/// a stale session ID is refused before any gesture; every answer the model or the client read is the same once its
/// identifiers are set aside, each refusal the same words; each archive records the same calls, each with its
/// composition's own producer; a declared secret is in no answer and no file of either archive.
@MainActor
@Suite("One task through the app's worker and external client compositions (I01-A)", .serialized,
       .timeLimit(.minutes(2)))
struct AppEntryCompositionsTests {

    nonisolated static let secret = "Sentinel-I01A-P3x6"

    /// The task's calls, in order, from the session ID the `open_session` answer gave (nil before it).
    nonisolated static let steps: [@Sendable (String?) -> (name: String, arguments: String)] = [
        { _ in ("open_session", #"{"app":"Synthetic Shop"}"#) },
        { _ in ("memory_task", #"""
            {"operation":"begin","goal":"Search lamps on the shop","recall":false,
             "inputs":[{"name":"query","value":"lamps"},
              {"name":"access_code","value":"\#(AppEntryCompositionsTests.secret)","secret":true}]}
            """#) },
        { id in ("type_text", #"{"session":"\#(id ?? "")","target":"Search","text":"lamps"}"#) },
        { id in (
            "type_text",
            #"{"session":"\#(id ?? "")","target":"Search","text":"\#(AppEntryCompositionsTests.secret)"}"#
        ) },
        { id in ("act", #"{"session":"\#(id ?? "")","target":"Go"}"#) },
        { _ in ("act", #"{"session":"\#(UUID().uuidString)","target":"Go"}"#) },
        { _ in ("memory_task", #"{"operation":"end","outcome":"completed"}"#) },
    ]

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

    /// One composition's run: the texts read, as outcomes and raw, the gestures, and the archive's calls.
    struct Run {
        var outcomes: [Outcome] = []
        var read    : [String]  = []
        var gestures: [String]  = []
        var calls   : [String]  = []
    }

    nonisolated static func decode(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    /// `value`'s JSON with its keys in order.
    static func sorted(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    /// What is each run's own set aside: UUIDs, a candidate's digest (of its calls' event identifiers) and an
    /// observation's instant. Nothing else is.
    static func identifiersAside(_ text: String) -> String {
        text.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
                                  with: "<id>", options: .regularExpression)
            .replacingOccurrences(of: "candidate-<id>-[0-9a-f]+", with: "candidate-<id>-<digest>",
                                  options: .regularExpression)
            .replacingOccurrences(of: #""observedAt":"[^"]*""#, with: #""observedAt":"<instant>""#,
                                  options: .regularExpression)
    }

    /// A tool's answer as the model reads it (`ModelToolLoop`) and a client reads it: its MCP text and its error mark.
    static func outcome(text: String, isError: Bool) -> Outcome {
        let value = decode(text)
        return isError
            ? .refused(identifiersAside(value["message"].string ?? text))
            : .answer(identifiersAside(value == .null ? text : sorted(value)))
    }

    /// The archive's calls, read with the system's `sqlite3` read-only once the archive is closed (each folder is this
    /// run's own, so the closed service is never asked for again; `forget` is not visible to the app's tests).
    static func calls(in directory: URL) async throws -> [String] {
        await MemoryService.shared(for: directory).close()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", directory.appending(path: "memory.sqlite").path, """
            SELECT e.source || ' ' || e.source_stream_id || ' ' || a.tool_kind || ' ' || a.execution_status || ' '
                   || ifnull(a.result_kind, '-')
            FROM memory_events e JOIN memory_agent_actions a ON a.event_id = e.event_id ORDER BY e.local_order;
            """]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "sqlite3 could not read the archive")
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// No piece of the secret in any file under `directory`; how many files were read.
    static func secretAbsent(under directory: URL, _ label: String) throws -> Int {
        var files = 0
        let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = walk?.nextObject() as? URL {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = try Data(contentsOf: file)
            files += 1
            for form in [secret, "P3x6"] {
                #expect(data.range(of: Data(form.utf8)) == nil, "\(label): \(file.lastPathComponent) holds \(form)")
            }
        }
        return files
    }

    /// The task through a worker's host: its loop runs each call the scripted transport issues.
    static func worker(under root: URL) async throws -> Run {
        let archive = root.appending(path: "worker-archive", directoryHint: .isDirectory)
        let work = root.appending(path: "worker-work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let desktop = EntryDesktop(directory: archive)
        let transport = StepTransport(steps: steps)
        let host = WorkerAgentHost(workingDirectory: work, bridgeExecutable: URL(filePath: "/usr/bin/false"),
                                   session: { desktop },
                                   agents: { _ in throw AutomationFailure("no command line in this test") },
                                   transports: { _ in transport })
        host.callProducer = CallProducer(source: .app, streamID: "worker-i01a", traceID: "message-1",
                                         messageRef: "message-1")
        do {
            try await host.run(prompt: "Search lamps on the shop.",
                               selection: ModelSelection(provider: .ollama, model: "qwen3:8b", effort: .high),
                               sessionID: nil, role: nil, onEvent: { _ in })
            try await host.close()
        } catch {
            try? await host.close()
            await MemoryService.shared(for: archive).close()
            throw error
        }
        let answered = (transport.sent.last ?? []).filter { $0.role == .tool }
        var run = Run()
        run.outcomes = answered.map { outcome(text: $0.text, isError: $0.isError) }
        run.read = answered.map(\.text)
        run.gestures = desktop.gestures
        run.calls = try await calls(in: archive)
        #expect(try secretAbsent(under: archive, "worker") > 0, "worker: no file in the archive")
        return run
    }

    /// The task through an external client's session: each call through its router, as the bridge delivers it.
    static func client(under root: URL) async throws -> Run {
        let archive = root.appending(path: "client-archive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let desktop = EntryDesktop(directory: archive)
        let profile = MCPClientProfile(name: "I01-A")
        let session = ExternalMCPSession(profile: profile, session: desktop)
        var run = Run()
        var sessionID: String?
        for (index, step) in steps.enumerated() {
            let call = step(sessionID)
            let answer = await session.router.handle(.object([
                "jsonrpc": .string("2.0"), "id": .number(Double(index + 1)), "method": .string("tools/call"),
                "params": .object(["name": .string(call.name), "arguments": decode(call.arguments)]),
            ])) ?? .null
            let result = answer["result"]
            let text = result["content"].array?.first?["text"].string ?? Self.sorted(answer)
            if index == 0 { sessionID = decode(text)["session"].string }
            run.outcomes.append(outcome(text: text, isError: result["isError"].bool == true))
            run.read.append(text)
        }
        await session.close()
        run.gestures = desktop.gestures
        run.calls = try await calls(in: archive)
        #expect(run.calls.allSatisfy { $0.hasPrefix("mcp mcp-\(profile.id.uuidString) ") }, "\(run.calls)")
        #expect(try secretAbsent(under: archive, "client") > 0, "client: no file in the archive")
        return run
    }

    @Test("I01-A: the same task through a worker's host and an external client's session: the same gestures, lifecycle, answers and calls, each call its composition's own")
    func sameTaskThroughBothCompositions() async throws {
        let root = URL.temporaryDirectory.appending(path: "braus-i01a-\(UUID().uuidString)",
                                                    directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = try await Self.worker(under: root)
        let client = try await Self.client(under: root)
        print("gestures:", worker.gestures)
        print("worker outcomes:", worker.outcomes.map { String($0.description.prefix(160)) })
        print("calls:", worker.calls)

        // Both ran every call; the task began and ended completed in each.
        for (label, run) in [("worker", worker), ("client", client)] {
            try #require(run.outcomes.count == Self.steps.count, "\(label): \(run.outcomes)")
            #expect(Self.decode(run.read[1])["status"].string == "begun", "\(label): \(run.read[1])")
            let ended = Self.decode(run.read[6])
            #expect(ended["status"].string == "ended" && ended["outcome"].string == "completed",
                    "\(label): \(run.read[6])")
            for index in [0, 2, 3, 4] {
                if case .refused(let words) = run.outcomes[index] {
                    Issue.record("\(label): call \(index + 1) refused: \(words)")
                }
            }
            if case .answer(let answered) = run.outcomes[5] {
                Issue.record("\(label): a stale session ID was answered: \(answered)")
            }
            for text in run.read {
                #expect(!text.contains(Self.secret) && !text.contains("P3x6"), "\(label): \(text.prefix(300))")
            }
        }
        // The same effect, outcomes and calls; each call its composition's own. Go pressed exactly once in each:
        // equality alone would not tell a stale call's effect present in both.
        for (label, run) in [("worker", worker), ("client", client)] {
            #expect(run.gestures.filter { $0 == "act|Go" }.count == 1, "\(label): \(run.gestures)")
        }
        #expect(client.gestures == worker.gestures, "\(client.gestures) against \(worker.gestures)")
        for (index, pair) in zip(client.outcomes, worker.outcomes).enumerated() {
            #expect(pair.0 == pair.1, "call \(index + 1): \(pair.0) against \(pair.1)")
        }
        #expect(worker.calls.allSatisfy { $0.hasPrefix("app worker-i01a ") }, "\(worker.calls)")
        let workers = worker.calls.map { $0.replacingOccurrences(of: "app worker-i01a ", with: "") }
        let clients = client.calls.map { $0.split(separator: " ", maxSplits: 2).dropFirst(2).joined() }
        #expect(!workers.isEmpty && clients == workers, "\(client.calls) against \(worker.calls)")
    }
}

/// A session double of the shop: not open until `open_session`, a new ID at each open, its archive in `directory`,
/// and a record of each gesture.
@MainActor
private final class EntryDesktop: AutomationSessionOperating {
    let directory: URL
    private(set) var id: UUID?
    private(set) var gestures: [String] = []
    private var application: String?
    private let scene = SceneSnapshot(
        bundleID: "test.shop", appName: "Synthetic Shop", windowTitle: "Shop",
        viewportPixelSize: ViewportPixelSize(width: 400, height: 200),
        elements: [
            SceneElement(id: "field|search", kind: .control, label: "Search",
                         bounds: NormalizedRect(x: 0.3, y: 0.05, width: 0.3, height: 0.04), role: "AXTextField",
                         labelOrigin: .description),
            SceneElement(id: "button|go", kind: .control, label: "Go",
                         bounds: NormalizedRect(x: 0.7, y: 0.05, width: 0.1, height: 0.04), role: "AXButton",
                         labelOrigin: .description),
        ]
    )

    init(directory: URL) { self.directory = directory }

    var memoryDirectory: URL? { directory }
    var memoryApplication: String? { application }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        gestures.append("open")
        self.application = "test.shop"
        id = UUID()
        return scene
    }

    func observe() async throws -> SceneSnapshot { scene }

    func act(target: String, verb: ActionVerb, section: String?,
             desiredState: ControlState?) async throws -> ActOutcome {
        gestures.append("act|\(target)")
        return ActOutcome(.foundActed, "\(target) pressed", scene: scene)
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        gestures.append("select|\(control)")
        return ActOutcome(.foundActed, "\(item) selected", scene: scene)
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        if case .typeText(_, let target, _) = input { gestures.append("type_text|\(target)") }
        else { gestures.append("deliver") }
        return ActOutcome(.foundActed, "delivered", scene: scene)
    }

    func applications(matching query: String?) async throws -> [ApplicationCandidate] { [] }

    func close() async {
        gestures.append("close")
        application = nil
        id = nil
    }
}

/// A model transport that issues the task's calls one per round, each from the session ID the `open_session` answer
/// gave, then answers; it keeps what each round was sent.
private final class StepTransport: ModelTransport {

    private let steps: [@Sendable (String?) -> (name: String, arguments: String)]
    private let kept = Mutex<[[TurnMessage]]>([])

    init(steps: [@Sendable (String?) -> (name: String, arguments: String)]) { self.steps = steps }

    var sent: [[TurnMessage]] { kept.withLock { $0 } }

    var streaming: StreamingSupport { .incremental }

    func complete(prompt: String, schema: Data,
                  timeout: TimeInterval) async throws -> (text: String, usage: ModelUsage) {
        throw ModelTransportError.streamingUnsupported("a scripted transport has no structured request")
    }

    func capabilities() async throws -> ModelCapabilities { ModelCapabilities(supportsTools: true) }

    func converse(
        _ messages: [TurnMessage],
        tools     : [ToolDefinition],
        timeout   : TimeInterval
    ) throws -> AsyncThrowingStream<TurnEvent, any Error> {
        kept.withLock { $0.append(messages) }
        let usage = ModelUsage(inputTokens: nil, outputTokens: nil, duration: .zero)
        let answered = messages.filter { $0.role == .tool }
        let session = answered.first { $0.call?.name == "open_session" }
            .flatMap { AppEntryCompositionsTests.decode($0.text)["session"].string }
        let events: [TurnEvent]
        if answered.count < steps.count {
            let step = steps[answered.count](session)
            events = [.toolCall(ToolCall(id: "call_\(answered.count)", name: step.name,
                                         arguments: Data(step.arguments.utf8))), .completed(usage)]
        } else {
            events = [.delta("Done."), .completed(usage)]
        }
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
