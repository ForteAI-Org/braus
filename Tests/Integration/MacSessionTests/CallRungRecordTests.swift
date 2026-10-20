import AutomationMCP
import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import LocalMCP
import MacDriver
import MacDriving
@testable import MacSession
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Synchronization
import Testing

/// M05, the rung on the record: the MacDriver's actuator notes how each gesture went (rung 1, an accessibility action;
/// rung 2, events posted in place), and the native session hands the note of a call's last gesture to the call's
/// recorder, once, for the call that sent it. On the record each such call has one rung with what it did and why rung
/// 1 was passed over, under the task open then; a call refused before any gesture has none and never an earlier call's;
/// a call whose first gesture went out before a later one failed keeps that first gesture's; an uncertain rung 1 keeps
/// the word; a start the memory does not confirm acts nothing and records nothing. A declared secret the driver's own
/// words carry (an app's uncertain answer, an action's name) is in the actuator's raw note and in no row, no transcript
/// line and no file of the archive, open or closed.
///
/// Offline: `AutomationTools` over the MacDriver on the fakes of `MacSessionTests`, the knowledge folder the memory.
@MainActor
@Suite("M05: the rung of each call's last gesture, on the record", .serialized)
struct CallRungRecordTests {

    nonisolated static let typedSecret   = "Sentinel-R1-typed-9z4q"
    nonisolated static let answerSecret  = "Sentinel-R1-answer-k2m8"
    nonisolated static let actionSecret  = "Sentinel-R1-action-v7p3"

    /// A window covered by twelve controls, rich for `MacCoverage` as `MacSessionTests.rich` is (a sparse one goes to
    /// the Seat): the Save button rung 1 presses, the Name field a typed text's keys reach on rung 2, the Picker pop-up
    /// rung 1 presses as a `select`'s first click, and nine more buttons.
    nonisolated static let form = MacTreeNode(role: "AXWindow", title: "Notes", frame: MacSessionTests.frame, children: (0..<12).map { index in
        let frame = CGRect(x: Double(index % 4) * 200, y: Double(index / 4) * 200, width: 200, height: 200)
        switch index {
            case 0: return MacTreeNode(role: "AXButton", title: "Save", frame: frame, actions: ["AXPress"])
            case 1: return MacTreeNode(role: "AXTextField", title: "Name", frame: frame, actions: ["AXConfirm"])
            case 2: return MacTreeNode(role: "AXPopUpButton", title: "Picker", frame: frame, actions: ["AXPress"])
            default: return MacTreeNode(role: "AXButton", title: "B\(index)", frame: frame, actions: ["AXPress"])
        }
    })

    /// What the archive holds of one call: its tool, its status, its rung, its task and its effect.
    struct Recorded: Equatable {
        let tool  : String
        let status: AgentCallStatus?
        let rung  : CallRung?
        let task  : String?
        let performed: OperationCheck.Performed?
    }

    static func recorded(_ trace: String, in knowledge: URL) async throws -> [Recorded] {
        let memory = MemoryService.shared(for: knowledge)
        _ = await memory.flush(within: .seconds(5))
        var found: [Recorded] = []
        for call in try await memory.calls(inTrace: trace) {
            let id = call.event.eventID
            let rung = try await memory.perform { try await $0.facts.rung(of: id) }
            let task = try await memory.perform { try await $0.facts.attribution(of: id) }?.taskID
            let effect = try await memory.perform { try await $0.facts.effect(of: id) }
            found.append(Recorded(tool: call.request.tool.rawValue, status: call.progress.status, rung: rung, task: task,
                                  performed: effect?.performed))
        }
        return found
    }

    /// The files under the knowledge folder holding `text`, by name, read from any context. A file the memory makes
    /// and removes while it works (its backup's partial files) may be gone between the enumeration and the read: gone
    /// (`ENOENT`, and nothing else), it holds nothing; any other error, on the metadata or the bytes, is thrown.
    nonisolated static func files(under knowledge: URL, holding text: String) throws -> [String] {
        var holding: [String] = []
        let walk = FileManager.default.enumerator(at: knowledge, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = walk?.nextObject() as? URL {
            let regular: Bool
            do { regular = try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            catch let error where vanished(error) { continue }
            guard regular else { continue }
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch let error where vanished(error) { continue }
            if data.range(of: Data(text.utf8)) != nil { holding.append(file.lastPathComponent) }
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

    static func knowledge() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("braus-rung-\(UUID().uuidString)")
    }

    final class Transcript: @unchecked Sendable {
        let lines = Mutex<[String]>([])
        var text: String { lines.withLock { $0.joined(separator: "\n") } }
    }

    /// The tools over the MacDriver on `reader` and `delivery`, the archive in `knowledge`, the calls under `trace`,
    /// the transcript kept in `transcript`.
    static func tools(_ reader: any MacTreeReading & MacAccessibilityActing, delivery: any MacEventDelivering,
                      knowledge: URL, trace: String, transcript: Transcript? = nil) -> AutomationTools {
        // The fake process declares who it is (the seam of `MacScenes.identity`): the workspace knows no application
        // behind pid 500, and a scene with no bundle identifier is refused by the record.
        let roles = MacRoles(reader: reader, actor: reader, delivery: delivery, person: nil,
                             notifications: QuietNotifications(), controls: NoControls(),
                             serverWindows: { _ in [(number: 7, frame: MacSessionTests.frame)] },
                             identity: { _ in (MacSessionTests.notes.bundleID, "Notes") })
        let session = MacAutomationSession(knowledgeDirectory: knowledge, roles: roles, workspace: WorkspaceStub(),
                                           leases: MacAppLeases())
        let tools = AutomationTools(session: session)
        tools.producer = CallProducer(source: .app, streamID: "rung", traceID: trace)
        if let transcript { tools.record = { line in transcript.lines.withLock { $0.append(line) } } }
        return tools
    }

    /// The same actuator the session drives, built apart over the same reader, so the raw note it writes can be read:
    /// the words the driver would keep before the record withholds anything.
    static func rawNote(_ reader: any MacTreeReading & MacAccessibilityActing, delivery: any MacEventDelivering) async -> MacDeliveryNote? {
        let cache = MacSceneCache()
        cache.store(MacSceneCache.Entry(window: Self.form.addressed(), windowIndex: 0, windowNumber: 7), for: 9)
        let actuator = MacActuator(cache: cache, actor: reader, delivery: delivery, person: nil)
        _ = try? await actuator.perform(.click(at: CGPoint(x: 100, y: 100)), in: 9)
        return actuator.lastDelivery(in: 9)
    }

    static func sessionID(_ answer: JSONValue) -> String? {
        guard let text = answer["content"].array?.first?["text"].string,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { return nil }
        return value["session"].string
    }

    static func text(_ answer: JSONValue) -> String { answer["content"].array?.first?["text"].string ?? "" }

    /// Begins a task through the tools with `secrets` declared, and answers its id.
    static func begin(_ tools: AutomationTools, secrets: [String]) async throws -> String {
        let inputs = secrets.enumerated().map { index, secret -> JSONValue in
            .object(["name": .string("code\(index)"), "value": .string(secret), "secret": .bool(true)])
        }
        let begun = try await tools.call("memory_task", .object([
            "operation": .string("begin"), "goal": .string("Name the note"), "remaining": .string("Name the note"),
            "inputs": .array(inputs),
        ]))
        return try #require((try? JSONDecoder().decode(JSONValue.self, from: Data(text(begun).utf8)))?["task"].string, "\(text(begun))")
    }

    /// Every row's words, the transcript and every file of the archive, open and then closed, searched for `secrets`.
    static func nothingKeeps(_ secrets: [String], calls: [Recorded], transcript: Transcript, knowledge: URL, _ label: String) async throws {
        for secret in secrets {
            for call in calls {
                #expect(call.rung?.how.contains(secret) != true && call.rung?.skipped.contains { $0.contains(secret) } != true,
                        "\(label): a row holds the secret: \(call)")
            }
            #expect(!transcript.text.contains(secret), "\(label): the transcript holds the secret")
            #expect(try Self.files(under: knowledge, holding: secret).isEmpty, "\(label): the open archive holds the secret")
        }
        await MemoryService.closeAll()
        for secret in secrets {
            #expect(try Self.files(under: knowledge, holding: secret).isEmpty, "\(label): the closed archive holds the secret")
        }
    }

    @Test("R1: a click a button lists is rung 1 with what it did; a typed text ends on rung 2 with why rung 1 was passed over; a click on a label the scene lacks records no rung and not the earlier call's; the task of each call's moment; a declared secret typed is in no row and no file")
    func rungsOnTheRecord() async throws {
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let reader = TreeStub(Self.form)
        let transcript = Transcript()
        let tools = Self.tools(reader, delivery: NoDelivery(), knowledge: knowledge, trace: "r1", transcript: transcript)
        let id = try #require(Self.sessionID(try await tools.call("open_session", .object(["app": .string("Notes")]))))
        let task = try await Self.begin(tools, secrets: [Self.typedSecret])
        _ = try await tools.call("act", .object(["session": .string(id), "target": .string("Save"), "verb": .string("click")]))
        _ = try await tools.call("type_text", .object(["session": .string(id), "target": .string("Name"), "text": .string(Self.typedSecret)]))
        _ = try? await tools.call("act", .object(["session": .string(id), "target": .string("Nowhere"), "verb": .string("click")]))
        _ = try await tools.call("memory_task", .object(["operation": .string("end"), "outcome": .string("completed")]))
        _ = try await tools.call("act", .object(["session": .string(id), "target": .string("Save"), "verb": .string("click")]))
        #expect(reader.steps.withLock { $0 }.filter { $0.hasPrefix("perform AXPress") }.count == 2, "\(reader.steps.withLock { $0 })")

        let calls = try await Self.recorded("r1", in: knowledge)
        #expect(calls.map(\.tool) == ["open_session", "act", "type_text", "act", "act"], "\(calls.map(\.tool))")
        try #require(calls.count == 5)
        #expect(calls[1].rung?.rung == .accessibility && calls[1].rung?.skipped == [] && calls[1].rung?.how.contains("AXButton") == true,
                "\(String(describing: calls[1].rung))")
        #expect(calls[2].rung?.rung == .inPlace && calls[2].rung?.skipped == ["keys have no accessibility action: posted to the process"],
                "\(String(describing: calls[2].rung))")
        #expect(calls[3].rung == nil && calls[3].performed == OperationCheck.Performed.none, "a refusal before any gesture: \(calls[3])")
        #expect(calls[4].rung?.rung == .accessibility, "\(String(describing: calls[4].rung))")
        #expect(calls[0].rung == nil, "an open sends no gesture")
        #expect(calls[1...3].allSatisfy { $0.task == task } && calls[4].task == nil && calls[0].task == nil, "\(calls.map(\.task))")
        #expect(calls.allSatisfy { $0.status == .completed }, "\(calls)")
        try await Self.nothingKeeps([Self.typedSecret], calls: calls, transcript: transcript, knowledge: knowledge, "R1")
    }

    /// A reader whose accessibility actions answer with the failure given: an app that does not answer (rung 1
    /// uncertain, never replayed), or an action the element does not list (rung 1 passed over, rung 2 runs).
    final class ThrowingTreeStub: MacTreeReading, MacAccessibilityActing, @unchecked Sendable {
        let tree: MacTreeNode
        let failure: MacTreeFailure
        let isTrusted = true
        let performs = Mutex(0)
        init(_ tree: MacTreeNode, failure: MacTreeFailure) {
            self.tree = tree.addressed()
            self.failure = failure
        }
        func windows(of processID: pid_t) throws -> [MacWindowSummary] {
            [MacWindowSummary(index: 0, role: "AXWindow", title: tree.title, frame: tree.frame, isMain: true, isFocused: true)]
        }
        func read(windowAt index: Int, of processID: pid_t, limits: MacTreeLimits) throws -> MacTreeRead {
            MacTreeRead(window: tree, nodesVisited: tree.flattened.count)
        }
        func perform(_ action: String, on element: MacElementAddress) throws {
            performs.withLock { $0 += 1 }
            throw failure
        }
        func select(_ element: MacElementAddress) throws { throw failure }
        func focus(_ element: MacElementAddress) throws { throw failure }
        func scroll(_ area: MacElementAddress, _ direction: MacScrollDirection) throws -> String { "bar" }
        func readBack(_ element: MacElementAddress) -> MacTreeNode? { nil }
    }

    /// A delivery that counts the events it was asked to post and posts none.
    final class CountingDeliveryForRungs: MacEventDelivering, @unchecked Sendable {
        let sent = Mutex(0)
        func deliver(_ gesture: Gesture, toWindow windowNumber: Int, of processID: pid_t,
                     needsKeyWindow: Bool) async throws -> MacEventReceipt {
            sent.withLock { $0 += 1 }
            return MacEventReceipt(preparationNotRestored: false)
        }
    }

    /// A delivery that fails every event, so rung 2 never lands.
    struct FailingDelivery: MacEventDelivering {
        func deliver(_ gesture: Gesture, toWindow windowNumber: Int, of processID: pid_t,
                     needsKeyWindow: Bool) async throws -> MacEventReceipt {
            throw AutomationFailure("the events could not be posted")
        }
    }

    @Test("R1-secrets: a declared secret the driver's own words carry, in an app's uncertain answer (into how) and in an action's name (into skipped), is in the actuator's raw note and in no row, no transcript line and no file of the archive, open or closed; the uncertainty and the rung stay")
    func secretsInTheDriversWords() async throws {
        // The app's answer names the secret: rung 1 uncertain, its `how` carries it raw, the row does not.
        let uncertainKnowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: uncertainKnowledge) }
        let uncertain = ThrowingTreeStub(Self.form, failure: .uncertain("\(Self.answerSecret) did not answer"))
        let counting = CountingDeliveryForRungs()
        let raw = await Self.rawNote(uncertain, delivery: counting)
        #expect(raw?.rung == .accessibility && raw?.how.contains(Self.answerSecret) == true && raw?.how.contains("uncertain") == true,
                "the actuator's own note carries the answer: \(String(describing: raw))")
        let transcript = Transcript()
        let tools = Self.tools(uncertain, delivery: counting, knowledge: uncertainKnowledge, trace: "r1s", transcript: transcript)
        let id = try #require(Self.sessionID(try await tools.call("open_session", .object(["app": .string("Notes")]))))
        let task = try await Self.begin(tools, secrets: [Self.answerSecret, Self.actionSecret])
        _ = try? await tools.call("act", .object(["session": .string(id), "target": .string("Save"), "verb": .string("click")]))
        #expect(uncertain.performs.withLock { $0 } == 2 && counting.sent.withLock { $0 } == 0, "one request each (the raw note's and the call's), no rung 2")
        let doubted = try await Self.recorded("r1s", in: uncertainKnowledge)
        try #require(doubted.count == 2, "\(doubted)")
        #expect(doubted[1].rung?.rung == .accessibility && doubted[1].rung?.how.contains("uncertain") == true
                && doubted[1].rung?.how.contains(ValueMinimization.marker) == true && doubted[1].task == task,
                "\(String(describing: doubted[1].rung))")
        #expect(doubted[1].performed == .uncertain, "\(doubted[1])")
        try await Self.nothingKeeps([Self.answerSecret, Self.actionSecret], calls: doubted, transcript: transcript,
                                    knowledge: uncertainKnowledge, "uncertain")

        // The action's name is the secret: rung 1 passed over, rung 2 runs, the reason in `skipped` carries it raw.
        let listedKnowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: listedKnowledge) }
        let unlisted = ThrowingTreeStub(Self.form, failure: .actionNotListed(Self.actionSecret))
        let posting = CountingDeliveryForRungs()
        let rawSkipped = await Self.rawNote(unlisted, delivery: posting)
        #expect(rawSkipped?.rung == .inPlace && rawSkipped?.skipped.contains { $0.contains(Self.actionSecret) } == true,
                "the actuator's own note names the action: \(String(describing: rawSkipped))")
        let listedTranscript = Transcript()
        let listedTools = Self.tools(unlisted, delivery: posting, knowledge: listedKnowledge, trace: "r1a", transcript: listedTranscript)
        let listedID = try #require(Self.sessionID(try await listedTools.call("open_session", .object(["app": .string("Notes")]))))
        _ = try await Self.begin(listedTools, secrets: [Self.actionSecret])
        _ = try? await listedTools.call("act", .object(["session": .string(listedID), "target": .string("Save"), "verb": .string("click")]))
        #expect(posting.sent.withLock { $0 } == 2, "rung 2 posted once for the raw note and once for the call")
        let passedOver = try await Self.recorded("r1a", in: listedKnowledge)
        try #require(passedOver.count == 2, "\(passedOver)")
        #expect(passedOver[1].rung?.rung == .inPlace && passedOver[1].rung?.skipped.count == 1
                && passedOver[1].rung?.skipped.first?.contains(ValueMinimization.marker) == true,
                "\(String(describing: passedOver[1].rung))")
        try await Self.nothingKeeps([Self.actionSecret], calls: passedOver, transcript: listedTranscript,
                                    knowledge: listedKnowledge, "passed over")
    }

    @Test("R2: a select whose first click is rung 1 and whose item the scene lacks keeps the first gesture's rung under that call; a typed text whose keys fail on rung 2 noted no gesture and has no rung, its effect uncertain; a start the memory does not confirm sends nothing and records nothing")
    func partialAndUnconfirmed() async throws {
        // Two gestures in one call: the pop-up pressed on rung 1, then the item refused before any gesture; the note of
        // the first stays under the call, the refusal does not erase it.
        let knowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let reader = TreeStub(Self.form)
        let tools = Self.tools(reader, delivery: FailingDelivery(), knowledge: knowledge, trace: "r2")
        let id = try #require(Self.sessionID(try await tools.call("open_session", .object(["app": .string("Notes")]))))
        let selected: String
        do { selected = Self.text(try await tools.call("select", .object(["session": .string(id), "control": .string("Picker"), "item": .string("Nowhere")]))) }
        catch { selected = "thrown: \(error)" }
        #expect(reader.steps.withLock { $0 }.filter { $0.hasPrefix("perform AXPress") }.count == 1, "the pop-up pressed once on rung 1: \(reader.steps.withLock { $0 }); the call answered \(selected)")
        // A typed text on the MacDriver sends its keys on rung 2, and the delivery fails: no gesture was noted, the
        // record has no rung for it and its effect is uncertain, never zero gestures claimed.
        let typed: String
        do { typed = Self.text(try await tools.call("type_text", .object(["session": .string(id), "target": .string("Name"), "text": .string("hello")]))) }
        catch { typed = "thrown: \(error)" }
        #expect(typed.contains("delivery failed") && typed.contains("acted_unverified"), "\(typed)")
        let partial = try await Self.recorded("r2", in: knowledge)
        try #require(partial.count == 3, "\(partial)")
        #expect(partial[1].tool == "select" && partial[1].rung?.rung == .accessibility && partial[1].rung?.how.contains("AXPopUpButton") == true,
                "the first gesture's note, kept under the select: \(partial[1]); the call answered \(selected)")
        #expect(partial[2].tool == "type_text" && partial[2].rung == nil && partial[2].performed == .uncertain,
                "no gesture noted, the effect uncertain: \(partial[2]); the call answered \(typed)")
        await MemoryService.closeAll()

        // A start the memory does not confirm: refused before the gesture, no event, no rung.
        let lockedKnowledge = Self.knowledge()
        defer { try? FileManager.default.removeItem(at: lockedKnowledge) }
        let lockedReader = TreeStub(Self.form)
        let lockedTools = Self.tools(lockedReader, delivery: NoDelivery(), knowledge: lockedKnowledge, trace: "r2l")
        MemoryService.install(MemoryService(directory: lockedKnowledge, configuration: MemoryService.Configuration(
            store: SQLiteMemoryStore.Configuration(lockBudget: .milliseconds(100), retryPause: .milliseconds(5),
                                                   maximumRetryPause: .milliseconds(10)),
            essentialAttempts: 1, essentialCycles: 1)))
        let lockedID = try #require(Self.sessionID(try await lockedTools.call("open_session", .object(["app": .string("Notes")]))))
        let lock = FilesThroughTheToolsTests.ArchiveLock()
        try lock.hold(lockedKnowledge)
        let refusal: String
        do {
            _ = try await lockedTools.call("act", .object(["session": .string(lockedID), "target": .string("Save"), "verb": .string("click")]))
            refusal = "answered"
        } catch {
            refusal = String(describing: error)
        }
        lock.release()
        #expect(refusal.contains("did not confirm"), "\(refusal)")
        #expect(lockedReader.steps.withLock { $0 }.isEmpty, "nothing was sent")
        let locked = try await Self.recorded("r2l", in: lockedKnowledge)
        #expect(locked.map(\.tool) == ["open_session"], "\(locked)")
        await MemoryService.closeAll()
    }
}
