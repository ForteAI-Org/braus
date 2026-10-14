//
//  RoutingAutomationSession.swift
//  Braus
//

import AutomationRuntime
import EngineCore
import Foundation
import PerceptionCore

/// RoutingAutomationSession lets one set of tools drive applications and pages: `open` with
/// `web:<host>` or a URL goes to the web session, any other name to the desktop one, and every
/// later call goes to the session that was opened last. The tools see one session, as before.
@MainActor
public final class RoutingAutomationSession: AutomationSessionOperating {

    public let desktop: any AutomationSessionOperating
    public let web    : any AutomationSessionOperating
    private var active: (any AutomationSessionOperating)?

    public init(desktop: any AutomationSessionOperating, web: any AutomationSessionOperating) {
        self.desktop = desktop
        self.web     = web
    }

    private var current: any AutomationSessionOperating { active ?? desktop }

    public var id: UUID? { current.id }

    public func open(application: String, window: String?) async throws -> SceneSnapshot {
        let next = WebAutomationSession.address(in: application) != nil ? web : desktop
        // Moving between the desktop and the web ends the other session, as opening a second app does.
        if let active, active !== next, active.id != nil { await active.close() }
        active = next
        return try await next.open(application: application, window: window)
    }

    public func observe() async throws -> SceneSnapshot { try await current.observe() }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        try await current.act(target: target, verb: verb, section: section, desiredState: desiredState)
    }

    public func select(control: String, item: String) async throws -> ActOutcome {
        try await current.select(control: control, item: item)
    }

    public func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        try await current.deliver(input, section: section)
    }

    public func menu(path: String) async throws -> ActOutcome { try await current.menu(path: path) }

    public func press(button: String) async throws -> ActOutcome { try await current.press(button: button) }

    public func close() async { await current.close() }

    public var closeWarning: String? { current.closeWarning }
    public var seatNotice: String? { current.seatNotice }
    public var observedWindowNumber: Int? { current.observedWindowNumber }

    public func applications(matching query: String?) async throws -> [ApplicationCandidate] {
        try await desktop.applications(matching: query)
    }

    public func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] {
        processID < 0 ? try web.windowCandidates(ownedBy: processID) : try desktop.windowCandidates(ownedBy: processID)
    }

    public var memoryDirectory: URL? { current.memoryDirectory }
    public var memoryApplication: String? { current.memoryApplication }
}
