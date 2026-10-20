//
//  MacAutomationSession.swift
//  Braus
//

import AutomationRuntime
import Engine
import EngineCore
import Foundation
import MacDriver
import MacDriving
import Memory
import PerceptionCore
import Router
import WindowServerListing

/// MacAutomationSession is a session on one native app through the MacDriver: `open` launches or finds
/// the app with `MacLauncher`, in the background, and reads its window from the accessibility tree;
/// every later call goes through the engine and the recorder exactly as a desktop session's does. It
/// takes no seat (spec 2026-10-14-mac-driver-design, section 7).
///
/// `open` gives the app back to the current Driver (`MacHandoff`) when its window reads sparse
/// (`MacCoverage`), or when the window came in front of the person's and could not be sent back: the
/// seat then adopts it (mode 1). The general rule: the MacDriver keeps the apps that stay behind, and
/// the seat contains the ones that want the front. So each later gesture is guarded the same way
/// (`MacFocusGuard` in `MacActuator`): when the app came in front during one, the person's app is
/// brought back where possible, the outcome says so, and the next call hands the app to the seat.
/// Closing never quits the app.
///
/// The app is claimed for `leaseOwner` (`AppClaims`, I03) at `open`, before the launch can reach it, and the session
/// keeps its hold until `close` or until it goes away. Another owner's session driving it refuses the open with
/// nothing sent and no handoff to the seat. An `open` that fails gives the hold back; one that hands the app to the
/// seat keeps it until `close`, so the app stays its owner's until the seat holds it too.
@MainActor
public final class MacAutomationSession: AutomationSessionOperating {

    private let knowledgeDirectory: URL
    private let allowsDestructive : Bool
    private let roles             : MacRoles
    private let launcher          : MacLauncher
    private let workspace         : any MacWorkspace
    private let leases            : MacAppLeases
    private let leaseOwner        : AnyHashable
    private var hold     : AppClaims.Hold?
    private var runtime  : MacEngineRuntime?
    private var report   : MacLaunchReport?
    /// Set when the app came in front during a gesture: the next call hands it to the seat.
    private var cameInFront = false
    public private(set) var id: UUID?
    /// The coverage of the window `open` read last, kept after a handoff for the caller's note.
    public private(set) var openedCoverage: MacCoverage?

    /// `leaseOwner` is who drives through this session: a worker's id, an external client's connection, or by
    /// default this session alone.
    public init(
        knowledgeDirectory: URL,
        allowsDestructive : Bool = false,
        roles             : MacRoles = .live(),
        workspace         : any MacWorkspace = LiveMacWorkspace(),
        leases            : MacAppLeases = .shared,
        leaseOwner        : AnyHashable = UUID()
    ) {
        self.knowledgeDirectory = knowledgeDirectory
        self.allowsDestructive  = allowsDestructive
        self.roles              = roles
        self.workspace          = workspace
        self.leases             = leases
        self.leaseOwner         = leaseOwner
        launcher = MacLauncher(workspace: workspace, reader: roles.reader)
    }

    /// The route this session is when no routing session fronts it (M05).
    public var dispatchRoute: CallRoute.Route? { .native }

    public func open(application word: String, window title: String?) async throws -> SceneSnapshot {
        guard id == nil else {
            throw AutomationFailure("A session is already open. Observe it or close_session before opening another app.")
        }
        // Resolving the name touches no app: the lease is taken before the launch can.
        let app: MacApp
        do { app = try launcher.resolve(word) }
        catch let failure as MacLaunchFailure { throw AutomationFailure(Self.sentence(failure, word)) }
        try lease(app.bundleID, name: app.displayName)
        do {
            return try await open(app, word, window: title)
        } catch let handoff as MacHandoff {
            throw handoff
        } catch {
            hold = nil
            throw error
        }
    }

    /// `open` once `app` is claimed: opened as resolved, never by `word` again, so a name that changed meanwhile
    /// cannot open another app.
    private func open(_ app: MacApp, _ word: String, window title: String?) async throws -> SceneSnapshot {
        let report: MacLaunchReport
        do { report = try await launcher.open(app) }
        catch let failure as MacLaunchFailure { throw AutomationFailure(Self.sentence(failure, word)) }
        if !report.wasRunning { MacLaunchLog(directory: knowledgeDirectory).append(report) }
        // A dialog or a sheet the app came forward to show is left in front for the person; the seat takes it.
        if report.dialogInFront { throw MacHandoff.dialogInFront(bundleID: report.app.bundleID) }
        // An app still in front after the launch (`revert` did not catch it) goes to the seat, even when
        // the focus guard brought the person's app back.
        if report.selfActivated {
            throw report.leftInFront ? MacHandoff.leftInFront(bundleID: report.app.bundleID)
                                     : MacHandoff.cameInFront(bundleID: report.app.bundleID)
        }
        guard let window = report.window else {
            let name = report.app.displayName
            let what = report.reopenRequested
                ? "\(name) is running and showed no window within the wait, although it was asked for one in the background."
                : "\(name) opened with no window within the wait."
            throw AutomationFailure(what + " No session was opened on it: ask the person to show a window of \(name), "
                                    + "or open with it a document the person names.")
        }
        // The MacDriver reads the focused window; another one named by title is the seat's to pick.
        if let title, (window.title ?? "").caseInsensitiveCompare(title) != .orderedSame {
            throw MacHandoff.otherWindow(bundleID: report.app.bundleID)
        }
        let runtime = MacEngineRuntime(knowledgeDirectory: knowledgeDirectory, roles: roles, focus: workspace)
        let scene = try await runtime.scenes.scene(of: report.processID)
        openedCoverage = scene.coverage
        guard scene.coverage.isRich else {
            await runtime.finish()
            throw MacHandoff.sparse(bundleID: report.app.bundleID, coverage: scene.coverage)
        }
        self.runtime = runtime
        self.report  = report
        id = UUID()
        // A first-run sheet is part of the window's tree, so the scene shows it with its buttons.
        return await recorder(runtime).observe(scene.perceived)
    }

    public func observe() async throws -> SceneSnapshot {
        let (report, runtime) = try await current()
        let perceived = try await runtime.scenes.currentScene(of: report.processID)
        return await recorder(runtime).observe(perceived)
    }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        let (report, runtime) = try await current()
        if verb == .setToggle, desiredState != .on && desiredState != .off {
            throw AutomationFailure("set_toggle requires value on or off.")
        }
        let request = ActionRequest(processID: report.processID, bundleID: report.app.bundleID,
                                    appName: report.app.displayName, target: target, verb: verb, section: section,
                                    desiredState: desiredState)
        let focusGuard = await MacFocusGuard.begin(workspace)
        let outcome = await runtime.engine(recorder: recorder(runtime), allowsDestructive: allowsDestructive).act(request)
        return await enriched(checkingFocus(outcome, focusGuard, report, runtime), by: runtime)
    }

    public func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        try await deliver(input, section: section, withholdsText: false)
    }

    /// The MacDriver attests no field (W1): it classifies nothing, so a bound text is refused with nothing typed, and
    /// a withheld one is delivered with the engine quoting none of its values.
    public func deliver(_ input: InputRequest.Input, section: String?, dispatch: TextDispatch) async throws -> ActOutcome {
        guard dispatch == .withheld else {
            throw AutomationFailure("This session cannot type only into the field the call recorded, so nothing was typed.")
        }
        return try await deliver(input, section: section, withholdsText: true)
    }

    private func deliver(_ input: InputRequest.Input, section: String?, withholdsText: Bool) async throws -> ActOutcome {
        let (report, runtime) = try await current()
        let request = InputRequest(processID: report.processID, bundleID: report.app.bundleID,
                                   appName: report.app.displayName, input: input, section: section,
                                   withholdsText: withholdsText)
        let focusGuard = await MacFocusGuard.begin(workspace)
        let outcome = await runtime.engine(recorder: recorder(runtime), allowsDestructive: allowsDestructive)
            .deliver(request)
        return await enriched(checkingFocus(outcome, focusGuard, report, runtime), by: runtime)
    }

    /// Opens `control`'s list and chooses `item` in it: two engine clicks, each verified, the second
    /// only when the first did not already choose it.
    public func select(control: String, item: String) async throws -> ActOutcome {
        let opened = try await act(target: control, verb: .click, section: nil, desiredState: nil)
        // After a click that brought the app in front, the item is the seat's to choose (the next call).
        guard opened.kind == .foundActed || opened.kind == .actedUnverified, !cameInFront else { return opened }
        return try await act(target: item, verb: .click, section: nil, desiredState: nil)
    }

    public func close() async {
        await finish()
        // Given back once the runtime has finished: only this session's hold.
        hold = nil
    }

    /// Ends the session and keeps its hold, for a handoff: `close` gives it back.
    private func finish() async {
        let runtime = self.runtime
        self.runtime = nil
        report = nil
        id = nil
        cameInFront = false
        await runtime?.finish()
    }

    /// Takes a hold of the app for this session's owner, or refuses: another owner's session drives it now. Nothing
    /// is sent to the app, and the call goes nowhere else.
    private func lease(_ bundleID: String, name: String) throws {
        switch leases.acquire(bundleID, owner: leaseOwner) {
            case .success(let taken): hold = taken
            case .failure(let refusal): throw AutomationFailure(AppClaims.sentence(refusal, name: name))
        }
    }

    public func windowCandidates(ownedBy processID: pid_t) async throws -> [WindowRow] {
        try await MacWindows(reader: roles.reader, serverWindows: roles.serverWindows).windows(ownedBy: processID)
    }

    public var memoryDirectory: URL? { knowledgeDirectory }

    public var memoryApplication: String? { report?.app.bundleID }

    private func recorder(_ runtime: MacEngineRuntime) -> CallRecorder {
        CallRecorder.current ?? runtime.recorder(ActionContext(
            source: .system, streamID: "session-\(id?.uuidString ?? "none")", sessionID: id?.uuidString
        ))
    }

    private func enriched(_ outcome: ActOutcome, by runtime: MacEngineRuntime) async -> ActOutcome {
        guard let scene = outcome.scene else { return outcome }
        return outcome.with(scene: await recorder(runtime).enrich(scene))
    }

    /// Notes a call during which the app came in front in the outcome: what was done stays done, and the
    /// next call hands the app to the seat. The actuator guards each gesture; `whole` guards the whole
    /// call, so the engine's own control and menu presses (`ControlPressing`) are covered too. A gesture
    /// whose key-window records were not taken back is noted too, and changes nothing else.
    private func checkingFocus(
        _ outcome: ActOutcome, _ whole: MacFocusGuard, _ report: MacLaunchReport, _ runtime: MacEngineRuntime
    ) async -> ActOutcome {
        var outcome = outcome
        // The rung the MacDriver's last gesture of this call took, the actuator's own note taken once for the call
        // that sent it (M05): a call whose gestures were all refused before any went out takes none, and a call whose
        // first gesture went out before a later one failed keeps that first gesture's note.
        if let note = runtime.actuator.takeFreshDelivery(in: report.processID) {
            await CallRecorder.current?.dispatched(rung: CallRung(note))
        }
        if runtime.actuator.takeUnrestoredPreparation(in: report.processID) {
            outcome = outcome.with(message: outcome.message + " " + Self.unrestoredNote(report.app.displayName))
        }
        let gesture = runtime.actuator.takeFocus(in: report.processID)
        let call = await whole.settle(after: report.processID)
        guard let focus = gesture?.selfActivated == true ? gesture : call, focus.selfActivated else { return outcome }
        cameInFront = true
        return outcome.with(message: outcome.message + " " + Self.cameInFrontNote(report.app.displayName, focus))
    }

    static func unrestoredNote(_ name: String) -> String {
        "Braus could not take back the key-window records it gave \(name)'s window for this step: the app may "
            + "treat that window as its key window until Braus next prepares it. What was done stays done."
    }

    static func cameInFrontNote(_ name: String, _ focus: MacFocusGuard.Outcome) -> String {
        let front = focus.focusRestored ? "the person's app is back in front"
            : focus.personActed ? "the person was using the computer, so their front was left as it is"
            : "it could not be sent back"
        return "\(name) came in front of the person's app during this step (\(front)): the next call hands it to the seat."
    }

    /// The open session, or the handoff a gesture left owed: the session closes and the seat adopts the
    /// app (mode 1).
    private func current() async throws -> (MacLaunchReport, MacEngineRuntime) {
        guard let report, let runtime else {
            throw AutomationFailure("No live application session. Use apps and open_session, then observe.")
        }
        guard !cameInFront else {
            await finish()
            throw MacHandoff.cameInFront(bundleID: report.app.bundleID)
        }
        return (report, runtime)
    }

    static func sentence(_ failure: MacLaunchFailure, _ word: String) -> String {
        switch failure {
            case .notFound(let name): "No installed application is named '\(name)'. Use apps to find its bundleID."
            case .ambiguous(let name, let identifiers):
                "'\(name)' names \(identifiers.count) installed applications: \(identifiers.joined(separator: ", ")). "
                    + "Nothing was opened; call open_session with the bundleID of the one meant, or ask the person."
            case .refused(let name) : "\(name) is a password manager: Braus never drives one."
            case .notTrusted        : "Braus has no Accessibility permission, so it cannot read '\(word)'. Grant it in "
                                      + "System Settings > Privacy & Security > Accessibility."
        }
    }
}

/// MacHandoff is the MacDriver giving an app back to the current Driver, with the reason: at `open`,
/// where nothing was acted on, or at the call after a gesture brought the app in front (`cameInFront`),
/// where the earlier steps stay done. The app is open either way.
nonisolated public enum MacHandoff: RouteHandoff, Equatable {
    /// The window's tree is too sparse for the MacDriver (spec section 3, "Which apps it takes").
    case sparse(bundleID: String, coverage: MacCoverage)
    /// The window came in front of the person's and stayed there: the seat adopts it (mode 1).
    case leftInFront(bundleID: String)
    /// The app came in front at launch or during a gesture: the seat contains it (mode 1).
    case cameInFront(bundleID: String)
    /// The app came forward at launch with a dialog or a sheet (a login, a permission prompt), left in
    /// front for the person: the seat adopts it.
    case dialogInFront(bundleID: String)
    /// The window asked for by title is not the focused one, the only one the MacDriver reads.
    case otherWindow(bundleID: String)

    public var bundleID: String {
        switch self {
            case .sparse(let bundleID, _), .leftInFront(let bundleID), .cameInFront(let bundleID), .dialogInFront(let bundleID),
                 .otherWindow(let bundleID): bundleID
        }
    }

    /// The reason in one sentence, for the record and the agent.
    public var reason: String {
        switch self {
            case .sparse(_, let coverage):
                "its window reads sparse (\(Int((coverage.coveredShare * 100).rounded()))% covered, "
                    + "\(coverage.actionableCount) actionable elements)"
            case .cameInFront:
                "it came in front of the person's app"
            case .dialogInFront:
                "it came in front with a dialog for the person (a login or a permission prompt), left there"
            case .leftInFront:
                "its window came in front of the person's and could not be sent back"
            case .otherWindow:
                "the window asked for is not its focused one"
        }
    }
}

extension CallRung {
    /// The actuator's note as the record keeps it: rung 1 as `accessibility`, rung 2 as `inPlace`, its words as they are.
    init(_ note: MacDeliveryNote) {
        self.init(rung: note.rung == .accessibility ? .accessibility : .inPlace, how: note.how, skipped: note.skipped)
    }
}
