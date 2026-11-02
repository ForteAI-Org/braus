//
//  RoutingAutomationSession.swift
//  Braus
//

import AutomationRuntime
import EngineCore
import Foundation
import PerceptionCore
import WindowServerListing

/// RoutingAutomationSession picks the session for each `open`, and every later call goes to the
/// session that was opened last. The tools see one session, as before. It stands before the drivers and
/// knows none of them: the app hands it a session for each route.
///
/// - A web address (`web:<host>` or an `http`, `https` or `file` URL) goes to the `web` session; without
///   one it is refused with the reason.
/// - A native app goes to the `native` session first (the MacDriver in the app). When it gives the app
///   back (`RouteHandoff`) the `desktop` session (the seat) opens it by its bundle id; without a
///   `native` session it goes to the desktop directly.
/// - A native session can also give the app back at the start of a later call, before acting (the app
///   came in front during the last one): the desktop session opens it and the same call runs there.
///
/// Which app to open at all is the `TaskRouter`'s, asked by `open_session` before this session.
///
/// Each dispatch is reported to the call's recorder (`CallRecorder.current`) before it runs: the session it goes to,
/// and the reason when the native session gave the app back. The record keeps the last, the route the call ran on
/// (M05).
@MainActor
public final class RoutingAutomationSession: AutomationSessionOperating {

    public let native : (any AutomationSessionOperating)?
    public let desktop: any AutomationSessionOperating
    public let web    : (any AutomationSessionOperating)?
    private var active: (any AutomationSessionOperating)?
    /// Why the last native `open` went to the desktop session; nil when the native session took it.
    public private(set) var lastHandoff: (any RouteHandoff)?
    /// The window title the last `open` asked for, for a handoff after it.
    private var openedWindow: String?

    public init(native: (any AutomationSessionOperating)? = nil, desktop: any AutomationSessionOperating,
                web: (any AutomationSessionOperating)? = nil) {
        self.native  = native
        self.desktop = desktop
        self.web     = web
    }

    private var current: any AutomationSessionOperating { active ?? desktop }

    public var id: UUID? { current.id }

    public func open(application: String, window: String?) async throws -> SceneSnapshot {
        lastHandoff = nil
        openedWindow = window
        if Self.isWebAddress(application) {
            guard let web else {
                throw AutomationFailure("Web pages are not reachable from this session: it has no web session. "
                                        + "Tell the person, or open the native app if they named it.")
            }
            return try await open(application, window: window, on: web)
        }
        guard let native else { return try await open(application, window: window, on: desktop) }
        do {
            return try await open(application, window: window, on: native)
        } catch let handoff as any RouteHandoff {
            lastHandoff = handoff
            // The app is open now, so the desktop session finds it by its bundle id.
            return try await handingOver(from: native) {
                try await open(handoff.bundleID, window: window, on: desktop, handedBack: handoff)
            }
        }
    }

    /// Runs `body`, the desktop session taking the app `native` gave back, then closes `native`: its claim on the
    /// app (`AppClaims`) lasts until the desktop session holds the app too, or failed to, so no other owner takes it
    /// between.
    private func handingOver<Answer>(from native: any AutomationSessionOperating,
                                     _ body: () async throws -> Answer) async throws -> Answer {
        do {
            let answer = try await body()
            await native.close()
            return answer
        } catch {
            await native.close()
            throw error
        }
    }

    /// Moving to another session ends the open one, as opening a second app does.
    private func open(_ application: String, window: String?, on next: any AutomationSessionOperating,
                      handedBack handoff: (any RouteHandoff)? = nil) async throws -> SceneSnapshot {
        if let active, active !== next, active.id != nil { await active.close() }
        active = next
        await report(next, handedBack: handoff)
        return try await next.open(application: application, window: window)
    }

    /// Tells the call's recorder, before the dispatch, which route `session` is, with the native session's reason
    /// when it gave the app back (M05).
    private func report(_ session: any AutomationSessionOperating,
                        handedBack handoff: (any RouteHandoff)? = nil) async {
        let route: CallRoute.Route = session === native ? .native : session === web ? .web : .desktop
        await CallRecorder.current?.dispatched(on: CallRoute(route, handoffReason: handoff?.reason))
    }

    public func observe() async throws -> SceneSnapshot { try await routed { try await $0.observe() } }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        try await routed { try await $0.act(target: target, verb: verb, section: section, desiredState: desiredState) }
    }

    public func select(control: String, item: String) async throws -> ActOutcome {
        try await routed { try await $0.select(control: control, item: item) }
    }

    public func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        try await routed { try await $0.deliver(input, section: section) }
    }

    /// The current session's classification; a session handed back would classify nothing, so none is asked.
    public func classify(_ input: InputRequest.Input, section: String?) async -> TextTargetClass {
        await current.classify(input, section: section)
    }

    /// A classified delivery goes to the session that classified it; one handed back to the desktop refuses a
    /// binding it cannot keep, with nothing typed.
    public func deliver(_ input: InputRequest.Input, section: String?, dispatch: TextDispatch) async throws -> ActOutcome {
        try await routed { try await $0.deliver(input, section: section, dispatch: dispatch) }
    }

    public func menu(path: String) async throws -> ActOutcome { try await routed { try await $0.menu(path: path) } }

    public func press(button: String) async throws -> ActOutcome { try await routed { try await $0.press(button: button) } }

    public func collectPosts(_ request: PostCollectionRequest) async throws -> PostCollection {
        try await routed { try await $0.collectPosts(request) }
    }

    /// Human-control history belongs to the desktop even if the active route has since changed.
    public func humanStep(_ request: HumanStepRequest) async -> HumanStepResult {
        await desktop.humanStep(request)
    }

    /// Runs `call` on the current session. When the native session gives the app back instead (it acts on
    /// nothing then), the desktop session opens the app and `call` runs there.
    private func routed<Answer>(_ call: (any AutomationSessionOperating) async throws -> Answer) async throws -> Answer {
        let session = current
        await report(session)
        do {
            return try await call(session)
        } catch let handoff as any RouteHandoff {
            guard let native, session === native else { throw handoff }
            lastHandoff = handoff
            _ = try await handingOver(from: native) {
                try await open(handoff.bundleID, window: openedWindow, on: desktop, handedBack: handoff)
            }
            return try await call(desktop)
        }
    }

    public func close() async {
        var closed: Set<ObjectIdentifier> = []
        for session in [native, desktop, web].compactMap({ $0 }) where closed.insert(ObjectIdentifier(session)).inserted {
            await session.close()
        }
    }

    public var closeWarning: String? { current.closeWarning }
    public var seatNotice: String? { current.seatNotice }
    public var browserNotice: String? { current.browserNotice }
    public var observedWindowNumber: Int? { current.observedWindowNumber }

    public func applications(matching query: String?) async throws -> [ApplicationCandidate] {
        try await desktop.applications(matching: query)
    }

    public func resolvedBundleID(of application: String) async -> String? {
        guard !Self.isWebAddress(application) else { return nil }
        return await desktop.resolvedBundleID(of: application)
    }

    public func windowCandidates(ownedBy processID: pid_t) async throws -> [WindowRow] {
        if processID < 0, let web { return try await web.windowCandidates(ownedBy: processID) }
        return try await desktop.windowCandidates(ownedBy: processID)
    }

    public var memoryDirectory: URL? { current.memoryDirectory }
    public var memoryApplication: String? { current.memoryApplication }
    public var dataProfile: String? { current.dataProfile }

    /// `web:` followed by anything, or an `http`, `https` or `file` URL: what the web session opens
    /// (`WebAutomationSession.address(in:)`, which refuses a `web:` word naming no address).
    public nonisolated static func isWebAddress(_ word: String) -> Bool {
        let lowered = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["web:", "http://", "https://", "file://"].contains { lowered.hasPrefix($0) }
    }
}

/// RouteHandoff is a native session giving an app back, at `open` or at the start of a later call, with
/// the reason: that call acted on nothing, the app is open, and the desktop session finds it by `bundleID`.
public protocol RouteHandoff: Error, Sendable {
    var bundleID: String { get }
    /// The reason in one sentence, for the record and the agent.
    var reason: String { get }
}
