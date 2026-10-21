//
//  SyntheticWebSession.swift
//  Braus
//

import AutomationRuntime
import CoreGraphics
import Engine
import EngineCore
import Foundation
import Memory
import PerceptionCore
import WebDriver
@testable import WebDriving
import WebSession

/// SyntheticWebSession is a web session over a `SyntheticPage`, composed as `WebAutomationSession` composes
/// its tab: the production web roles, engine and recorder (`WebEngineRuntime`), every call recorded through
/// `CallRecorder.current` when the tools give one. With no memory (`knowledge` nil) the tools record nothing
/// and the engine reports to no recorder. It opens no Chrome; `open` names the page it already has.
/// `failure`, when set, is thrown by a delivery in place of the engine's answer, after its classification.
@MainActor
final class SyntheticWebSession: AutomationSessionOperating {

    let page     : SyntheticPage
    let tabs     : WebTabs
    let processID: pid_t
    private let knowledge: URL?
    private let runtime  : WebEngineRuntime?
    private(set) var id: UUID?
    /// Thrown by `deliver` instead of delivering, to test what an error carries.
    var failure: (any Error)?
    /// Awaited by `deliver` before it delivers, to test a cancellation mid-call.
    var waitsBeforeDelivering = false
    /// Passed by `deliver` before it delivers: a call held there is still inside its scope.
    var gate: Gate?
    /// Run once a delivery returned, before the tools write its end.
    var afterDelivering: (() throws -> Void)?
    /// Whether it classifies its texts (true) or, as the MacDriver and the Seat, attests nothing (false).
    var classifies = true
    /// Whether a withheld dispatch reaches the engine (true), or is delivered as any input (false): a session
    /// that keeps the protocol's default, as the Seat did before `withholdsText` reached its engine.
    var passesWithheld = true

    /// Gate holds the calls that pass it until it is released, and tells a test once one is held.
    @MainActor
    final class Gate {
        private var held: [CheckedContinuation<Void, Never>] = []
        private var watchers: [CheckedContinuation<Void, Never>] = []
        func pass() async {
            for watcher in watchers { watcher.resume() }
            watchers = []
            await withCheckedContinuation { held.append($0) }
        }
        func untilHeld() async {
            guard held.isEmpty else { return }
            await withCheckedContinuation { watchers.append($0) }
        }
        func release() {
            for call in held { call.resume() }
            held = []
        }
    }

    static func make(fields: [SyntheticPage.Field], knowledge: URL?) async -> SyntheticWebSession {
        let page = SyntheticPage(fields: fields)
        let connection = await CDPConnection(transport: page)
        return SyntheticWebSession(page: page, connection: connection, knowledge: knowledge)
    }

    private init(page: SyntheticPage, connection: CDPConnection, knowledge: URL?) {
        let tabs = WebTabs()
        self.page      = page
        self.knowledge = knowledge
        self.tabs      = tabs
        processID      = tabs.register(WebPage(connection: connection, targetID: "target-1", sessionID: "session-1"))
        runtime        = knowledge.map { WebEngineRuntime(knowledgeDirectory: $0, tabs: tabs) }
    }

    var memoryDirectory: URL? { knowledge }
    var memoryApplication: String? { id == nil ? nil : "web:fixture.test" }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        id = UUID()
        return try await observe()
    }

    func observe() async throws -> SceneSnapshot {
        let perceived = try await WebScenes(tabs: tabs).currentScene(of: processID)
        guard let recorder = recorder() else { return perceived.scene }
        return await recorder.observe(perceived)
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        await engine().act(ActionRequest(processID: processID, bundleID: "web:fixture.test", appName: "fixture.test",
                                         target: target, verb: verb, section: section, desiredState: desiredState))
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        throw AutomationFailure("select is not part of this synthetic page")
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        try await deliver(input, section: section, binding: nil, withholdsText: false)
    }

    func deliver(_ input: InputRequest.Input, section: String?, dispatch: TextDispatch) async throws -> ActOutcome {
        switch dispatch {
            case .bound(let binding): try await deliver(input, section: section, binding: binding, withholdsText: false)
            case .withheld          : try await deliver(input, section: section, binding: nil, withholdsText: passesWithheld)
        }
    }

    func classify(_ input: InputRequest.Input, section: String?) async -> TextTargetClass {
        guard classifies else { return .unclassified(.unsupported) }
        return await engine().classify(request(input, section: section, binding: nil))
    }

    private func deliver(_ input: InputRequest.Input, section: String?, binding: TextTargetBinding?,
                         withholdsText: Bool) async throws -> ActOutcome {
        if waitsBeforeDelivering { try await Task.sleep(for: .seconds(30)) }
        if let gate { await gate.pass() }
        if let failure { throw failure }
        var request = request(input, section: section, binding: binding)
        request.withholdsText = withholdsText
        let outcome = await engine().deliver(request)
        try afterDelivering?()
        afterDelivering = nil
        return outcome
    }

    func close() async {
        id = nil
        await runtime?.finish()
    }

    private func request(_ input: InputRequest.Input, section: String?, binding: TextTargetBinding?) -> InputRequest {
        InputRequest(processID: processID, bundleID: "web:fixture.test", appName: "fixture.test", input: input,
                     section: section, binding: binding)
    }

    private func recorder() -> CallRecorder? {
        guard let runtime else { return nil }
        return CallRecorder.current ?? runtime.recorder(ActionContext(source: .system, streamID: "synthetic",
                                                                       sessionID: id?.uuidString))
    }

    private func engine() -> ActionEngine {
        if let runtime, let recorder = recorder() { return runtime.engine(recorder: recorder, allowsDestructive: false) }
        return ActionEngine(ActionEngine.Dependencies(
            scenes: WebScenes(tabs: tabs), actuator: WebActuator(tabs: tabs), windows: WebWindows(tabs: tabs),
            controls: WebControls(tabs: tabs), settling: WebSettler(tabs: tabs)
        ))
    }
}
