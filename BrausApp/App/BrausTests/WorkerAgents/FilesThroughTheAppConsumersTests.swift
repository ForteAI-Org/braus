//
//  FilesThroughTheAppConsumersTests.swift
//  Braus
//

import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import ModelTransports
import PerceptionCore
import Synchronization
import Testing
@testable import Braus

/// F06: the files adapter through the app's two real consumers of `AutomationTools`: a worker's `WorkerAgentHost`,
/// whose `ModelToolLoop` runs the calls a scripted model transport issues, and an external client's
/// `ExternalMCPSession`, through its router, as a client's bridge delivers them. Each is composed with the `adapters`
/// channel and, through the test hook, an adapter on a temporary root with a Trash of the test's; each drives a
/// session double with a real archive in a temporary folder. The Seat, a provider, the Mac's own adapters and the
/// person's files are not used.
///
/// The oracles: the bytes on the temporary root, read by the test after every step; the read's text in what the
/// model or the client read; each archive's `app_call`s under the task, with the adapter dispatch where the adapter
/// ran and none where the policy refused before it, their arguments carrying the marker and never the content; no
/// content in the worker's transcript events nor in any file of either archive; a refused overwrite with the bytes
/// unchanged. And the channel off: with the same hook, neither consumer offers `app_call`, a call to it is refused
/// before any effect, and a client without the desktop is refused by the router's protocol error.
@MainActor
@Suite("F06: the files adapter through the app's worker and external client", .serialized, .timeLimit(.minutes(2)))
struct FilesThroughTheAppConsumersTests {

    /// The texts no file of the test's machine holds, each with a sentinel of its own: the text written, the text an
    /// edit finds in it and the text it puts in its place. The model and the client must read the written text; no
    /// record, transcript line or archive file may hold any of the three.
    nonisolated static let written  = "braus f06 nonce one: sentinel-find-q7x2 stays in this line\n"
    nonisolated static let found    = "sentinel-find-q7x2"
    nonisolated static let replaced = "sentinel-replace-m4k9"
    nonisolated static let nonces   = ["f06 nonce", "sentinel-find-q7x2", "sentinel-replace-m4k9"]
    nonisolated static let note     = "P12/note.txt"

    nonisolated static func files(_ verb: String, _ arguments: [String: JSONValue]) -> JSONValue {
        .object(["app": .string("files"), "verb": .string(verb), "arguments": .object(arguments)])
    }

    /// The task's calls, in order, as the model would make them and as a client would send them.
    nonisolated static let steps: [(name: String, arguments: JSONValue)] = [
        ("memory_task", .object(["operation": .string("begin"), "goal": .string("Keep a note in a folder"),
                                 "remaining": .string("Keep a note in a folder")])),
        ("app_call", files("make_folder", ["path": .string("~/P12")])),
        ("app_call", files("write", ["path": .string("~/P12/note.txt"), "text": .string(written)])),
        ("app_call", files("read", ["path": .string("~/P12/note.txt")])),
        ("app_call", files("edit", ["path": .string("~/P12/note.txt"), "find": .string(found), "replace": .string(replaced)])),
        ("app_call", files("write", ["path": .string("~/P12/note.txt"), "text": .string("gone")])),
        ("app_call", files("move_to_trash", ["path": .string("~/P12/note.txt")])),
        ("memory_task", .object(["operation": .string("end"), "outcome": .string("completed")])),
    ]

    /// The bytes the note must hold after each step (nil: no file), by the step's index.
    nonisolated static var expected: [Data?] {
        let edited = Data(written.replacingOccurrences(of: found, with: replaced).utf8)
        return [nil, nil, Data(written.utf8), Data(written.utf8), edited, edited, edited, edited]
    }

    nonisolated static let outcomes = ["found_acted", "found_acted", "found_acted", "found_acted", "refused", "refused"]

    /// The call the channel-off cases make: a write under the root itself, whose parent exists, so a hook that
    /// wrongly enabled the adapters would leave the file.
    nonisolated static let offStep: (name: String, arguments: JSONValue) =
        ("app_call", files("write", ["path": .string("~/off.txt"), "text": .string(written)]))
    nonisolated static let offNote = "off.txt"

    nonisolated static func decode(_ text: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
    }

    /// A count behind a lock, shared by reference.
    final class Counter: Sendable {
        let value = Mutex(0)
        var count: Int { value.withLock { $0 } }
        func add() { value.withLock { $0 += 1 } }
    }

    /// A root with a Library, a Trash beside it, an archive folder, and the adapter on that root.
    final class Fixture {
        let base   : URL
        let home   : URL
        let trash  : URL
        let archive: URL
        let adapters: AppAdapters
        let trashed = Counter()

        init(_ label: String) throws {
            base    = URL.temporaryDirectory.appending(path: "braus-f06-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
            home    = base.appending(path: "Home", directoryHint: .isDirectory)
            trash   = base.appending(path: "Trash", directoryHint: .isDirectory)
            archive = base.appending(path: "Archive", directoryHint: .isDirectory)
            for folder in [home.appending(path: "Library"), trash, archive] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            let bin = trash, counted = trashed
            adapters = AppAdapters([FilesAdapter(root: home, trash: { url in
                counted.add()
                let moved = bin.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: moved)
                return moved
            })])
        }

        /// Runs `body` on a fresh fixture and ends it, whether `body` returns or throws.
        static func with(_ label: String, _ body: (Fixture) async throws -> Void) async throws {
            let fixture = try Fixture(label)
            do { try await body(fixture) } catch {
                await fixture.end()
                throw error
            }
            await fixture.end()
        }

        func bytes(_ path: String) -> Data? { try? Data(contentsOf: home.appending(path: path)) }

        var folderExists: Bool { FileManager.default.fileExists(atPath: home.appending(path: "P12").path) }

        func end() async {
            await MemoryService.shared(for: archive).close()
            try? FileManager.default.removeItem(at: base)
        }
    }

    /// What the archive holds of each `app_call`, read with the system's `sqlite3` read-only once the archive is
    /// closed: the producer's source, the status, the adapter dispatch when one was noted, the task, and the
    /// arguments as kept.
    struct Recorded: Equatable {
        let source   : String
        let stream   : String
        let status   : String
        let dispatch : String
        let task     : String
        let arguments: String
    }

    static func recorded(in archive: URL) async throws -> [Recorded] {
        await MemoryService.shared(for: archive).close()
        // A call the router refused before the tools never opened the memory, and closing one makes no database: no
        // file is no event. A database that is there is read, and a read that fails is a failure of the test.
        guard FileManager.default.fileExists(atPath: archive.appending(path: "memory.sqlite").path) else { return [] }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", archive.appending(path: "memory.sqlite").path, """
            SELECT e.source || '|' || e.source_stream_id || '|' || a.execution_status || '|' || ifnull(d.adapter || '.' || d.verb, '-') || '|'
                   || ifnull(r.task_id, '-') || '|'
                   || ifnull((SELECT o.text_value FROM memory_operation_arguments o
                              WHERE o.event_id = a.event_id AND o.argument_name = 'arguments'), '-')
            FROM memory_events e JOIN memory_agent_actions a ON a.event_id = e.event_id
            LEFT JOIN memory_call_adapter_dispatches d ON d.event_id = a.event_id
            LEFT JOIN memory_task_call_revisions r ON r.event_id = a.event_id
            WHERE a.tool_kind = 'app_call' ORDER BY e.local_order;
            """]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "sqlite3 could not read the archive")
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { line in
            let parts = line.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            func part(_ index: Int) -> String { parts.count > index ? parts[index] : "" }
            return Recorded(source: part(0), stream: part(1), status: part(2), dispatch: part(3), task: part(4), arguments: part(5))
        }
    }

    /// The files under `directory` holding one of the nonces, by name; read from any context, the model's loop included.
    /// A file the memory makes and removes while it works (its backup's partial files) may be gone between the
    /// enumeration and the read: gone (`ENOENT`, and nothing else), it holds nothing; any other error is thrown.
    nonisolated static func filesHoldingContent(under directory: URL) throws -> [String] {
        var holding: [String] = []
        let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = walk?.nextObject() as? URL {
            let regular: Bool
            do { regular = try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            catch let error where vanished(error) { continue }
            guard regular else { continue }
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch let error where vanished(error) { continue }
            for nonce in nonces where data.range(of: Data(nonce.utf8)) != nil { holding.append("\(file.lastPathComponent): \(nonce)") }
        }
        return holding
    }

    /// Whether an error says the file is no longer there: POSIX `ENOENT`, or Cocoa's no-such-file, itself or underneath.
    nonisolated static func vanished(_ error: any Error) -> Bool {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain { return failure.code == Int(ENOENT) }
        guard failure.domain == NSCocoaErrorDomain else { return false }
        if failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError { return true }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError { return vanished(underlying) }
        return false
    }

    /// The record of the six `app_call`s checked against the steps: completed; dispatched to the adapter unless the
    /// policy refused the Trash before it; under one task; the arguments with the marker and without the content.
    static func check(_ calls: [Recorded], source: String, stream: String, task: String?, _ label: String) {
        let verbs = ["make_folder", "write", "read", "edit", "write", "move_to_trash"]
        #expect(calls.count == verbs.count, "\(label): \(calls)")
        #expect(task != nil && task != "", "\(label): the begin answer named no task")
        guard calls.count == verbs.count else { return }
        for (call, verb) in zip(calls, verbs) {
            #expect(call.source == source && call.stream == stream && call.status == "completed", "\(label) \(verb): \(call)")
            #expect(call.dispatch == (verb == "move_to_trash" ? "-" : "files.\(verb)"), "\(label) \(verb): \(call)")
            #expect(call.task == task, "\(label) \(verb): \(call.task) against \(task ?? "nil")")
            for nonce in nonces { #expect(!call.arguments.contains(nonce), "\(label) \(verb): \(call.arguments)") }
            #expect(!call.arguments.contains(replaced), "\(label) \(verb): \(call.arguments)")
        }
        #expect(calls[1].arguments.contains(ValueMinimization.marker) && calls[1].arguments.contains(#""path":"~/P12/note.txt""#),
                "\(label): \(calls[1].arguments)")
        #expect(calls[2].arguments == #"{"path":"~/P12/note.txt"}"#, "\(label): \(calls[2].arguments)")
        #expect(calls[3].arguments.contains(ValueMinimization.marker), "\(label): \(calls[3].arguments)")
    }

    final class Transcript: @unchecked Sendable {
        let lines = Mutex<[String]>([])
        var text: String { lines.withLock { $0.joined(separator: "\n") } }
    }

    // MARK: The worker

    /// A model transport that issues the task's calls one per round and keeps what each round was sent; before each
    /// round it hands the number of calls answered so far to `beforeRound`, where the test reads the disk.
    final class StepTransport: ModelTransport {
        private let steps: [(name: String, arguments: JSONValue)]
        private let kept = Mutex<[[TurnMessage]]>([])
        private let beforeRound: @Sendable (Int) -> Void

        init(steps: [(name: String, arguments: JSONValue)], beforeRound: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.steps = steps
            self.beforeRound = beforeRound
        }

        var sent: [[TurnMessage]] { kept.withLock { $0 } }
        var streaming: StreamingSupport { .incremental }

        func complete(prompt: String, schema: Data, timeout: TimeInterval) async throws -> (text: String, usage: ModelUsage) {
            throw ModelTransportError.streamingUnsupported("a scripted transport has no structured request")
        }

        func capabilities() async throws -> ModelCapabilities { ModelCapabilities(supportsTools: true) }

        func converse(_ messages: [TurnMessage], tools: [ToolDefinition],
                      timeout: TimeInterval) throws -> AsyncThrowingStream<TurnEvent, any Error> {
            kept.withLock { $0.append(messages) }
            let answered = messages.filter { $0.role == .tool }.count
            beforeRound(answered)
            let usage = ModelUsage(inputTokens: nil, outputTokens: nil, duration: .zero)
            let events: [TurnEvent]
            if answered < steps.count {
                let step = steps[answered]
                let arguments = (try? JSONEncoder().encode(step.arguments)) ?? Data("{}".utf8)
                events = [.toolCall(ToolCall(id: "call_\(answered)", name: step.name, arguments: arguments)), .completed(usage)]
            } else {
                events = [.delta("Done."), .completed(usage)]
            }
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    /// A worker's host on the fixture, with the given channels and the hook's adapters.
    static func worker(_ fixture: Fixture, channels: AutomationChannels, transport: StepTransport) -> WorkerAgentHost {
        let host = WorkerAgentHost(workingDirectory: fixture.base.appending(path: "work"),
                                   bridgeExecutable: URL(filePath: "/usr/bin/false"),
                                   session: { FilesDesktop(directory: fixture.archive) },
                                   channels: channels,
                                   agents: { _ in throw AutomationFailure("no command line in this test") },
                                   transports: { _ in transport },
                                   adapters: fixture.adapters)
        host.callProducer = CallProducer(source: .app, streamID: "worker-f06", traceID: "message-1", messageRef: "message-1")
        return host
    }

    /// One turn of the worker, its tool events kept; what the turn threw, if it did.
    static func turn(_ host: WorkerAgentHost, events: Transcript) async -> String? {
        do {
            try await host.run(prompt: "Keep a note in a folder.",
                               selection: ModelSelection(provider: .ollama, model: "qwen3:8b", effort: .high),
                               sessionID: nil, role: nil) { event in
                if case .tool(let line) = event { events.lines.withLock { $0.append(line) } }
            }
            try await host.close()
            return nil
        } catch {
            try? await host.close()
            return String(describing: error)
        }
    }

    @Test("F06-A: the worker, with the adapters: the model's calls make the folder, write, read, edit and are refused twice; the disk read after each step; the archive and the transcript without the content")
    func worker() async throws {
        try await Fixture.with("worker") { fixture in
            let home = fixture.home, archive = fixture.archive
            let seen = Mutex<[Int: Data?]>([:]), leaks = Mutex<[String]>([])
            let transport = StepTransport(steps: Self.steps) { answered in
                seen.withLock { $0[answered] = try? Data(contentsOf: home.appending(path: Self.note)) }
                // The archive as it is now, open, its WAL included: nothing of the content in any of its files.
                do {
                    let holding = try Self.filesHoldingContent(under: archive)
                    leaks.withLock { $0 += holding.map { "round \(answered): \($0)" } }
                } catch {
                    leaks.withLock { $0.append("round \(answered): the scan failed: \(error)") }
                }
            }
            let events = Transcript()
            let host = Self.worker(fixture, channels: .adapters, transport: transport)
            #expect(host.servedTools.compactMap { $0["name"].string }.contains("app_call"))
            let threw = await Self.turn(host, events: events)
            #expect(threw == nil, "\(threw ?? "")")
            // The disk after each step, read by the test before the model's next call; and at the end.
            for (index, expected) in Self.expected.enumerated() {
                #expect(seen.withLock { $0[index + 1] ?? nil } == expected, "after step \(index + 1)")
            }
            #expect(fixture.bytes(Self.note) == Self.expected.last!, "at the end")
            #expect(fixture.trashed.count == 0, "the Trash was never asked")
            // What the model read: the text in the read's answer, the refusals as outcomes.
            let answered = (transport.sent.last ?? []).filter { $0.role == .tool }
            try #require(answered.count == Self.steps.count, "\(answered.map(\.text))")
            let outcomes = answered.map { Self.decode($0.text)["outcome"].string ?? "" }
            #expect(Array(outcomes[1...6]) == Self.outcomes, "\(outcomes)")
            #expect(Self.decode(answered[3].text)["result"]["text"] == .string(Self.written), "the model reads the text: \(answered[3].text)")
            #expect(answered[6].text.contains("destructive actions are off"), "\(answered[6].text)")
            // The transcript the worker reports, and the archive: without the content.
            for nonce in Self.nonces { #expect(!events.text.contains(nonce), "the transcript holds \(nonce)") }
            #expect(events.text.contains("app_call") && events.text.contains(ValueMinimization.marker), "\(events.text.prefix(400))")
            #expect(leaks.withLock { $0 }.isEmpty, "the open archive held content: \(leaks.withLock { $0 })")
            let calls = try await Self.recorded(in: fixture.archive)
            Self.check(calls, source: "app", stream: "worker-f06", task: Self.decode(answered[0].text)["task"].string, "worker")
            #expect(try Self.filesHoldingContent(under: fixture.archive).isEmpty, "the closed archive")
        }
    }

    @Test("F06-A, the channel off: the same hook without the adapters channel: the worker offers no app_call, the model's call is refused, nothing on the disk, no content in the transcript or the archive")
    func workerWithoutTheChannel() async throws {
        try await Fixture.with("worker-off") { fixture in
            let transport = StepTransport(steps: [Self.offStep])
            let events = Transcript()
            let host = Self.worker(fixture, channels: [], transport: transport)
            let served = host.servedTools.compactMap { $0["name"].string }
            #expect(!served.contains("app_call") && !served.contains("app_capabilities"), "\(served)")
            let threw = await Self.turn(host, events: events)
            let answered = (transport.sent.last ?? []).filter { $0.role == .tool }
            #expect(threw != nil || (!answered.isEmpty && answered.allSatisfy(\.isError)), "refused: \(threw ?? "") \(answered.map(\.text))")
            #expect(fixture.bytes(Self.offNote) == nil && !fixture.folderExists, "nothing written")
            for nonce in Self.nonces {
                #expect(!events.text.contains(nonce), "the transcript holds \(nonce)")
                #expect(!(threw ?? "").contains(nonce) && answered.allSatisfy { !$0.text.contains(nonce) })
            }
            let calls = try await Self.recorded(in: fixture.archive)
            #expect(calls.allSatisfy { call in call.dispatch == "-" && Self.nonces.allSatisfy { !call.arguments.contains($0) } }, "\(calls)")
            #expect(try Self.filesHoldingContent(under: fixture.archive).isEmpty)
        }
    }

    // MARK: The external client

    /// One `tools/call` through the session's router, as a client's bridge delivers it: the answer's text, its error
    /// mark, and the whole answer.
    static func call(_ session: ExternalMCPSession, _ step: (name: String, arguments: JSONValue),
                     id: Int) async -> (text: String, isError: Bool, answer: JSONValue) {
        let answer = await session.router.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/call"),
            "params": .object(["name": .string(step.name), "arguments": step.arguments]),
        ])) ?? .null
        let result = answer["result"]
        return (result["content"].array?.first?["text"].string ?? "", result["isError"].bool == true, answer)
    }

    static func listed(_ session: ExternalMCPSession) async -> [String] {
        let answer = await session.router.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(0), "method": .string("tools/list"), "params": .object([:]),
        ])) ?? .null
        return answer["result"]["tools"].array?.compactMap { $0["name"].string } ?? []
    }

    @Test("F06-B: the external client, with the adapters: the same calls through its router, the disk read after each; the archive's calls the client's own, without the content")
    func client() async throws {
        try await Fixture.with("client") { fixture in
            let profile = MCPClientProfile(name: "F06")
            let session = ExternalMCPSession(profile: profile, session: FilesDesktop(directory: fixture.archive),
                                             channels: .adapters, adapters: fixture.adapters)
            let names = await Self.listed(session)
            #expect(names.contains("app_call") && names.contains("app_capabilities"), "\(names)")
            var texts: [String] = []
            for (index, step) in Self.steps.enumerated() {
                let answered = await Self.call(session, step, id: index + 1)
                texts.append(answered.text)
                #expect(fixture.bytes(Self.note) == Self.expected[index], "after step \(index + 1): \(answered.text)")
                #expect(try Self.filesHoldingContent(under: fixture.archive).isEmpty, "the open archive after step \(index + 1)")
            }
            await session.close()
            let outcomes = texts.map { Self.decode($0)["outcome"].string ?? "" }
            #expect(Array(outcomes[1...6]) == Self.outcomes, "\(outcomes)")
            #expect(Self.decode(texts[3])["result"]["text"] == .string(Self.written), "the client reads the text: \(texts[3])")
            #expect(fixture.trashed.count == 0, "the Trash was never asked")
            let calls = try await Self.recorded(in: fixture.archive)
            Self.check(calls, source: "mcp", stream: "mcp-" + profile.id.uuidString, task: Self.decode(texts[0])["task"].string, "client")
            #expect(try Self.filesHoldingContent(under: fixture.archive).isEmpty, "the closed archive")
        }
    }

    @Test("F06-B, the channel off and the desktop denied: the same hook without the adapters channel offers no app_call and the router refuses the call; a profile without the desktop is refused by the router's protocol error before anything; nothing on the disk, no content kept")
    func clientWithoutTheChannelOrTheDesktop() async throws {
        try await Fixture.with("client-off") { fixture in
            let performed = Mutex(0)
            let perform: ExternalMCPSession.Performing = { body in
                performed.withLock { $0 += 1 }
                return try await body()
            }
            let off = ExternalMCPSession(profile: MCPClientProfile(name: "F06 off"), session: FilesDesktop(directory: fixture.archive),
                                         channels: [], perform: perform, adapters: fixture.adapters)
            let names = await Self.listed(off)
            #expect(!names.contains("app_call") && !names.contains("app_capabilities"), "\(names)")
            let refused = await Self.call(off, Self.offStep, id: 1)
            #expect(refused.answer["error"]["code"] == .number(-32602) && refused.answer["result"] == .null,
                    "the router's protocol error: \(refused.answer)")
            await off.close()

            let denied = ExternalMCPSession(profile: MCPClientProfile(name: "No desktop", desktop: false),
                                            session: FilesDesktop(directory: fixture.archive), channels: .adapters,
                                            perform: perform, adapters: fixture.adapters)
            #expect(await Self.listed(denied).isEmpty)
            let deniedAnswer = await Self.call(denied, Self.offStep, id: 2)
            #expect(deniedAnswer.answer["error"]["code"] == .number(-32602) && deniedAnswer.answer["result"] == .null,
                    "\(deniedAnswer.answer)")
            await denied.close()

            #expect(performed.withLock { $0 } == 0, "nothing reached the tools")
            #expect(fixture.bytes(Self.offNote) == nil && !fixture.folderExists, "nothing written")
            let calls = try await Self.recorded(in: fixture.archive)
            #expect(calls.allSatisfy { $0.dispatch == "-" }, "\(calls)")
            for answer in [refused.answer, deniedAnswer.answer] {
                let text = String(describing: answer)
                for nonce in Self.nonces { #expect(!text.contains(nonce), "\(text)") }
            }
            #expect(try Self.filesHoldingContent(under: fixture.archive).isEmpty)
        }
    }
}

/// A session double with an archive in `directory` and nothing to drive: the adapters need no app.
@MainActor
private final class FilesDesktop: AutomationSessionOperating {
    let directory: URL
    private(set) var id: UUID?

    init(directory: URL) { self.directory = directory }

    var memoryDirectory: URL? { directory }
    var memoryApplication: String? { nil }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        throw AutomationFailure("this double opens nothing")
    }
    func observe() async throws -> SceneSnapshot { throw AutomationFailure("nothing is open") }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        ActOutcome(.refused, "nothing is open")
    }
    func select(control: String, item: String) async throws -> ActOutcome { ActOutcome(.refused, "nothing is open") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { ActOutcome(.refused, "nothing is open") }
    func applications(matching query: String?) async throws -> [ApplicationCandidate] { [] }
    func close() async { id = nil }
}
