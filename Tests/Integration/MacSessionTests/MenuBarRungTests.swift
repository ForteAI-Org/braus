//
//  MenuBarRungTests.swift
//  Braus
//

import ApplicationServices
@testable import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// M05, the menu bar command's press on the record: the shared command's runners (`runPrepared`, `runInFront`) answer
/// what was pressed and the code the press returned; `MenuBarCommand.handMenuRung`, the seam `perform` and
/// `performInFront` call right after the press and before anything is observed, hands the call's recorder the
/// accessibility rung with the driver's words, written with the end under the task open then. A press the system
/// refused, or nothing pressed, records none and nothing is inferred; the real `observedOutcome` after the press
/// keeps its answers, and the rung outlives an observation that fails. The press is a fake: no application, no menu
/// bar, no window. Source-only: the Broker's `menu` calling `perform`/`performInFront` with its bound recorder.
@MainActor
@Suite("M05: the menu bar command's press on the record", .serialized)
struct MenuBarRungTests {

    nonisolated static let secret = "Sentinel-Menu-3f9k"

    /// The record of one `menu` call, as the tools make it: a recorder on a temporary archive whose minimization knows
    /// the task's declared secret, begun with the call's request, handed what the runner answered, ended.
    struct Record {
        let knowledge: URL
        let memory   : MemoryService
        let brain    : BrainMemory
        let app      = AppContextIdentity(bundleID: "test.menu")

        init() throws {
            knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("braus-menu-rung-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
            let memory = MemoryService.shared(for: knowledge)
            self.memory = memory
            brain = BrainMemory(brains: memory, applications: memory, relations: memory, clock: { memory.clock.brainNow() })
        }

        func recorder() -> CallRecorder {
            CallRecorder(memory: memory, brain: brain,
                         context: ActionContext(source: .system, streamID: "menu-rung", traceID: "menu-rung", sessionID: "s1"),
                         minimization: ValueMinimization(secrets: [MenuBarRungTests.secret]))
        }

        /// One call: begun with the path, the hand-over of the runner's answer (and, when `again`, a second with
        /// nothing, as a later moment of the same call), ended with the outcome the command returned.
        func menu(_ path: String, _ run: MenuBarCommand.Run, attribution: TaskCallAttribution? = nil, again: Bool = false) async throws -> String {
            let recorder = recorder()
            try await recorder.begin(.menu(path: path), app: app, attribution: attribution)
            await MenuBarCommand.handMenuRung(pressed: run.pressed, answer: run.answer, to: recorder)
            if again { await MenuBarCommand.handMenuRung(pressed: nil, answer: nil, to: recorder) }
            try await recorder.end(.completed, result: .outcome(run.outcome.kind, message: run.outcome.message), tool: .menu,
                                   check: run.outcome.check)
            return recorder.eventID
        }

        func rung(of id: String) async throws -> CallRung? { try await memory.perform { try await $0.facts.rung(of: id) } }
        func attribution(of id: String) async throws -> TaskCallAttribution? { try await memory.perform { try await $0.facts.attribution(of: id) } }
        func performed(of id: String) async throws -> OperationCheck.Performed? { try await memory.perform { try await $0.facts.effect(of: id) }?.performed }

        func beginTask() async throws -> (task: OpenTask, producer: TaskProducer, attribution: TaskCallAttribution) {
            let producer = try TaskProducer(source: .system, streamID: "menu-rung")
            let task = try await TaskChannel.begin(try TaskRevisionContent(goal: "Save through the menu", inputs: [
                try TaskValue(name: "item", role: "the menu item", kind: .text, content: .withheld, sensitivity: .secret, source: .request),
            ]), producer: producer, traceID: "menu-rung", memory: memory)
            guard let attribution = task.attribution else { throw CocoaError(.coderInvalidValue) }
            return (task, producer, attribution)
        }

        func endTask(_ task: OpenTask, _ producer: TaskProducer) async throws {
            _ = try await TaskChannel.checkpoint(task, try TaskCheckpointDraft(kind: .end, declared: .completed), producer: producer, memory: memory)
        }

        /// The event ids under the trace after a flush; then the archive scanned for the secret open and closed.
        func finish(expecting ids: Set<String>, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            _ = await memory.flush(within: .seconds(10))
            let calls = try await memory.calls(inTrace: "menu-rung")
            #expect(Set(calls.map(\.event.eventID)) == ids && calls.count == ids.count, "\(calls.map(\.event.eventID))", sourceLocation: sourceLocation)
            #expect(try MenuBarRungTests.files(under: knowledge, holding: MenuBarRungTests.secret).isEmpty, "the open archive holds the secret",
                    sourceLocation: sourceLocation)
            await memory.close()
            MemoryService.forget(knowledge)
            #expect(try MenuBarRungTests.files(under: knowledge, holding: MenuBarRungTests.secret).isEmpty, "the closed archive holds the secret",
                    sourceLocation: sourceLocation)
            try? FileManager.default.removeItem(at: knowledge)
        }
    }

    /// The regular files under `knowledge` whose bytes hold `text`, strictly: a folder that cannot be enumerated throws;
    /// an error met on the way is kept and thrown after the walk; a file gone between the enumeration and the read
    /// (`ENOENT`, POSIX or Cocoa's no-such-file, itself or underneath) is skipped; every other error propagates.
    nonisolated static func files(under knowledge: URL, holding text: String) throws -> [String] {
        struct ScanFailure: Error, CustomStringConvertible { let description: String }
        final class Interrupted: @unchecked Sendable {
            private let lock = NSLock()
            private var failure: (URL, any Error)?
            func record(_ url: URL, _ error: any Error) { lock.withLock { failure = (url, error) } }
            var value: (URL, any Error)? { lock.withLock { failure } }
        }
        let interrupted = Interrupted()
        guard let walk = FileManager.default.enumerator(at: knowledge, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [], errorHandler: { url, error in
            if vanished(error) { return true }
            interrupted.record(url, error)
            return false
        }) else {
            throw ScanFailure(description: "the knowledge folder could not be enumerated: \(knowledge.path)")
        }
        var holding: [String] = []
        while let file = walk.nextObject() as? URL {
            let regular: Bool
            do { regular = try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            catch let error where vanished(error) { continue }
            guard regular else { continue }
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch let error where vanished(error) { continue }
            if data.range(of: Data(text.utf8)) != nil { holding.append(file.lastPathComponent) }
        }
        if let (url, error) = interrupted.value {
            throw ScanFailure(description: "the enumeration of \(knowledge.path) failed at \(url.lastPathComponent): \(error)")
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

    static func words(_ path: String, _ answer: AXError) -> String {
        answer == .success ? "AXPress for \(path) returned success"
                           : "AXPress for \(path) returned cannotComplete; delivery uncertain, treated as pressed by the driver"
    }

    @Test("MB-1: the press's code is the call's rung in the driver's words, success and cannotComplete distinct, the fresh path after a refresh; a second hand-over with nothing keeps it; after the task ends the next call is its own; a press the system refused and nothing pressed record none; through both runners; the secret in the path nowhere")
    func thePressIsTheRung() async throws {
        let record = try Record()
        let (task, producer, attribution) = try await record.beginTask()
        let secretPath = "File > \(Self.secret)"
        var presses = 0

        // 1. A press answered success through runPrepared: the row with the path's secret withheld.
        let a = await MenuBarCommand.runPrepared(preparesEnabledItems: false, read: { .press("item", path: secretPath) },
                                                 press: { (_: String) in presses += 1; return .success }, refresh: nil)
        #expect(a.pressed == secretPath && a.answer == .success && a.outcome.kind == .foundActed && presses == 1)
        let first = try await record.menu(secretPath, a, attribution: attribution, again: true)
        // The recorder's rule (CallRecorder.admit): a request argument withheld for a declared secret is itself kept as a
        // secret of the call, searched for whole; so the row withholds the whole path, not the word alone.
        let expectedFirst = ValueMinimization(secrets: [Self.secret, secretPath]).minimize(text: Self.words(secretPath, .success)).0
        let firstRung = try await record.rung(of: first)
        #expect(firstRung == CallRung(rung: .accessibility, how: expectedFirst) && firstRung?.how.contains(Self.secret) == false
                && firstRung?.how.contains(ValueMinimization.marker) == true, "\(String(describing: firstRung))")
        #expect(try await record.attribution(of: first) == attribution)

        // 2. A refresh that reads the item again, then a press answered cannotComplete: the fresh path, the words that keep
        //    the doubt, distinct from success; still under the task.
        var reads = 0
        let b = await MenuBarCommand.runPrepared(preparesEnabledItems: true,
                                                 read: { reads += 1; return .press("item", path: reads == 1 ? "File > Save" : "File > Save…") },
                                                 press: { (_: String) in presses += 1; return .cannotComplete }, refresh: { .readAgain })
        #expect(b.pressed == "File > Save…" && b.answer == .cannotComplete && b.outcome.kind == .foundActed && reads == 2 && presses == 2)
        let second = try await record.menu("File > Save", b, attribution: attribution)
        #expect(try await record.rung(of: second) == CallRung(rung: .accessibility, how: Self.words("File > Save…", .cannotComplete)))
        #expect(try await record.rung(of: second) != firstRung)
        let secondAttribution = try await record.attribution(of: second)
        #expect(secondAttribution == attribution && secondAttribution?.taskID == attribution.taskID
                && secondAttribution?.attemptID == attribution.attemptID && secondAttribution?.revision == attribution.revision)
        try await record.endTask(task, producer)

        // 3. A press the system refused with another code: attempted, uncertain, no rung, no task.
        let c = await MenuBarCommand.runPrepared(preparesEnabledItems: false, read: { .press("item", path: "File > Save") },
                                                 press: { (_: String) in presses += 1; return .actionUnsupported }, refresh: nil)
        #expect(c.pressed == nil && c.answer == .actionUnsupported && c.outcome.kind == .actedUnverified
                && c.outcome.check?.performed == .uncertain && presses == 3)
        let third = try await record.menu("File > Save", c)
        let thirdRung = try await record.rung(of: third)
        let thirdPerformed = try await record.performed(of: third)
        #expect(thirdRung == nil && thirdPerformed == .uncertain)
        #expect(try await record.attribution(of: third) == nil)

        // 4. Nothing pressed: a listing, a disabled item, a refused path; the press is never invoked, no rung.
        var ids: Set<String> = [first, second, third]
        let unpressed: [MenuBarCommand.Resolution<String>] = [
            .list(path: "File", items: ["New…", "Save"]), .disabled(path: "File > Save"),
            .outcome(ActOutcome(.refused, "File > Delete requires --allow-destructive")),
        ]
        for resolution in unpressed {
            let r = await MenuBarCommand.runPrepared(preparesEnabledItems: false, read: { resolution },
                                                     press: { (_: String) in Issue.record("nothing to press"); return .success }, refresh: nil)
            #expect(r.pressed == nil && r.answer == nil)
            let id = try await record.menu("File", r)
            #expect(try await record.rung(of: id) == nil)
            ids.insert(id)
        }
        #expect(presses == 3)

        // 5. The same fact through runInFront: the press inside the front scope, answered success.
        let e = await MenuBarCommand.runInFront(read: { .press("item", path: "File > Save") },
                                                press: { (_: String) in presses += 1; return .success },
                                                withFront: { command in command(); return nil })
        #expect(e.pressed == "File > Save" && e.answer == .success && presses == 4)
        let fifth = try await record.menu("File > Save", e)
        #expect(try await record.rung(of: fifth) == CallRung(rung: .accessibility, how: Self.words("File > Save", .success)))
        #expect(try await record.attribution(of: fifth) == nil, "after the task ended: no task")
        ids.insert(fifth)

        try await record.finish(expecting: ids)
    }

    @Test("MB-2: the rung the real runner's press hands over before the real observedOutcome survives an observation that throws, an ordinary error or a CancellationError alike: one press and one observation per call, the outcome actedUnverified with noAfterScene, the check unknown, the call ended as the outcome says, the rung kept")
    func theRungOutlivesAFailedObservation() async throws {
        struct ObservationFailure: Error {}
        let record = try Record()
        var ids: Set<String> = []
        let failures: [(name: String, error: any Error, inFront: Bool)] = [
            ("an ordinary error", ObservationFailure(), false),
            ("a CancellationError", CancellationError(), false),
            ("an ordinary error in the front scope", ObservationFailure(), true),
            ("a CancellationError in the front scope", CancellationError(), true),
        ]
        for failure in failures {
            var presses = 0, observations = 0
            // The real runner with a counted fake press, as perform and performInFront run it.
            let run: MenuBarCommand.Run
            if failure.inFront {
                run = await MenuBarCommand.runInFront(read: { .press("item", path: "File > Save") },
                                                      press: { (_: String) in presses += 1; return .success },
                                                      withFront: { command in command(); return nil })
            } else {
                run = await MenuBarCommand.runPrepared(preparesEnabledItems: false, read: { .press("item", path: "File > Save") },
                                                       press: { (_: String) in presses += 1; return .success }, refresh: nil)
            }
            #expect(run.pressed == "File > Save" && run.answer == .success && run.outcome.kind == .foundActed && presses == 1, "\(failure.name)")
            let recorder = record.recorder()
            try await recorder.begin(.menu(path: "File > Save"), app: record.app)
            // The hand-over as perform does it, right after the runner, then the real observation that fails.
            await MenuBarCommand.handMenuRung(pressed: run.pressed, answer: run.answer, to: recorder)
            let outcome = try await MenuBarCommand.observedOutcome(
                run.pressed, outcome: run.outcome, processID: 1, before: ["w|AXWindow||Doc"],
                signature: { _ in ["w|AXWindow||Doc"] }, observe: { observations += 1; throw failure.error }
            )
            #expect(observations == 1 && presses == 1, "\(failure.name): one press, one observation, nothing replayed")
            #expect(outcome.kind == .actedUnverified && outcome.check?.verdict == .unknown
                    && outcome.check?.limits.contains(.noAfterScene) == true && outcome.check?.performed == .requested,
                    "\(failure.name): \(outcome.kind): \(outcome.message)")
            try await recorder.end(.completed, result: .outcome(outcome.kind, message: outcome.message), tool: .menu, check: outcome.check)
            #expect(try await record.rung(of: recorder.eventID) == CallRung(rung: .accessibility, how: Self.words("File > Save", .success)), "\(failure.name)")
            #expect(try await record.performed(of: recorder.eventID) == .requested)
            ids.insert(recorder.eventID)
        }
        try await record.finish(expecting: ids)
    }
}
