//
//  LearningSession.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore

/// LearningSession is a session double over several applications for the procedure tests: it holds one
/// window per application, answers every operation the tools route to a session with the outcome and
/// the check a real path reports for it, and reports to the call's recorder the perceptions the engine
/// would (`before`, `menu`, `after`, or the `current` observation), so the recorder, the archive, the
/// scene associations, the Brain's relations and the procedures all run as they do in production. Only
/// the operating system and the applications are replaced: a script says what each operation does to
/// the window and how its check judges it.
@MainActor
final class LearningSession: AutomationSessionOperating {

    /// Outcome is what one scripted operation does: the outcome's kind, the check its path reports, the
    /// effect the engine attributes, the window it leaves (nil keeps the window), and whether it throws.
    struct Outcome {
        var kind: ActOutcomeKind = .foundActed
        var check: OperationCheck?
        var effect: SceneEffect?
        var next: Window?
        var fails = false
        /// False for a command refused before any gesture (a menu item disabled, a button not found).
        var gesture = true
        /// How the window after a native command is perceived: as it is, by a perception that fails, or
        /// by a cancellation of the call arriving while it is perceived.
        var afterPerception = AfterPerception.perceived
        /// True for a native command whose call is cancelled before its gesture.
        var cancelledBeforeGesture = false
        /// How the window before a native command is perceived: as it is, by a perception that fails, by
        /// one that throws a cancellation, or while the call's task is cancelled, the window still read.
        var beforePerception = BeforePerception.perceived

        enum AfterPerception { case perceived, fails, cancelled }
        enum BeforePerception { case perceived, fails, cancelled, taskCancelled }
    }

    /// Window is one application's window as the double shows it.
    struct Window {
        var elements: [SceneElement]
        var surface: CaptureSurface = .window
        var title: String = "Window"
    }

    let directory: URL
    var id: UUID? = UUID()
    private(set) var application: String?
    var windows: [String: Window] = [:]
    /// What an operation does, by `tool|target` (the target, the control, the key, the path or the button).
    var script: [String: Outcome] = [:]
    /// Every operation that reached an application, in order.
    private(set) var gestures: [String] = []

    init(directory: URL) { self.directory = directory }

    var memoryDirectory: URL? { directory }
    var memoryApplication: String? { application }

    // MARK: Windows

    static func perceived(_ window: Window, of bundleID: String) -> PerceivedWindow {
        PerceivedWindow(
            scene  : SceneSnapshot(bundleID: bundleID, appName: bundleID, windowTitle: window.title,
                                   viewportPixelSize: ViewportPixelSize(width: 1600, height: 1200), elements: window.elements),
            frame  : CGRect(x: 0, y: 0, width: 800, height: 600),
            capture: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true, windowRole: "AXWindow",
                                    nodesVisited: window.elements.count + 1, elementsEmitted: window.elements.count),
            surface: window.surface
        )
    }

    private var current: PerceivedWindow? {
        guard let application, let window = windows[application] else { return nil }
        return Self.perceived(window, of: application)
    }

    static func button(_ label: String, x: Double = 0.5, container: String? = nil) -> SceneElement {
        SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label,
                     bounds: NormalizedRect(x: x, y: 0.1, width: 0.08, height: 0.04), role: "AXButton", container: container,
                     labelOrigin: .title)
    }

    static func field(_ value: String, x: Double = 0.3, container: String? = nil) -> SceneElement {
        SceneElement(id: "field|\(x)", kind: .control, label: value, bounds: NormalizedRect(x: x, y: 0.2, width: 0.2, height: 0.04),
                     role: "AXTextField", container: container, labelOrigin: .value)
    }

    static func popup(_ title: String, value: String, x: Double = 0.6) -> SceneElement {
        SceneElement(id: "popup|\(title.lowercased())", kind: .control, label: title,
                     bounds: NormalizedRect(x: x, y: 0.3, width: 0.1, height: 0.04), role: "AXPopUpButton", value: value,
                     labelOrigin: .title)
    }

    static func checkbox(_ title: String, state: ControlState) -> SceneElement {
        SceneElement(id: "check|\(title.lowercased())", kind: .control, label: title,
                     bounds: NormalizedRect(x: 0.1, y: 0.5, width: 0.05, height: 0.04), role: "AXCheckBox", state: state,
                     labelOrigin: .title)
    }

    static func row(_ name: String, y: Double, in list: String = "files") -> SceneElement {
        SceneElement(id: "row|\(name)", kind: .control, label: name, bounds: NormalizedRect(x: 0.2, y: y, width: 0.5, height: 0.04),
                     role: "AXRow", labelOrigin: .rowContent, collectionPath: list)
    }

    // MARK: Checks

    static func check(_ condition: OperationCheck.Condition, _ verdict: OperationCheck.Verdict = .passed,
                      method: OperationCheck.Method, expected: String? = nil, observed: String? = nil,
                      limits: [OperationCheck.Limit] = [], performed: OperationCheck.Performed = .requested,
                      target: SceneElement? = nil) -> OperationCheck {
        OperationCheck(condition: condition, method: method, verdict: verdict, expected: expected, observed: observed,
                       limits: limits, performed: performed, target: target.map(OperationCheck.Target.init))
    }

    private func element(_ label: String) -> SceneElement? {
        guard let application else { return nil }
        return windows[application]?.elements.first { $0.label == label }
    }

    // MARK: The session

    func open(application name: String, window: String?) async throws -> SceneSnapshot {
        guard windows[name] != nil else { throw AutomationFailure("no application \(name)") }
        application = name
        return try await observe()
    }

    func observe() async throws -> SceneSnapshot {
        guard let window = current else { throw AutomationFailure("no session") }
        return await recorder.observe(window)
    }

    /// The recorder of the call this task performs, or one of the session's own over the directory's
    /// memory, as the production sessions have (`AutomationSession.recorder`): what is observed is always
    /// enriched, and says when the memory cannot be read.
    private var recorder: CallRecorder {
        if let current = CallRecorder.current { return current }
        let memory = MemoryService.shared(for: directory)
        return CallRecorder(memory: memory,
                            brain: BrainMemory(brains: memory, applications: memory, relations: memory, clock: { memory.clock.brainNow() }),
                            context: ActionContext(source: .system, streamID: "session-double", sessionID: id?.uuidString))
    }

    /// Runs the scripted outcome of an operation: the window moves to its next one, the recorder gets the
    /// perceptions, the outcome carries its check.
    private func perform(_ key: String, target: SceneElement?, default fallback: OperationCheck,
                         record: (PerceivedWindow, PerceivedWindow, SceneEffect?) async -> Void) async throws -> ActOutcome {
        guard let application, let before = current else { throw AutomationFailure("no session") }
        let outcome = script[key] ?? Outcome(check: fallback)
        gestures.append(key)
        if outcome.fails { throw AutomationFailure("the seat stopped") }
        if let next = outcome.next { windows[application] = next }
        let after = current ?? before
        await record(before, after, outcome.effect)
        return ActOutcome(outcome.kind, "\(key) done", scene: after.scene, check: outcome.check ?? fallback)
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        let element = self.element(target) ?? Self.button(target)
        let fallback = verb == .setToggle
            ? Self.check(.stateAfterGesture, method: .controlState, expected: desiredState?.rawValue,
                         observed: desiredState?.rawValue, target: element)
            : Self.check(.structuralEffect, method: .sceneDifference, observed: "elementsAppeared",
                         limits: [.windowWide, .noExpectation], target: element)
        let bundle = application ?? ""
        return try await perform("act|\(target)", target: element, default: fallback) { before, after, effect in
            await CallRecorder.current?.record(ActionRecord(
                bundleID: bundle, element: element, verb: verb, effect: effect ?? .elementsAppeared(labels: ["done"]),
                windowTitleAfter: after.scene.windowTitle, before: before, after: after
            ))
        }
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        let element = self.element(control) ?? Self.popup(control, value: item)
        let fallback = Self.check(.valueReadBack, method: .controlValue, expected: item, observed: item, target: element)
        let bundle = application ?? ""
        return try await perform("select|\(control)", target: element, default: fallback) { before, after, _ in
            await CallRecorder.current?.record(before: before, menu: nil, after: after, bundleID: bundle, target: element)
        }
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        let bundle = application ?? ""
        switch input {
            case .typeText(let text, let target, _):
                let element = self.element(target) ?? Self.field("")
                let fallback = Self.check(.valueReadBack, method: .controlValue, expected: text, observed: text, target: element)
                return try await perform("type_text|\(target)", target: element, default: fallback) { before, after, _ in
                    await CallRecorder.current?.record(InputRecord(bundleID: bundle, input: input, target: element,
                                                                   before: before, after: after))
                }
            case .insertText(let text, let expecting):
                let fallback = Self.check(.valueReadBack, method: .controlValue, expected: expecting, observed: expecting ?? text)
                return try await perform("insert_text|focus", target: nil, default: fallback) { before, after, _ in
                    await CallRecorder.current?.record(InputRecord(bundleID: bundle, input: input, target: nil, before: before,
                                                                   after: after))
                }
            case .pressKey(let chord, _):
                let fallback = Self.check(.structuralEffect, method: .sceneDifference, observed: "elementsAppeared",
                                          limits: [.windowWide, .noExpectation])
                return try await perform("press_key|\(chord.key.word)", target: nil, default: fallback) { before, after, effect in
                    await CallRecorder.current?.record(InputRecord(bundleID: bundle, input: input, target: nil, before: before,
                                                                   after: after, effect: effect))
                }
            case .scroll(_, let target):
                let element = target.flatMap(self.element)
                let fallback = Self.check(.structuralEffect, method: .sceneDifference, observed: "elementsAppeared",
                                          limits: [.windowWide, .noExpectation], target: element)
                return try await perform("scroll|\(target ?? "window")", target: element, default: fallback) { before, after, effect in
                    await CallRecorder.current?.record(InputRecord(bundleID: bundle, input: input, target: element, before: before,
                                                                   after: after, effect: effect))
                }
            case .drag(let from, _):
                let element = self.element(from) ?? Self.button(from)
                let fallback = Self.check(.structuralEffect, method: .sceneDifference, observed: "elementsDisappeared",
                                          limits: [.windowWide, .noExpectation], target: element)
                return try await perform("drag|\(from)", target: element, default: fallback) { before, after, effect in
                    await CallRecorder.current?.record(InputRecord(bundleID: bundle, input: input, target: element, before: before,
                                                                   after: after, effect: effect))
                }
            case .contextMenu(let target, let item):
                let element = self.element(target) ?? Self.button(target)
                let fallback = Self.check(.menuItemChosen, method: .driverReceipt, expected: item, observed: item,
                                          limits: [.commandEffectUnchecked], target: element)
                return try await perform("context_menu|\(target)", target: element, default: fallback) { before, after, _ in
                    await CallRecorder.current?.record(before: before, menu: nil, after: after, bundleID: bundle, target: element)
                }
        }
    }

    func menu(path: String) async throws -> ActOutcome {
        try await native("menu|\(path)", default: Self.check(.windowSetChanged, method: .windowSignature, observed: "opened"))
    }

    func press(button: String) async throws -> ActOutcome {
        try await native("press|\(button)", default: Self.check(.windowSetChanged, method: .windowSignature, observed: "closed"))
    }

    /// A menu command or a dialog button as the production sessions run them: through
    /// `PerceivedCommand`, which perceives the window before the command and hands it the perception
    /// after it, and records both for the call. Only the command's own gesture and window check are the
    /// double's; a scripted refusal reaches no gesture and records nothing. A press whose window after it
    /// cannot be perceived, or whose call is cancelled meanwhile, is concluded by the production press
    /// (`DialogButtonPress.observed`), after its one gesture.
    private func native(_ key: String, default fallback: OperationCheck) async throws -> ActOutcome {
        guard let application, current != nil else { throw AutomationFailure("no session") }
        let outcome = script[key] ?? Outcome(check: fallback)
        var reads = 0
        return try await PerceivedCommand.perform(
            bundleID: application,
            recorder: CallRecorder.current,
            perceive: { [unowned self] in
                reads += 1
                if reads == 1 {
                    switch outcome.beforePerception {
                        case .perceived    : break
                        case .fails        : throw AutomationFailure("AX read failed before the command")
                        case .cancelled    : throw CancellationError()
                        case .taskCancelled: withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                if reads > 1 {
                    switch outcome.afterPerception {
                        case .perceived: break
                        case .fails    : throw AutomationFailure("AX read failed for window 4242 (secret-canary)")
                        case .cancelled: throw CancellationError()
                    }
                }
                guard let window = self.current else { throw AutomationFailure("no session") }
                return window
            }
        ) { observe in
            if outcome.cancelledBeforeGesture { throw CancellationError() }
            if !outcome.gesture { return ActOutcome(outcome.kind, "\(key) refused before any gesture") }
            gestures.append(key)
            if outcome.fails { throw AutomationFailure("the seat stopped") }
            if let next = outcome.next { windows[application] = next }
            if key.hasPrefix("press|"), outcome.afterPerception != .perceived {
                return try await DialogButtonPress.observed(String(key.dropFirst("press|".count)), observe: observe,
                                                            windowsChanged: { true })
            }
            let scene = try await observe()
            return ActOutcome(outcome.kind, "\(key) done", scene: scene, check: outcome.check ?? fallback)
        }
    }

    func applications(matching query: String?) async throws -> [ApplicationCandidate] { [] }

    func close() async {}
}
