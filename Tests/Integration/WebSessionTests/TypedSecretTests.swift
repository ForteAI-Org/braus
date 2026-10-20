//
//  TypedSecretTests.swift
//  Braus
//

import AutomationMCP
@testable import AutomationRuntime
import ChatCore
import CLIProviders
import CoreGraphics
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing
import WebDriver
@testable import WebDriving
import WebSession

/// W1 typed secrets through the tools (T1 to T13 of plan/W1-typed-secrets-proposal.md v3): the production
/// `AutomationTools` and `CallRecorder` over a `SyntheticWebSession`, with a memory in a temporary directory. A
/// text is withheld before the call's first write unless a fresh classification attests an ordinary field, and
/// then from every record, transcript line, answer and error of that call; an ordinary text is kept. Each text is
/// looked for as written and as JSON escapes it, in the transcript's and the answers' decoded values and in every
/// byte of the archive, and so is its distinctive fragment.
@MainActor
@Suite("Typed secrets through the tools (W1)", .serialized)
struct TypedSecretTests {

    static let fields = TextTargetWebTests.fields

    /// What every typed sentinel holds, so no piece of one may stay visible.
    nonisolated static let fragment = "Q7z9"

    /// Texts whose JSON form differs from their own: a quote, a backslash, a line break (which the engine
    /// refuses to type, after the call recorded it).
    nonisolated static let variants = ["typed-\(fragment)", "ty\"ped-\(fragment)", "ty\\ped-\(fragment)", "typed\n\(fragment)"]

    final class Transcript { var lines: [String] = [] }

    struct Harness {
        let root      : URL
        let knowledge : URL?
        let session   : SyntheticWebSession
        let tools     : AutomationTools
        let transcript: Transcript
        let id        : String
    }

    static func harness(memory: Bool = true, fields: [SyntheticPage.Field] = fields) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "braus-w1t-\(UUID().uuidString)", directoryHint: .isDirectory)
        let knowledge = root.appending(path: "Knowledge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        let session = await SyntheticWebSession.make(fields: fields, knowledge: memory ? knowledge : nil)
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: .app, streamID: "w1t-\(UUID().uuidString)", traceID: "m1", messageRef: "m1")
        let transcript = Transcript()
        tools.record = { transcript.lines.append($0) }
        _ = try await tools.call("open_session", .object(["app": .string("web:fixture.test")]))
        let id = try #require(session.id?.uuidString)
        return Harness(root: root, knowledge: memory ? knowledge : nil, session: session, tools: tools,
                       transcript: transcript, id: id)
    }

    @discardableResult
    static func call(_ harness: Harness, _ name: String, _ arguments: [String: LocalMCP.JSONValue]) async throws -> LocalMCP.JSONValue {
        var arguments = arguments
        arguments["session"] = .string(harness.id)
        return try await harness.tools.call(name, .object(arguments))
    }

    /// Closes the session and the memory, so every write is in the archive's files.
    static func finish(_ harness: Harness) async {
        await harness.session.close()
        guard let knowledge = harness.knowledge else { return }
        let memory = MemoryService.shared(for: knowledge)
        _ = await memory.flush(within: .seconds(10))
        await memory.close()
        MemoryService.forget(knowledge)
    }

    static func remove(_ harness: Harness) { try? FileManager.default.removeItem(at: harness.root) }

    /// Every string of a JSON value, keys included; a string that is JSON itself (a tool result's text) decoded too.
    static func strings(in value: LocalMCP.JSONValue) -> [String] {
        switch value {
            case .string(let text):
                if let inner = try? JSONDecoder().decode(LocalMCP.JSONValue.self, from: Data(text.utf8)),
                   inner.object != nil || inner.array != nil {
                    return [text] + strings(in: inner)
                }
                return [text]
            case .array(let items) : return items.flatMap(strings(in:))
            case .object(let items): return Array(items.keys) + items.values.flatMap(strings(in:))
            default                : return []
        }
    }

    /// A transcript line and the values of its JSON part, decoded.
    static func values(of line: String) -> [String] {
        guard let start = line.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let value = try? JSONDecoder().decode(LocalMCP.JSONValue.self, from: Data(line[start...].utf8))
        else { return [line] }
        return [line] + strings(in: value)
    }

    /// The forms a text takes in bytes: as written, and as a JSON string escapes it.
    static func forms(of text: String) throws -> [String] {
        let encoded = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        return Array(Set([text, String(encoded.dropFirst().dropLast())]))
    }

    /// `text`, its JSON form and the fragment are nowhere in the transcript, the answers or the archive.
    static func expectWithheld(_ text: String, in harness: Harness, answers: [LocalMCP.JSONValue] = [],
                               sourceLocation: SourceLocation = #_sourceLocation) throws {
        for needle in try forms(of: text) + [fragment] {
            for line in harness.transcript.lines {
                #expect(!values(of: line).contains { $0.contains(needle) }, "transcript holds \(needle): \(line)",
                        sourceLocation: sourceLocation)
            }
            for answer in answers {
                #expect(!strings(in: answer).contains { $0.contains(needle) }, "answer holds \(needle)",
                        sourceLocation: sourceLocation)
            }
            if let knowledge = harness.knowledge {
                #expect(try SecureFieldTests.files(in: knowledge, holding: needle).isEmpty, "archive holds \(needle)",
                        sourceLocation: sourceLocation)
            }
        }
    }

    /// The archive's declared gaps, as `argument_name:reason` (the location kind for another place).
    static func gaps(_ harness: Harness) throws -> [String] {
        let url = try #require(harness.knowledge).appendingPathComponent("memory.sqlite")
        let connection = try SQLiteConnection(path: url.path, readOnly: true)
        defer { connection.close() }
        return try connection.query(
            "SELECT ifnull(argument_name, location_kind) || ':' || reason FROM memory_value_redactions ORDER BY redaction_id"
        ) { try $0.text(0) ?? "" }
    }

    static func status(of answer: LocalMCP.JSONValue) -> String? {
        guard let text = answer["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(LocalMCP.JSONValue.self, from: Data(text.utf8)) else { return nil }
        return value["status"].string
    }

    // MARK: T1, T2: secure and ordinary

    @Test("T1: type_text into a password field under a neutral label: withheld everywhere, a secure_field gap",
          arguments: variants)
    func secureField(text: String) async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        let answer = try await Self.call(harness, "type_text", ["target": .string("Accesso"), "text": .string(text)])
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness, answers: [answer])
        let gaps = try Self.gaps(harness)
        #expect(gaps.contains("text:secure_field"), "\(gaps)")
    }

    @Test("T2: type_text into an attested ordinary field: the text is kept, with no gap, so the memory learns it")
    func ordinaryKept() async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        let answer = try await Self.call(harness, "type_text", ["target": .string("Nome"), "text": .string("Grace Hopper")])
        #expect(Self.status(of: answer) == "found_acted", "\(answer)")
        await Self.finish(harness)
        #expect(try !SecureFieldTests.files(in: try #require(harness.knowledge), holding: "Grace Hopper").isEmpty)
        #expect(try !Self.gaps(harness).contains { $0.hasPrefix("text:") })
    }

    // MARK: T3, T4, T9: freshness and identity

    @Test("T3: the model read the field as ordinary, then the page made it a password field: the fresh classification withholds")
    func staleScene() async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        let observed = try await Self.call(harness, "observe", ["full": .bool(true)])
        #expect(Self.strings(in: observed).contains { $0.contains("Nome") })
        harness.session.page.change([.setType(12, "password")])
        let text = "stale-\(Self.fragment)"
        let answer = try await Self.call(harness, "type_text", ["target": .string("Nome"), "text": .string(text)])
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness, answers: [answer])
        #expect(try Self.gaps(harness).contains("text:secure_field"))
    }

    @Test("T4, T9: the field changes between the classification and the dispatch, same name, role and place: refused, nothing typed",
          arguments: [SyntheticPage.Change.replace(12, by: 52), .replace(12, by: 52, type: "password"), .setType(12, "password")])
    func changedBeforeDispatch(change: SyntheticPage.Change) async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        harness.session.page.schedule([change], afterScene: harness.session.page.scenesRead + 1)
        let answer = try await Self.call(harness, "type_text", ["target": .string("Nome"), "text": .string("Grace")])
        #expect(Self.status(of: answer) == "refused", "\(answer)")
        #expect(harness.session.page.value(of: 12) != "Grace" && harness.session.page.value(of: 52) != "Grace")
        await Self.finish(harness)
    }

    // MARK: T5, T8: unclassifiable

    @Test("T5: a target that names no field: withheld as unclassified_target before the engine refuses it")
    func absentTarget() async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        let text = "missing-\(Self.fragment)"
        let answer = try await Self.call(harness, "type_text", ["target": .string("Missing"), "text": .string(text)])
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness, answers: [answer])
        #expect(try Self.gaps(harness).contains("text:unclassified_target"))
    }

    @Test("T8: a session that classifies nothing (the default): every typed text is withheld")
    func defaultConformer() async throws {
        let probe = DesktopProbe()
        let tools = AutomationTools(session: probe)
        let transcript = Transcript()
        tools.record = { transcript.lines.append($0) }
        _ = try await tools.call("open_session", .object(["app": .string("com.example.App")]))
        let id = try #require(probe.id?.uuidString)
        let text = "probe-\(Self.fragment)"
        await #expect(throws: (any Error).self) {
            _ = try await tools.call("type_text", .object(["session": .string(id), "target": .string("Name"), "text": .string(text)]))
        }
        #expect(!transcript.lines.contains { Self.values(of: $0).contains { $0.contains(Self.fragment) } }, "\(transcript.lines)")
    }

    // MARK: T6: batch

    @Test("T6: a batch: its first text step is classified; a later one, after an effect, is withheld in the plan",
          arguments: variants)
    func batch(text: String) async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        let answer = try await Self.call(harness, "batch", ["steps": .array([
            .object(["operation": .string("type_text"), "target": .string("Nome"), "text": .string("Grace Hopper")]),
            .object(["operation": .string("type_text"), "target": .string("Nome"), "text": .string(text)]),
        ])])
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness, answers: [answer])
        #expect(try !SecureFieldTests.files(in: try #require(harness.knowledge), holding: "Grace Hopper").isEmpty,
                "the first step's ordinary text is kept")
        #expect(try Self.gaps(harness).contains("text:unclassified_target"))
    }

    // MARK: T7: insert_text

    @Test("T7: insert_text at a focused password field: its text and expected value withheld as secure_field")
    func insertIntoSecureFocus() async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        harness.session.page.run("document.activeElement = __fields[0];")
        let text = "inserted-\(Self.fragment)"
        let answer = try await Self.call(harness, "insert_text", ["text": .string(text), "expected_value": .string(text)])
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness, answers: [answer])
        let gaps = try Self.gaps(harness)
        #expect(gaps.contains("text:secure_field") && gaps.contains("expected_value:secure_field"), "\(gaps)")
    }

    @Test("T7: insert_text at a focus the page cannot attest (a frame it cannot read): withheld as unclassified_target")
    func insertIntoUnknownFocus() async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        harness.session.page.run("document.activeElement = { tagName: 'IFRAME', contentDocument: null };")
        let text = "framed-\(Self.fragment)"
        let answer = try await Self.call(harness, "insert_text", ["text": .string(text)])
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness, answers: [answer])
        #expect(try Self.gaps(harness).contains("text:unclassified_target"))
    }

    // MARK: T10, T11, T13: no memory, errors, cancellation, the last output

    @Test("T10: with no memory, nothing is recorded and the transcript still withholds", arguments: variants)
    func noMemory(text: String) async throws {
        let harness = try await Self.harness(memory: false)
        defer { Self.remove(harness) }
        let answer = try await Self.call(harness, "type_text", ["target": .string("Accesso"), "text": .string(text)])
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness, answers: [answer])
    }

    @Test("T11: a delivery that fails with the text in its error: the transcript and the thrown error withhold it",
          arguments: variants)
    func failureCarriesTheText(text: String) async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        harness.session.failure = AutomationFailure("could not type \(text) into the field")
        var thrown = ""
        do {
            _ = try await Self.call(harness, "type_text", ["target": .string("Accesso"), "text": .string(text)])
        } catch {
            thrown = String(describing: error)
        }
        #expect(!thrown.isEmpty, "the call failed")
        #expect(!thrown.contains(Self.fragment), "\(thrown)")
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness)
    }

    @Test("T11: a call cancelled while it delivers: the transcript and the archive withhold its text")
    func cancelledCall() async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        harness.session.waitsBeforeDelivering = true
        let text = "cancelled-\(Self.fragment)"
        let tools = harness.tools, id = harness.id
        let call = Task { @MainActor in
            try await tools.call("type_text", .object(["session": .string(id), "target": .string("Accesso"),
                                                       "text": .string(text)]))
        }
        for _ in 0..<500 where !harness.transcript.lines.contains(where: { $0.hasPrefix("→ type_text") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        call.cancel()
        let result = await call.result
        #expect(throws: CancellationError.self) { try result.get() }
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness)
    }

    // MARK: T14: a secure field's text protects the later calls

    @Test("T14: a text typed into a password field, then shown by the page in an ordinary field: a later observe's answer and transcript, and a later call's error, withhold it",
          arguments: variants)
    func secureTextLater(text: String) async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        _ = try await Self.call(harness, "type_text", ["target": .string("Accesso"), "text": .string(text)])
        // The page puts the same text where the scene shows it: an ordinary field's value.
        harness.session.page.run("__fields[1].value = \(SyntheticPage.literal(text));")
        let later = harness.transcript.lines.count
        let observed = try await Self.call(harness, "observe", ["full": .bool(true)])
        harness.session.failure = AutomationFailure("the field holds \(text) already")
        var thrown = ""
        do { _ = try await Self.call(harness, "type_text", ["target": .string("Nome"), "text": .string("Grace")]) }
        catch { thrown = String(describing: error) }
        #expect(!thrown.isEmpty && !thrown.contains(Self.fragment), "\(thrown)")
        let laterLines = Array(harness.transcript.lines.dropFirst(later))
        #expect(laterLines.contains { $0.hasPrefix("← observe") })
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness, answers: [observed])
    }

    // MARK: M07: a command line's own web search

    @Test("M07: a text typed into a password field, then put in the agent's own web search and, percent-encoded, in an address it reads: the host's records withhold it, and a credential in an address; an ordinary query and address are kept",
          arguments: variants + ["ty ped-\(fragment)"])
    func ownWebSearch(text: String) async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        _ = try await Self.call(harness, "type_text", ["target": .string("Accesso"), "text": .string(text)])
        // The records the host writes of the command line's own web tools, through these tools' withholding.
        let token = "ghp_Synthetic0M07" + String(repeating: "x", count: 24)
        // The text as an address carries it: every character but letters and digits percent-encoded, and in a
        // query's form encoding a space as `+`.
        let encoded = try #require(text.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let ordinary = "https://fixture.test/a%20b?q=caf%C3%A9+cr%C3%A8me"
        var records = WebToolRecords()
        func fetch(_ address: String) -> ProviderEvent {
            .web(id: nil, kind: .fetch, detail: address, phase: .finished(failed: false))
        }
        let lines = try [
            ProviderEvent.web(id: "w1", kind: .search, detail: "account \(text) reset", phase: .started),
            fetch("https://fixture.test/in?token=\(token)"),
            fetch("https://fixture.test/find?q=\(encoded)"),
            fetch("https://fixture.test/find?q=\(encoded.replacingOccurrences(of: "%20", with: "+"))&page=2"),
            fetch(ordinary),
            .web(id: nil, kind: .search, detail: "swift 6.4 release notes", phase: .finished(failed: false)),
        ].flatMap { try records.lines(for: $0, withholding: harness.tools.withheld) }
        await Self.finish(harness)
        for needle in try Self.forms(of: text) + [Self.fragment, token] {
            #expect(!lines.contains { Self.values(of: $0).contains { $0.contains(needle) } },
                    "\(needle): \(lines)")
        }
        #expect(lines.contains(#"→ web_search {"query":"swift 6.4 release notes"}"#), "\(lines)")
        #expect(lines.contains("→ web_fetch {\"url\":\"\(ordinary)\"}"), "\(lines)")
    }

    // MARK: T15: a session that attests nothing, a long text

    @Test("T15: a long text through a session that attests nothing: neither it nor the answer's 59-character prefix of it reaches the answer, the transcript or the archive",
          arguments: [true, false])
    func longTextUnattested(passesWithheld: Bool) async throws {
        let harness = try await Self.harness()
        defer { Self.remove(harness) }
        harness.session.classifies = false
        harness.session.passesWithheld = passesWithheld
        let long = "Lungo-" + String(repeating: "abcdefghij", count: 8) + "-\(Self.fragment)"
        let answer = try await Self.call(harness, "type_text", ["target": .string("Nome"), "text": .string(long)])
        #expect(harness.session.page.value(of: 12) == long, "the text did reach the field")
        await Self.finish(harness)
        try Self.expectWithheld(long, in: harness, answers: [answer])
        let prefix = String(long.prefix(59))
        for line in harness.transcript.lines {
            #expect(!Self.values(of: line).contains { $0.contains(prefix) }, "transcript holds the prefix: \(line)")
        }
        #expect(!Self.strings(in: answer).contains { $0.contains(prefix) }, "the answer holds the prefix")
        #expect(try SecureFieldTests.files(in: try #require(harness.knowledge), holding: prefix).isEmpty, "the archive holds the prefix")
        #expect(try Self.gaps(harness).contains("text:unclassified_target"))
    }

    // MARK: T12: concurrency

    @Test("T12: while a call that withholds a text is held inside its scope, a second call's ordinary scene keeps that text, and so does a later call")
    func concurrentCalls() async throws {
        let milano = "Milano-\(Self.fragment)"
        let fields = [Self.fields[0], SyntheticPage.Field(backendID: 12, type: "text", name: "Nome", value: milano,
                                                          box: CGRect(x: 100, y: 200, width: 300, height: 30))]
        let harness = try await Self.harness(fields: fields)
        defer { Self.remove(harness) }
        let gate = SyntheticWebSession.Gate()
        harness.session.gate = gate
        let typed = Task { @MainActor in
            try await Self.call(harness, "type_text", ["target": .string("Missing"), "text": .string(milano)])
        }
        // The rendezvous: the typing call is held in its delivery, inside its scope, before the second call starts.
        await gate.untilHeld()
        harness.session.gate = nil
        let observing = try await Self.call(harness, "observe", ["full": .bool(true)])
        #expect(Self.strings(in: observing).contains { $0.contains(milano) }, "the concurrent observation keeps the field's value")
        gate.release()
        let typing = try await typed.value
        #expect(!Self.strings(in: typing).contains { $0.contains(milano) }, "the typing call withholds it")
        let later = try await Self.call(harness, "observe", ["full": .bool(true)])
        #expect(Self.strings(in: later).contains { $0.contains(milano) }, "nothing of the scope outlives its call")
        let typingLines = harness.transcript.lines.filter { $0.hasPrefix("→ type_text") || $0.hasPrefix("← type_text") }
        #expect(typingLines.count == 2 && !typingLines.contains { Self.values(of: $0).contains { $0.contains(milano) } },
                "\(typingLines)")
        await Self.finish(harness)
    }

    // MARK: T13: the last output after a failed end

    @Test("T13: the end the memory cannot write after the effect: the answer's last line says so, withholds the text, and nothing is replayed")
    func failedEndAfterTheEffect() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "braus-w1t-\(UUID().uuidString)", directoryHint: .isDirectory)
        let knowledge = root.appending(path: "Knowledge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A memory that gives a held lock one short attempt, so the end is refused at once.
        MemoryService.install(MemoryService(directory: knowledge, configuration: MemoryService.Configuration(
            store: SQLiteMemoryStore.Configuration(lockBudget: .milliseconds(100), retryPause: .milliseconds(5),
                                                   maximumRetryPause: .milliseconds(10)),
            essentialAttempts: 1, essentialCycles: 1)))
        let session = await SyntheticWebSession.make(fields: Self.fields, knowledge: knowledge)
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: .app, streamID: "w1t-end", traceID: "m1", messageRef: "m1")
        let transcript = Transcript()
        tools.record = { transcript.lines.append($0) }
        _ = try await tools.call("open_session", .object(["app": .string("web:fixture.test")]))
        let id = try #require(session.id?.uuidString)
        let harness = Harness(root: root, knowledge: knowledge, session: session, tools: tools, transcript: transcript, id: id)
        // An unclassified text, not a producer secret: inserted at a focus the page cannot attest.
        session.page.run("document.activeElement = { tagName: 'IFRAME', contentDocument: null };")
        let text = "unended-\(Self.fragment)"
        var lock: SQLiteConnection?
        session.afterDelivering = {
            let held = try SQLiteConnection(path: knowledge.appendingPathComponent("memory.sqlite").path)
            try held.execute("BEGIN IMMEDIATE")
            lock = held
        }
        let answer = try await Self.call(harness, "insert_text", ["text": .string(text)])
        let last = try #require(transcript.lines.last)
        #expect(last.hasPrefix("← insert_text") && last.contains("could not save its record"), "\(last)")
        #expect(Self.strings(in: answer).contains { $0.contains("Do not repeat the action") }, "\(answer)")
        #expect(session.page.textEvents == 1, "the text went out once and was not replayed")
        try lock?.execute("COMMIT")
        lock?.close()
        await Self.finish(harness)
        try Self.expectWithheld(text, in: harness, answers: [answer])
        #expect(session.page.textEvents == 1, "nothing replayed after the end was saved")
        #expect(try Self.gaps(harness).contains("text:unclassified_target"))
    }
}
