//
//  WebRungWiringTests.swift
//  Braus
//

import AutomationRuntime
import CoreGraphics
import Engine
import EngineCore
import Foundation
import Memory
import SQLiteMemory
import Testing
import WebDriver
import WebDriving
import WebSession

/// M05, the web's rung on the record, wired from the runtime's actuator to the archive (W-R1): the runtime a web
/// session composes (`WebEngineRuntime`) over a synthetic page sends each gesture as DevTools `Input` commands, the
/// actuator notes what it knows of the last one (the method, the commands planned, handed to the connection and
/// acknowledged, the outcome), the session's own hand-over (`WebAutomationSession.handRung`) takes it once and gives
/// it to the call's recorder, which writes it with the call's end. A call whose click the page would not deliver
/// (covered) sends nothing and records none, never an earlier call's. The counts are the page's own: the command the
/// browser rejects, the one the transport never carries, the one the call is cancelled on, each leaves exactly the
/// counts the page saw. No Chrome, no window, no key or mouse event of the person's. What is not here, by source
/// alone: `WebAutomationSession.act`/`deliver` calling `handRung` after the engine (W-R2 runs them through the tools).
@MainActor
@Suite("M05: the web's send reaches the call's record through the runtime's actuator and the session's hand-over", .serialized)
struct WebRungWiringTests {

    static let mouse = WebSend.Method.mouse.rawValue
    static let key   = WebSend.Method.key.rawValue
    /// The fields of the W1 page: "Accesso" (a password field) and "Nome" (a text field at 100,200 300×30).
    static let fields = TextTargetWebTests.fields
    static let nome   = CGRect(x: 100, y: 200, width: 300, height: 30)

    /// On the main actor, as the runtime's engine and recorder are.
    @MainActor
    struct Stack {
        let page     : SyntheticPage
        let tabs     : WebTabs
        let runtime  : WebEngineRuntime
        let processID: pid_t
        let knowledge: URL
        let app      = AppContextIdentity(bundleID: "web:fixture.test")

        func recorder() -> CallRecorder {
            runtime.recorder(ActionContext(source: .system, streamID: "web-rung", traceID: "web-rung", sessionID: "w1"))
        }

        func click(_ target: String) -> ActionRequest {
            ActionRequest(processID: processID, bundleID: app.bundleID, appName: "fixture.test", target: target, verb: .click)
        }

        /// One call as the session makes it: begun on the record, the engine's `act` (or `run`, which may act more
        /// than once under the one recorder, as `select` does), the hand-over, the end.
        func recordedClick(_ target: String, attribution: TaskCallAttribution? = nil,
                           engine run: ((ActionEngine, CallRecorder) async -> ActOutcome)? = nil) async throws -> (id: String, outcome: ActOutcome) {
            let recorder = recorder()
            try await recorder.begin(.act(target: target, verb: .click, value: nil, section: nil), app: app, attribution: attribution)
            let engine = runtime.engine(recorder: recorder, allowsDestructive: false)
            let request = click(target)
            let outcome = await CallRecorder.$current.withValue(recorder) {
                if let run { await run(engine, recorder) } else { await engine.act(request) }
            }
            await WebAutomationSession.handRung(of: tabs, in: processID, to: recorder)
            try await recorder.end(.completed, result: .outcome(outcome.kind, message: outcome.message), tool: .act,
                                   check: outcome.withStatedCheck.check)
            return (recorder.eventID, outcome)
        }

        func rung(of id: String) async throws -> CallRung? {
            try await runtime.service.perform { try await $0.facts.rung(of: id) }
        }

        func performed(of id: String) async throws -> OperationCheck.Performed? {
            try await runtime.service.perform { try await $0.facts.effect(of: id) }?.performed
        }
    }

    static func stack() async throws -> Stack {
        let page = SyntheticPage(fields: fields)
        let connection = await CDPConnection(transport: page)
        let tabs = WebTabs()
        let processID = tabs.register(WebPage(connection: connection, targetID: "target-1", sessionID: "session-1"))
        let knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("braus-web-rung-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        return Stack(page: page, tabs: tabs, runtime: WebEngineRuntime(knowledgeDirectory: knowledge, tabs: tabs),
                     processID: processID, knowledge: knowledge)
    }

    static func finish(_ stack: Stack) async {
        _ = await stack.runtime.service.flush(within: .seconds(10))
        await stack.runtime.service.close()
        MemoryService.forget(stack.knowledge)
        stack.page.close()
        try? FileManager.default.removeItem(at: stack.knowledge)
    }

    /// The three counts of a rung's `how`, as "<method>: P planned, A attempted, K acknowledged, <outcome>" words them.
    static func counts(of rung: CallRung?) -> [Int] {
        (rung?.how ?? "").split(separator: " ").compactMap { Int($0.trimmingCharacters(in: .punctuationCharacters)) }
    }

    @Test("a click's three commands acknowledged are the call's rung under its task; the browser's rejection, a closed transport and a cancellation keep the page's exact counts; a covered click records none and never an earlier one's")
    func theSendIsRecordedWithThePagesCounts() async throws {
        let stack = try await Self.stack()
        let page  = stack.page
        // A real task in the archive, through the channel the tools use; the first call begins under it.
        let producer = try TaskProducer(source: .system, streamID: "web-rung")
        let task = try await TaskChannel.begin(try TaskRevisionContent(goal: "Click Nome in the form"), producer: producer,
                                               traceID: "web-rung", memory: stack.runtime.service)
        let attribution = try #require(task.attribution)

        // 1. A click acknowledged whole: moved, pressed, released.
        let first = try await stack.recordedClick("Nome", attribution: attribution)
        #expect(page.pressCount == 1 && page.count(of: Self.mouse) == 3, "\(page.count(of: Self.mouse))")
        #expect(try await stack.rung(of: first.id) == CallRung(rung: .webInputEvent,
                                                               how: "Input.dispatchMouseEvent: 3 planned, 3 attempted, 3 acknowledged, completed"))
        #expect(try await stack.runtime.service.perform { try await $0.facts.attribution(of: first.id) } == attribution)
        #expect(stack.tabs.takeLastSend(for: stack.processID) == nil, "taken once")
        _ = try await TaskChannel.checkpoint(task, try TaskCheckpointDraft(kind: .end, declared: .completed),
                                             producer: producer, memory: stack.runtime.service)

        // 2. The browser rejects the second command (the press): two handed over, one acknowledged, no press seen,
        //    the effect uncertain, the row says so and nothing more.
        page.fault(Self.mouse, atOccurrence: page.count(of: Self.mouse) + 2, .rejected)
        let rejected = try await stack.recordedClick("Nome")
        #expect(page.pressCount == 1)
        #expect(try await stack.rung(of: rejected.id) == CallRung(rung: .webInputEvent,
                                                                  how: "Input.dispatchMouseEvent: 3 planned, 2 attempted, 1 acknowledged, rejected by the browser"))
        let rejectedEffect = try await stack.performed(of: rejected.id)
        #expect(rejectedEffect == .uncertain, "\(String(describing: rejectedEffect))")
        #expect(try await stack.runtime.service.perform { try await $0.facts.attribution(of: rejected.id) } == nil,
                "begun after the task ended: no task")

        // 3. The transport throws on the second command, as a closed connection does before anything is on the wire:
        //    handed over, not acknowledged, unanswered.
        page.fault(Self.mouse, atOccurrence: page.count(of: Self.mouse) + 2, .transportClosed)
        let closed = try await stack.recordedClick("Nome")
        #expect(page.pressCount == 1)
        #expect(try await stack.rung(of: closed.id) == CallRung(rung: .webInputEvent,
                                                                how: "Input.dispatchMouseEvent: 3 planned, 2 attempted, 1 acknowledged, unanswered"))
        #expect(try await stack.performed(of: closed.id) == .uncertain)

        // 4. The second command's answer never comes and the call is cancelled while it waits: the same counts,
        //    unanswered; the hand-over and the end run outside the cancelled task, as the session's do.
        let (dropped, droppedNow) = AsyncStream<Void>.makeStream()
        page.fault(Self.mouse, atOccurrence: page.count(of: Self.mouse) + 2, .dropped(then: { droppedNow.yield(); droppedNow.finish() }))
        let cancelled = try await stack.recordedClick("Nome") { engine, _ in
            let request = stack.click("Nome")
            let running = Task { await engine.act(request) }
            // The fault must be reached within a bound, or the test fails here; the call is cancelled and joined either way.
            let reached = await withTaskGroup(of: Bool.self) { group in
                group.addTask { for await _ in dropped { return true }; return false }
                group.addTask { try? await Task.sleep(for: .seconds(10)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(reached, "the dropped answer was not reached within 10 s")
            running.cancel()
            return await running.value
        }
        #expect(page.pressCount == 1)
        #expect(try await stack.rung(of: cancelled.id) == CallRung(rung: .webInputEvent,
                                                                   how: "Input.dispatchMouseEvent: 3 planned, 2 attempted, 1 acknowledged, unanswered"))
        let cancelledEffect = try await stack.performed(of: cancelled.id)
        #expect(cancelledEffect == .uncertain, "\(String(describing: cancelledEffect))")

        // 5. A typed text: the last gesture is the keys, counted; the row holds the method and counts, not the text.
        let keysBefore = page.count(of: Self.key)
        let typed = stack.recorder()
        try await typed.begin(.typeText(target: "Nome", text: "typed-Q7z9", section: nil, replace: false), app: stack.app)
        let typedOutcome = await CallRecorder.$current.withValue(typed) {
            await stack.runtime.engine(recorder: typed, allowsDestructive: false).deliver(InputRequest(
                processID: stack.processID, bundleID: stack.app.bundleID, appName: "fixture.test",
                input: .typeText("typed-Q7z9", into: "Nome", replacing: false), section: nil))
        }
        await WebAutomationSession.handRung(of: stack.tabs, in: stack.processID, to: typed)
        try await typed.end(.completed, result: .outcome(typedOutcome.kind, message: typedOutcome.message), tool: .typeText,
                            check: typedOutcome.withStatedCheck.check)
        let keys = page.count(of: Self.key) - keysBefore
        let typedRung = try await stack.rung(of: typed.eventID)
        let typedCounts = Self.counts(of: typedRung)
        #expect(typedRung?.rung == .webInputEvent && typedRung?.how.hasPrefix("Input.dispatchKeyEvent: ") == true
                && typedRung?.how.hasSuffix(", completed") == true, "\(String(describing: typedRung))")
        #expect(typedCounts.count == 3 && typedCounts[0] == typedCounts[1] && typedCounts[1] == typedCounts[2]
                && typedCounts[0] > 0 && typedCounts[0] <= keys && keys > 0, "\(typedCounts) of \(keys) key commands")
        #expect(typedRung?.how.contains("typed") == false && typedRung?.how.contains("Q7z9") == false, "no text in the row")
        #expect(page.textCount > 0, "the keys reached the page")

        // 6. One record, two gestures, as `select`'s two clicks run under the one recorder the tools opened (A): the
        //    first click goes out and is handed over; then a banner covers the field and the second click is refused
        //    before any command and handed over too; the one row keeps the first send. (The engine's `act` twice
        //    under one recorder, not the session's `select`.)
        let presses = page.pressCount
        let twoGestures = try await stack.recordedClick("Nome") { engine, recorder in
            _ = await engine.act(stack.click("Nome"))
            await WebAutomationSession.handRung(of: stack.tabs, in: stack.processID, to: recorder)
            page.change([.cover(Self.nome, name: "Banner")])
            let mouseBefore = page.count(of: Self.mouse)
            let refused = await engine.act(stack.click("Nome"))
            #expect(page.count(of: Self.mouse) == mouseBefore, "the covered click sent nothing")
            #expect(refused.kind == .refused || refused.kind == .honestMiss || refused.kind == .actedNoop,
                    "\(refused.kind): \(refused.message)")
            await WebAutomationSession.handRung(of: stack.tabs, in: stack.processID, to: recorder)
            return refused
        }
        #expect(page.pressCount == presses + 1)
        #expect(try await stack.rung(of: twoGestures.id) == CallRung(rung: .webInputEvent,
                                                                     how: "Input.dispatchMouseEvent: 3 planned, 3 attempted, 3 acknowledged, completed"),
                "the record keeps the first send when the later gesture sent nothing")

        // 7. The next call, its only click refused before any command: no rung, and nothing of the earlier calls'
        //    left to take.
        let mouseBefore = page.count(of: Self.mouse)
        let covered = try await stack.recordedClick("Nome")
        #expect(page.count(of: Self.mouse) == mouseBefore && page.pressCount == presses + 1, "nothing sent")
        #expect(covered.outcome.kind == .refused || covered.outcome.kind == .honestMiss || covered.outcome.kind == .actedNoop,
                "\(covered.outcome.kind): \(covered.outcome.message)")
        #expect(try await stack.rung(of: covered.id) == nil, "a call refused before any command has no rung")
        #expect(stack.tabs.takeLastSend(for: stack.processID) == nil)

        // Every call ended on the record, under one trace, nothing replayed: the page's presses are the two clicks'.
        let calls = try await stack.runtime.service.calls(inTrace: "web-rung")
        #expect(calls.count == 7 && calls.allSatisfy { $0.progress.status == .completed }, "\(calls.map(\.progress.status))")
        await Self.finish(stack)
    }
}
