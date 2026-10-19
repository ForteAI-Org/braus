//
//  BrokeredAutomationSession.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import AutomationRuntime
import Engine
import EngineCore
import Foundation
import Memory
import Observation
import os
import Perception
import PerceptionCore
import PrivateSymbols
import SeatCore
import SeatDriving
import SeatSession
import VisionText

/// BrokeredAutomationSession is one worker's application session over the seat SeatBroker's queue
/// grants, so a worker's tools reach the desktop only through the broker (§22.3).
///
/// It is made for one worker and owns at most one lease at a time. `open` checks the grants,
/// waits in the queue under the worker's id, opens the application through the granted
/// session and perceives and acts through Ron's `EngineRuntime` over a target borrowed from that
/// session's seat, so the scenes, the engine and the Brain are the command line's. `close` flushes
/// the Brain, ends the borrow, finishes with the application as its provenance says and gives the
/// lease back, which parks the seat warm for the next entry.
///
/// The seat is kept after a turn for `idleWindow` without another turn, then closed, so a quick
/// follow-up reuses the open session and the window comes back soon after. A new turn cancels
/// that pending close. An entry that starts waiting while this session holds the seat between
/// turns makes it close at once; one that arrives during a turn makes it close when `turn` ends,
/// never inside it. The next turn then finds no live session and opens one again, which waits in
/// the queue like any other entry.
///
/// Calls are serialized by the owner, as `AutomationSessionOperating` requires. Cancelling an
/// `open` that waits in the queue takes the worker out of it; one cancelled after the seat was
/// granted gives the seat back before it throws. A failed `open` leaves nothing held, and `close`
/// is safe at any point and twice.
@MainActor
@Observable
public final class BrokeredAutomationSession: AutomationSessionOperating {

    /// Opens `application`, or its window titled `window`, on the granted session and lends a
    /// target over its seat. A seam for the controlled tests; the public init supplies the broker's.
    typealias Seating = @MainActor (AgentSession, _ application: String, _ window: String?) async throws
        -> (opened: TargetApp, target: SeatTarget)

    /// Reads the scene of the application `pid` through `runtime`. A seam for the controlled tests;
    /// the public init perceives through Ron's engine.
    typealias Perceiving = @MainActor (EngineRuntime, _ pid: pid_t) async throws -> SceneSnapshot

    /// Returns once `window` has passed, or throws when cancelled. A seam for the controlled tests,
    /// which let the window elapse when they choose; the public init sleeps on the task's clock.
    typealias IdleWaiting = @MainActor (_ window: Duration) async throws -> Void

    /// Reads the dialog the application `pid` has open. A seam for the controlled tests; the public
    /// init reads it through accessibility.
    typealias DialogReading = @MainActor (_ pid: pid_t) -> DialogButtonPress.OpenDialog?

    /// Escape quits DaVinci Resolve instead of closing its dialog, so it is never suggested there.
    static let quitsOnEscape: Set<String> = ["com.blackmagic-design.DaVinciResolve"]

    /// How long a worker keeps the seat after its turn ends with no other turn, Eliomar's choice:
    /// a quick follow-up ("and what is the first one called?") still finds the session and its
    /// context, and the window comes back to the person's screen soon after the worker goes quiet.
    static let idleWindow: Duration = .seconds(30)

    /// Where the session is with the computer, which is what the worker's row reads.
    enum Phase: Equatable {
        case idle
        case waiting
        /// The seat is this session's; the application is named once it is open.
        case holding(application: String?)
    }

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Lab")

    public private(set) var id: UUID?
    private(set) var phase = Phase.idle

    @ObservationIgnored private let broker: SeatBroker
    @ObservationIgnored private let label: String
    @ObservationIgnored private let knowledgeDirectory: URL
    @ObservationIgnored private let allowsDestructive: Bool
    /// Who macOS gives the grants to, as a missing grant's refusal names it: Braus, or the terminal
    /// that runs the command line, which holds them for it.
    @ObservationIgnored let grantee: String
    @ObservationIgnored private let missingGrant: @MainActor () -> PermissionKind?
    @ObservationIgnored private let requestGrants: @MainActor () -> Void
    @ObservationIgnored private let seating: Seating
    @ObservationIgnored private let switching: @MainActor (SeatTarget, pid_t, String) async throws -> Void
    @ObservationIgnored private let perceiving: Perceiving
    @ObservationIgnored private let idleWindow: Duration
    @ObservationIgnored private let waitIdle: IdleWaiting
    @ObservationIgnored private let readDialog: DialogReading

    /// Whether the seat a held target borrows stopped for good, which ends this session.
    @ObservationIgnored private let stoppedForGood: @MainActor (SeatTarget) -> Bool

    @ObservationIgnored private var lease: SeatLease?
    @ObservationIgnored private var target: SeatTarget?
    @ObservationIgnored private var runtime: EngineRuntime?
    @ObservationIgnored private var application: NSRunningApplication?
    @ObservationIgnored private var closing: Task<Void, Never>?
    public private(set) var closeWarning: String?
    @ObservationIgnored private var isInTurn = false
    @ObservationIgnored private var idleRelease: Task<Void, Never>?

    /// The application the last successful `open` seated, with its window's title in the first scene,
    /// empty when the scene had none. Kept across `close`, so a later turn can name it.
    @ObservationIgnored private var lastOpened: (name: String, bundleID: String, window: String)?

    /// `workerID` labels this session's entry in `SeatQueue.entries` as its `uuidString`, so two
    /// workers with one name still read their own position; no view shows that label.
    /// `knowledgeDirectory` is the Brain's, the command line's own, so what either learns applies
    /// to both. The broker is retained for the life of this session. `grantee` is who the person
    /// grants a missing permission to: the command line passes its terminal.
    public convenience init(
        broker            : SeatBroker,
        workerID          : UUID,
        knowledgeDirectory: URL,
        allowsDestructive : Bool = false,
        grantee           : String = "Braus"
    ) {
        self.init(
            broker            : broker,
            workerID          : workerID,
            knowledgeDirectory: knowledgeDirectory,
            allowsDestructive : allowsDestructive,
            grantee           : grantee,
            missingGrant      : { Permissions.firstMissing(of: [.screenRecording, .accessibility, .postEvent]) },
            requestGrants     : { _ = broker.requestMissingPermissions() },
            seating           : Self.seatedByTheBroker,
            perceiving        : Self.perceivedThroughTheEngine
        )
    }

    /// The broker's own path: `open(applicationNamed:windowTitled:)` launches an application that
    /// is not running and records its provenance, then the session lends a target over its seat.
    static let seatedByTheBroker: Seating = { session, application, window in
        let opened = try await session.open(applicationNamed: application, windowTitled: window)
        return (opened, try session.borrowedSeatTarget())
    }

    /// Ron's scene provider over the borrowed target, observed into the Brain through the call's
    /// recorder, or one of its own for a call made without the tools, and enriched by the Brain.
    static let perceivedThroughTheEngine: Perceiving = { runtime, pid in
        let perceived = try await runtime.scenes.currentScene(of: pid)
        return await recorder(runtime, sessionID: nil).observe(perceived)
    }

    /// Selects one exact current title among held windows, retaining the application's lease.
    static func switchWindow(_ target: SeatTarget, processID: pid_t, title: String) async throws {
        let seat = try target.agentSeat()
        _ = try await target.observe()
        let candidates = TargetEnumerator.windows(
            of: processID, includingHeld: seat.adoptedWindows.map(\.reference)
        ).filter { $0.title == title }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw AutomationFailure("The window title is missing or ambiguous. Read windows and use one exact title.")
        }
        guard let held = seat.adoptedWindows.first(where: {
            $0.id == candidate.windowNumber && $0.reference.processID == processID
        }) else {
            throw AutomationFailure("That window is not yet held by the Seat. Observe before switching; keep the session open.")
        }
        _ = try await seat.switchTarget(to: held)
    }

    /// The recorder of the call this task is performing, or one of the session's own.
    static func recorder(_ runtime: EngineRuntime, sessionID: UUID?) -> CallRecorder {
        CallRecorder.current ?? runtime.recorder(ActionContext(
            source: .system, streamID: "session-\(sessionID?.uuidString ?? "none")", sessionID: sessionID?.uuidString
        ))
    }

    /// The Knowledge directory whose memory this session's calls are recorded in.
    public var memoryDirectory: URL? { knowledgeDirectory }

    /// The application of the session, as a call's event names it.
    public var memoryApplication: String? {
        application.map { $0.bundleIdentifier ?? "pid.\($0.processIdentifier)" }
    }

    init(
        broker            : SeatBroker,
        workerID          : UUID,
        knowledgeDirectory: URL,
        allowsDestructive : Bool,
        grantee           : String = "Braus",
        missingGrant      : @escaping @MainActor () -> PermissionKind?,
        requestGrants     : @escaping @MainActor () -> Void,
        seating           : @escaping Seating,
        perceiving        : @escaping Perceiving,
        idleWindow        : Duration = idleWindow,
        waitIdle          : @escaping IdleWaiting = { try await Task.sleep(for: $0) },
        readDialog        : @escaping DialogReading = { DialogButtonPress.openDialog(of: $0) },
        switching         : @escaping @MainActor (SeatTarget, pid_t, String) async throws -> Void = switchWindow,
        stoppedForGood    : @escaping @MainActor (SeatTarget) -> Bool = {
            SeatAdmission.stoppedForGood(try? $0.agentSeat())
        }
    ) {
        self.broker             = broker
        self.label              = workerID.uuidString
        self.knowledgeDirectory = knowledgeDirectory
        self.allowsDestructive  = allowsDestructive
        self.grantee            = grantee
        self.missingGrant       = missingGrant
        self.requestGrants      = requestGrants
        self.seating            = seating
        self.perceiving         = perceiving
        self.idleWindow         = idleWindow
        self.waitIdle           = waitIdle
        self.readDialog         = readDialog
        self.stoppedForGood     = stoppedForGood
        self.switching          = switching
    }

    /// What the worker's row says about the computer, and nil while this session neither waits
    /// for a seat nor holds one. The position is read from `SeatQueue.entries`, never inferred.
    public var activity: String? {
        switch phase {
            case .idle                    : nil
            case .waiting                 : Self.waiting(label: label, in: broker.queue.entries)
            case .holding(let application): "Using \(application ?? "the computer")"
        }
    }

    /// True from the queue's grant until `close` has given the lease back, which is when the
    /// person can be offered to release the computer (§3.4). Waiting is not holding.
    public var holdsComputer: Bool {
        if case .holding = phase { true } else { false }
    }

    /// True while there is a window to watch: the seat is held and an application is open on it.
    public var hasScreen: Bool {
        if case .holding(.some) = phase { true } else { false }
    }

    /// A live view of the window this session drives, or nil while there is none to watch.
    /// Mount it only while `hasScreen`: a seat given back goes warm to the next entry, and a view
    /// left attached would show that worker's window.
    public func makeScreenView(contentsScale: CGFloat) -> NSView? {
        guard hasScreen, let lease else { return nil }
        return lease.session.makePreviewView(contentsScale: contentsScale)
    }

    /// The driven window's frame, for the view's proportions; zero while there is none to watch.
    public var screenFrame: CGRect {
        guard hasScreen, let lease else { return .zero }
        return lease.session.windowFrame
    }

    /// The seat as a worker's turn begins, which Braus puts ahead of the turn's prompt so the agent
    /// needs no status call: the live session to observe by its ID, or the application the last one had.
    ///
    /// Read inside `turn`, so no idle release is pending and a close already under way reads as no
    /// session. Nothing waits in the queue then: an `open` waits only inside a turn's tool call.
    public var turnStatus: String {
        let last = lastOpened.map { app in
            "\(app.name) (\(app.bundleID))" + (app.window.isEmpty ? "" : ", window \"\(app.window)\"")
        }
        guard let id else {
            return "Braus seat: no session is open." + (last.map { " The last one was on \($0)." } ?? "")
        }
        return "Braus seat: session \(id.uuidString) is open" + (last.map { " on \($0)" } ?? "")
            + ". Observe it with this session ID before acting."
    }

    /// "Waiting for the computer", with how many entries are ahead when exactly one waiting entry
    /// carries `label`. Entries list the acting ones first and the waiting ones in arrival order,
    /// so an entry's index is the number ahead of it.
    static func waiting(label: String, in entries: [SeatQueue.Entry]) -> String {
        let mine = entries.indices.filter { entries[$0].label == label && entries[$0].state == .waiting }
        guard mine.count == 1, let index = mine.first else { return "Waiting for the computer" }
        return "Waiting for the computer (\(index) ahead)"
    }

    /// Checks the grants, waits for a seat, opens the application on it and returns the first
    /// scene, which the Brain observes. A missing grant is asked for through the broker and
    /// refused at once, before the queue. Any failure after the seat was granted closes, so the
    /// seat is given back before this throws; a cancellation is thrown as it came.
    public func open(application word: String, window title: String?) async throws -> SceneSnapshot {
        // A release between turns may still be finishing; this open comes after it.
        await closing?.value
        // A seat that stopped for good ends its session: this open replaces it, as close_session would.
        if case .holding = phase, let target, stoppedForGood(target) { await close() }
        if case .holding = phase, let target, let running = application, let title,
           (running.bundleIdentifier?.caseInsensitiveCompare(word) == .orderedSame
            || running.localizedName?.caseInsensitiveCompare(word) == .orderedSame
            || lastOpened?.name.caseInsensitiveCompare(word) == .orderedSame) {
            try await switching(target, running.processIdentifier, title)
            let scene = try await perceivedScene()
            if var opened = lastOpened {
                opened.window = scene.windowTitle
                lastOpened = opened
            }
            return scene
        }
        guard phase == .idle, closing == nil else {
            throw AutomationFailure("A Seat is already open. Observe it, or pass this app and an exact window title "
                + "to select another held window. Close the session before opening another app.")
        }
        if let missing = missingGrant() {
            requestGrants()
            throw AutomationFailure(Self.refusal(missing: missing, grantee: grantee))
        }
        phase = .waiting
        let lease: SeatLease
        do {
            lease = try await broker.queue.acquire(label)
        } catch {
            phase = .idle
            throw error
        }
        self.lease = lease
        phase = .holding(application: nil)
        do {
            // The queue can admit an entry in the same turn its wait was cancelled.
            try Task.checkCancellation()
            let seated = try await seating(lease.session, word, title)
            target  = seated.target
            runtime = EngineRuntime(knowledgeDirectory: knowledgeDirectory, seat: seated.target)
            guard let pid = seated.opened.pid, let running = NSRunningApplication(processIdentifier: pid) else {
                throw AutomationFailure("\(seated.opened.name) opened and then could not be found running.")
            }
            application = running
            phase = .holding(application: seated.opened.name)
            id = UUID()
            let scene = try await perceivedScene()
            lastOpened = (seated.opened.name, seated.opened.bundleID, scene.windowTitle)
            watchQueue(for: lease)
            return scene
        } catch {
            // A modal the application has open keeps the first observation off the adopted window.
            var blocking: String?
            if case .initialWindowChanged? = error as? SeatDrivingFailure, let running = application {
                blocking = readDialog(running.processIdentifier).map {
                    Self.blocking(
                        $0,
                        application: running.localizedName ?? "the application",
                        bundleID   : running.bundleIdentifier
                    )
                }
            }
            await close()
            throw Self.refusal(for: error, blocking: blocking)
        }
    }

    /// The refusal for `error`, with the sentence naming a blocking dialog after it when there is one.
    static func refusal(for error: any Error, blocking: String?) -> any Error {
        let refusal = refusal(for: error)
        guard let blocking, let failure = refusal as? AutomationFailure else { return refusal }
        return AutomationFailure(failure.description + " " + blocking)
    }

    /// Names `dialog`, open in `application`, and how the agent can close it and open again.
    static func blocking(
        _ dialog   : DialogButtonPress.OpenDialog,
        application: String,
        bundleID   : String?
    ) -> String {
        let named   = dialog.title.isEmpty ? "an untitled \(dialog.role)" : "the \(dialog.role) \"\(dialog.title)\""
        let buttons = dialog.buttons.isEmpty
            ? "Accessibility cannot read its buttons."
            : "Its buttons: \(dialog.buttons.joined(separator: ", "))."
        let fact = "\(application) has \(named) open, which blocks the window the session adopted. " + buttons
        let cancel  = dialog.buttons.first { ActionPolicy.normalizedLabel($0) == "cancel" }
        let escapes = dialog.buttons.isEmpty && !quitsOnEscape.contains(bundleID ?? "")
        // Only a titled modal dialog is listed among the windows open_session can adopt.
        guard dialog.isListed, !dialog.title.isEmpty, !dialog.buttons.isEmpty || escapes else {
            let way = if let cancel {
                " with its \"\(cancel)\" button"
            } else if !dialog.buttons.isEmpty {
                " with one of its buttons"
            } else if escapes {
                " with Escape"
            } else {
                ""
            }
            return fact + " Ask the person to close it\(way), then open \(application) again."
        }
        let answer = if let cancel {
            "press \"\(cancel)\""
        } else if !dialog.buttons.isEmpty {
            "press one of its buttons"
        } else {
            "press_key escape"
        }
        return fact + " To close it, open_session on \(application) with window \"\(dialog.title)\", \(answer), "
            + "then close_session and open \(application) again; or ask the person to close it."
    }

    /// The installed and running applications `query` names, ranked as `open` resolves a name, so
    /// what the worker is offered and what it may open cannot disagree. Needs no seat and no grant.
    public func applications(matching query: String?) async throws -> [ApplicationCandidate] {
        Self.candidates(ApplicationOpening.ranked(query, in: TargetEnumerator.targets()))
    }

    /// The bundle ID `open` resolves `application` to, through the same `ApplicationOpening.resolve`, so a name in
    /// the person's language routes as the app's own does. Nil, by design, for a name `open` would refuse: that
    /// open then says why. Needs no seat and no grant.
    public func resolvedBundleID(of application: String) async -> String? {
        try? ApplicationOpening.resolve(application, in: TargetEnumerator.targets()).bundleID
    }

    public func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] {
        let held = (try? target?.agentSeat().adoptedWindows.map(\.reference)) ?? []
        return TargetEnumerator.windows(of: processID, includingHeld: held).map {
            WindowRow(layer: 0, frame: $0.frame, title: $0.title, number: $0.windowNumber)
        }
    }

    /// `apps` as the worker reads them, in their order, each one's folder added only where two
    /// of them share a name, since the name alone would not say which is which. The application
    /// whose bundle ID is `defaultBrowser` is marked as the default browser.
    static func candidates(
        _ apps        : [TargetApp],
        defaultBrowser: String? = WebBrowsers.defaultBundleID()
    ) -> [ApplicationCandidate] {
        let shared = Set(Dictionary(grouping: apps, by: \.name).filter { $0.value.count > 1 }.keys)
        return apps.map { app in
            let folder = app.bundleURL.map {
                ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            }
            return ApplicationCandidate(
                name            : app.name,
                bundleID        : app.bundleID,
                version         : app.version,
                isRunning       : app.isRunning,
                location        : shared.contains(app.name) ? folder : nil,
                isDefaultBrowser: !app.bundleID.isEmpty && app.bundleID == defaultBrowser
            )
        }
    }

    public func observe() async throws -> SceneSnapshot {
        do {
            return try await perceivedScene()
        } catch {
            throw Self.refusal(for: error)
        }
    }

    /// The scene `observe` returns, with the seat's error as it came, so `open` can tell which it was.
    private func perceivedScene() async throws -> SceneSnapshot {
        let (application, runtime, _) = try current()
        let observingSession = id
        do {
            let scene = try await perceiving(runtime, application.processIdentifier)
            guard id == observingSession else {
                throw AutomationFailure("The session changed while observing. Use status and observe the current session.")
            }
            return scene
        } catch {
            if error as? ObservationUnavailable == .notAssigned, id == observingSession {
                await close()
                let message = "The observed session ended because it has no assigned application. "
                    + "Use status and list current windows; open the intended window explicitly before continuing. "
                    + "Earlier effects may remain. Do not replay input automatically."
                throw AutomationFailure(message + (closeWarning.map { " " + $0 } ?? ""))
            }
            throw error
        }
    }

    /// A fresh scene with the pixels it was read from, for a person who asks to see what the agent sees.
    public func observeWithImage() async throws -> (scene: SceneSnapshot, image: CGImage?) {
        let scene = try await observe()
        return (scene, target?.lastSceneImage)
    }

    public func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws
        -> ActOutcome {
        try await act(target: target, verb: verb, section: section, desiredState: desiredState, isDryRun: false)
    }

    /// `act`, or with `isDryRun` resolved and reported without acting, as the command line's `--dry-run` asks.
    package func act(
        target      : String,
        verb        : ActionVerb,
        section     : String?,
        desiredState: ControlState?,
        isDryRun    : Bool
    ) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        if case .refuse(let sentence) = try await SeatAdmission.awaited(
            seat.agentSeat(),
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        if verb == .setToggle, desiredState != .on && desiredState != .off {
            throw AutomationFailure("set_toggle requires value on or off.")
        }
        let request = ActionRequest(
            processID: application.processIdentifier,
            bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName: application.localizedName ?? "application",
            target: target, verb: verb, section: section, desiredState: desiredState, isDryRun: isDryRun
        )
        let remotePanel = try seat.agentSeat().holdsRemoteFilePanel
        let inFront     = Self.preparesMenuInFront(application)
        let menus       = MenuItemCommands(
            menuCommand(application, runtime, try seat.agentSeat(), inFront: inFront),
            inFront: inFront ? application.localizedName ?? "The application" : nil
        )
        return await enriched(runtime.engine(
            recorder                    : Self.recorder(runtime, sessionID: id),
            allowsDestructive           : allowsDestructive,
            contextMenusOnTextFieldsOnly: Self.drawsMenusUnderThePointer(application),
            selectsFieldsByTripleClick  : remotePanel,
            refusesMenuOpeningClicks    : remotePanel,
            windowClosure               : windowClosure(of: seat),
            menus                       : menus
        ).act(request), by: runtime)
    }

    public func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        if case .refuse(let sentence) = try await SeatAdmission.awaited(
            seat.agentSeat(),
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        if case .contextMenu(let control, let item) = input {
            let selector = SeatContextMenuSelector(target: seat, pipeline: ProductionPerception.pipeline())
            let chosen = try await selector.select(
                item: item, on: control,
                identity: SeatDriving.ApplicationIdentity(
                    bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
                    name: application.localizedName ?? "application"
                ),
                section: section,
                permissions: ActionPermissions(
                    allowsDestructive: allowsDestructive,
                    contextMenusOnTextFieldsOnly: Self.drawsMenusUnderThePointer(application)
                ),
                report: SelectorReporting.reporting(
                    to: CallRecorder.current,
                    bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
                )
            )
            return await enriched(chosen, by: runtime)
        }
        let request = InputRequest(
            processID: application.processIdentifier,
            bundleID : application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName  : application.localizedName ?? "application",
            input    : input,
            section  : section
        )
        // Of these inputs only Escape closes a window: the engine refuses text that carries one.
        var closesTheWindow = false
        if case .pressKey(let chord, _) = input { closesTheWindow = chord.key == .escape }
        return await enriched(runtime.engine(
            recorder                    : Self.recorder(runtime, sessionID: id),
            allowsDestructive           : allowsDestructive,
            contextMenusOnTextFieldsOnly: Self.drawsMenusUnderThePointer(application),
            selectsFieldsByTripleClick  : try seat.agentSeat().holdsRemoteFilePanel,
            windowClosure               : closesTheWindow ? windowClosure(of: seat) : WindowClosureGuard()
        ).deliver(request), by: runtime)
    }

    public func menu(path: String) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        let agentSeat = try seat.agentSeat()
        if case .refuse(let sentence) = await SeatAdmission.awaited(
            agentSeat,
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        let processID = application.processIdentifier
        let platform = TargetPlatform.chosen(
            bundleURL       : application.bundleURL,
            bundleIdentifier: application.bundleIdentifier
        )
        let inFront = Self.pressesMenuInFront(
            platform,
            bundleIdentifier     : application.bundleIdentifier,
            isEnabledInBackground: { MenuBarCommand.isEnabled(path, processID: processID) }
        )
        let command = menuCommand(application, runtime, agentSeat, inFront: inFront)
        return try await PerceivedCommand.perform(
            bundleID: application.bundleIdentifier ?? "pid.\(processID)",
            recorder: Self.recorder(runtime, sessionID: id),
            perceive: { try await runtime.scenes.currentScene(of: processID) }
        ) { observe in
            try await command(path, processID, observe)
        }
    }

    /// The menu command `menu` runs, which a text format toggle is carried out through as well,
    /// pressed during a brief activation when `inFront` is true (`preparesMenuInFront`).
    private func menuCommand(
        _ application: NSRunningApplication,
        _ runtime    : EngineRuntime,
        _ agentSeat  : AgentSeat,
        inFront      : Bool
    ) -> MenuItemCommands.Command {
        let closingRefusal    = closingRefusal(application, agentSeat)
        let allowsDestructive = self.allowsDestructive
        let settling          = runtime.settling
        return { path, processID, observe in
            if inFront {
                return try await MenuBarCommand.performInFront(
                    path,
                    processID: processID,
                    allowsDestructive: allowsDestructive,
                    closingRefusal: closingRefusal,
                    withFront: { command in
                        let outcome = await agentSeat.performMenuCommandBrieflyInFront(
                            when: { MenuBarCommand.isEnabled(path, processID: processID) },
                            performOnce: command
                        )
                        if case .ready = outcome { return nil }
                        return Self.briefMenuFailure(outcome)
                    },
                    frontReturned: { agentSeat.frontIsBackAfterCommand },
                    settling: settling,
                    observe: observe
                )
            }
            return try await MenuBarCommand.perform(
                path,
                processID        : processID,
                allowsDestructive: allowsDestructive,
                closingRefusal   : closingRefusal,
                settling         : settling,
                observe          : observe
            )
        }
    }

    /// What closing the window `seat` targets would do to its application, read now. Nothing is read
    /// when the person allowed destructive actions, because nothing would be refused.
    private func windowClosure(of seat: SeatTarget) -> WindowClosureGuard {
        guard !allowsDestructive, let seat = try? seat.agentSeat(), let facts = seat.windowClosureFacts
        else { return WindowClosureGuard() }
        return WindowClosureGuard(
            mayEndTheApplication: facts.mayEndTheApplication,
            controlFrames       : facts.controlFrames
        )
    }

    /// The sentence a command that closes the target window is refused with, given what it is, or
    /// nil when it may be sent. The facts are read only when a closing command is asked for.
    private func closingRefusal(
        _ application: NSRunningApplication,
        _ seat       : AgentSeat
    ) -> (String) -> String? {
        let allowsDestructive = allowsDestructive
        let name = application.localizedName ?? "the application"
        return { what in
            guard !allowsDestructive, seat.windowClosureFacts?.mayEndTheApplication == true else { return nil }
            let window = seat.currentTarget.flatMap { CGWindowID(exactly: $0.id) }.flatMap {
                (CGWindowListCopyWindowInfo(.optionIncludingWindow, $0) as? [[String: Any]])?
                    .first?[kCGWindowName as String] as? String
            } ?? ""
            return ActionPolicy.windowClosureRefusal(
                what,
                window      : window,
                application : name,
                alternatives: []
            )
        }
    }

    /// Whether a menu command of this application is read and pressed during a verified brief
    /// activation. Adobe's UXP hosts, TextEdit and Preview leave menus disabled while driven in the
    /// background (ADR 0013, 0029, 0042); Safari opens no window from File > New Window until it is
    /// active (ADR 0038). A browser found by Chrome's renderer helper keeps its window items
    /// disabled until it has a key window (ADR 0029, 14/10/2026); Electron and CEF hosts, found
    /// by their framework, are not measured. Other native hosts remain separately qualified.
    nonisolated static func preparesMenuInFront(_ platform: TargetPlatform, bundleIdentifier: String?) -> Bool {
        platform == .adobeUXP || platform == .webKitBrowser || platform == .embeddedRenderer(.rendererHelper)
            || bundleIdentifier == "com.apple.TextEdit" || bundleIdentifier == "com.apple.Preview"
    }

    /// Whether this one menu command is pressed in the brief activation. A Chromium browser
    /// presses an item that reads enabled in the background where it is, with no activation, and
    /// pays the activation only for a disabled one (ADR 0029, 14/10/2026). The other in-front
    /// applications always pay it: Adobe's enabled items are stale (ADR 0020), TextEdit's titles
    /// validate only in front (ADR 0029), Preview's are disabled in the background (ADR 0042), and Safari's enabled New Window opens nothing (ADR 0038).
    /// `isEnabledInBackground` is read once, and only for a Chromium browser.
    nonisolated static func pressesMenuInFront(
        _ platform           : TargetPlatform,
        bundleIdentifier     : String?,
        isEnabledInBackground: () -> Bool
    ) -> Bool {
        guard preparesMenuInFront(platform, bundleIdentifier: bundleIdentifier) else { return false }
        guard platform == .embeddedRenderer(.rendererHelper) else { return true }
        return !isEnabledInBackground()
    }

    /// `preparesMenuInFront` for `application`, its platform read now.
    static func preparesMenuInFront(_ application: NSRunningApplication) -> Bool {
        preparesMenuInFront(
            TargetPlatform.chosen(bundleURL: application.bundleURL, bundleIdentifier: application.bundleIdentifier),
            bundleIdentifier: application.bundleIdentifier
        )
    }

    private static func briefMenuFailure(_ outcome: BriefActivationOutcome) -> String {
        switch refresh(after: outcome) {
            case .stillDisabled(let reason):
                return reason ?? "It was brought forward for a moment, and the item did not read enabled before the "
                    + "moment ended, so nothing was pressed."
            case .blockedByDialog: return "A dialog is open; answer it before another menu command."
            case .readAgain: return "The admitted menu command was not dispatched."
        }
    }

    /// What a moment in front answered, as the menu command reads it: the item is read again only
    /// when it read enabled in front, a dialog open in the seat gets the dialog's own refusal, and
    /// any other refusal says why in one sentence a worker can repeat, with none of the seat's
    /// internals.
    static func refresh(after outcome: BriefActivationOutcome) -> MenuBarCommand.Refresh {
        switch outcome {
            case .ready:
                return .readAgain
            case .notReady:
                return .stillDisabled(reason: nil)
            case .frontElsewhere:
                return .stillDisabled(reason: "It was brought forward for a moment, but another application came to "
                    + "the front meanwhile and was left there, so nothing was pressed. The command can be tried again.")
            case .handbackNotVerified:
                return .stillDisabled(reason: "It was brought forward for a moment, but the return to "
                    + "the person's own window was not verified.")
            case .refused(let refusal):
                let because: String
                switch refusal {
                    case .dialogOpen         : return .blockedByDialog
                    case .noFocusRecovery    : because = "this seat cannot give the person's focus back"
                    case .seatNotReady       : because = "the seat is busy"
                    case .noUserWindow       : because = "no window of the person's own is in front to come back to"
                    case .targetNotPrepared  : because = "its window could not be identified"
                    case .frontRequestRefused: because = "macOS refused to bring it forward"
                }
                return .stillDisabled(reason: "It could not be brought forward for a moment, because \(because).")
        }
    }

    public func press(button: String) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        let agentSeat = try seat.agentSeat()
        if case .refuse(let sentence) = await SeatAdmission.awaited(
            agentSeat,
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        let processID = application.processIdentifier
        let dialogs   = agentSeat.openDialogs.map(\.windowNumber)
        let allowsDestructive = self.allowsDestructive
        let closingRefusal = closingRefusal(application, agentSeat)
        return try await PerceivedCommand.perform(
            bundleID: application.bundleIdentifier ?? "pid.\(processID)",
            recorder: Self.recorder(runtime, sessionID: id),
            perceive: { try await runtime.scenes.currentScene(of: processID) }
        ) { observe in
            try await DialogButtonPress.perform(button, processID: processID, dialogs: dialogs,
                                                allowsDestructive: allowsDestructive, closingRefusal: closingRefusal,
                                                observe: observe)
        }
    }

    public func select(control: String, item: String) async throws -> ActOutcome {
        try await select(control: control, item: item, dryRun: false).outcome
    }

    /// `select` with what the command line asks of it: a dry run, the opened menu and the captures it
    /// saves as evidence, and the menu's receipt returned beside the outcome.
    package func select(
        control  : String,
        item     : String,
        dryRun   : Bool,
        onMenu   : @escaping @MainActor @Sendable (ContextMenu) -> Void = { _ in },
        onCapture: @escaping @MainActor @Sendable (String, CGImage) throws -> Void = { _, _ in }
    ) async throws -> (outcome: ActOutcome, receipt: PopupMenuReceipt?) {
        let (application, runtime, target) = try current()
        let selector = SeatDropdownSelector(target: target, pipeline: ProductionPerception.pipeline(), windows: runtime.windows)
        let result = try await selector.select(
            control: control, item: item,
            identity: SeatDriving.ApplicationIdentity(
                bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
                name: application.localizedName ?? "application"
            ),
            permissions: ActionPermissions(allowsDestructive: allowsDestructive),
            dryRun: dryRun,
            onMenu: onMenu,
            onCapture: onCapture,
            report: SelectorReporting.reporting(
                to: CallRecorder.current,
                bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
            )
        )
        return (await enriched(result.outcome, by: runtime), result.receipt)
    }

    /// Flushes the Brain, ends the borrow, finishes with the application and gives the seat back.
    ///
    /// The cleanup runs in a task of its own, so a cancelled caller still gives the seat back and a
    /// second call waits for the first. What finishing leaves the person to do (an application the
    /// seat could not confirm home, so left running) has no channel in this role, so it is logged.
    public func close() async {
        idleRelease?.cancel()
        idleRelease = nil
        if let closing { await closing.value; return }
        guard phase != .idle else { return }
        closeWarning = nil
        let runtime = self.runtime
        let target  = self.target
        let lease   = self.lease
        self.runtime = nil
        self.target  = nil
        self.lease   = nil
        application  = nil
        id           = nil
        let cleanup = Task {
            await runtime?.finish()
            await target?.stop()
            if let lease {
                closeWarning = await lease.session.finishUsingApp()
                if let left = closeWarning {
                    Self.log.error("A worker's session closed with this left to do: \(left, privacy: .public)")
                }
                lease.giveBack()
            }
            // Reset here, so every caller awaiting this task finds the session idle when it resumes.
            closing = nil
            phase   = .idle
        }
        closing = cleanup
        await cleanup.value
    }

    /// Runs one turn of the worker's agent, and closes afterwards when another entry is waiting in
    /// the queue, which gives the seat back; otherwise it closes once `idleWindow` passes with no
    /// new turn. Starting a turn cancels that pending close, and nothing is released while `body`
    /// runs, since the agent may be between an observation and an act.
    public func turn(_ body: () async throws -> Void) async throws {
        idleRelease?.cancel()
        idleRelease = nil
        isInTurn = true
        do {
            try await body()
        } catch {
            await endTurn()
            throw error
        }
        await endTurn()
    }

    private func endTurn() async {
        isInTurn = false
        await releaseIfSomeoneWaits()
        releaseWhenIdle()
    }

    /// Closes once an open session has gone `idleWindow` without a turn. The wait is tied to the
    /// lease held now, so one that outlives a close, or returns under a later lease, closes nothing.
    private func releaseWhenIdle() {
        guard let lease, id != nil, closing == nil else { return }
        idleRelease?.cancel()
        idleRelease = Task { [weak self, waitIdle, idleWindow] in
            do {
                try await waitIdle(idleWindow)
            } catch {
                // The wait ends early only when cancelled: a turn started or the session closed.
                return
            }
            guard let self, !Task.isCancelled, self.lease === lease, !isInTurn, closing == nil else { return }
            await close()
        }
    }

    /// Closes when an open session is idle between turns and an entry is waiting for the seat.
    private func releaseIfSomeoneWaits() async {
        guard !isInTurn, id != nil, closing == nil,
              broker.queue.entries.contains(where: { $0.state == .waiting })
        else { return }
        await close()
    }

    /// Reads the queue while `lease` is held and again on every change of its entries, so a holder
    /// idle between turns learns of a new waiting entry without a turn to end.
    private func watchQueue(for lease: SeatLease) {
        guard self.lease === lease else { return }
        let isSomeoneWaiting = withObservationTracking {
            broker.queue.entries.contains { $0.state == .waiting }
        } onChange: { [weak self] in
            // Called before the change lands, so the queue is read again once it has.
            Task { @MainActor in self?.watchQueue(for: lease) }
        }
        if isSomeoneWaiting { Task { await releaseIfSomeoneWaits() } }
    }

    /// Whether a custom widget of `application` opens its contextual menu under the person's pointer
    /// rather than at the click: measured on DaVinci Resolve's media pool, a Qt application, whose menu
    /// opened on the person's screen and left the seat suspended until it was closed there.
    static func drawsMenusUnderThePointer(_ application: NSRunningApplication) -> Bool {
        let choice = TargetPlatform.chosen(
            bundleURL       : application.bundleURL,
            bundleIdentifier: application.bundleIdentifier
        )
        if case .qtToolkit = choice { return true }
        return false
    }

    /// `outcome` with its scene enriched by the Brain, so an action's scene reads like an observed one.
    /// The engine already recorded the transition, so the scene is not observed again.
    private func enriched(_ outcome: ActOutcome, by runtime: EngineRuntime) async -> ActOutcome {
        guard let scene = outcome.scene else { return outcome }
        return outcome.with(scene: await Self.recorder(runtime, sessionID: id).enrich(scene))
    }

    private func current() throws -> (NSRunningApplication, EngineRuntime, SeatTarget) {
        guard let application, !application.isTerminated, let runtime, let target else {
            throw AutomationFailure("No live application session. Use windows and open_session, then observe.")
        }
        return (application, runtime, target)
    }

    /// The window the seat's latest observation captured: the latest scene's, or the one under its pop-up.
    public var observedWindowNumber: Int? { target?.lastCapturedWindow?.id }

    /// The seat the held target borrows, nil while none is held: for the command line, which says the
    /// seat's state when a selection stops and checks a batch's window between its steps.
    package var heldSeat: AgentSeat? { try? target?.agentSeat() }

    /// The windows of the application the latest scene saw on the person's screen, outside the seat,
    /// each named by its window server title and the kind the seat read, in the worker's sentence.
    public var seatNotice: String? {
        guard let target, let application else { return nil }
        let seat = try? target.agentSeat()
        return SeatErrorMapper.notice(
            for        : target.lastShownOutsideSeat.map(\.windowNumber),
            application: application.localizedName ?? "the application"
        ) { number in
            Self.windowName(number, role: seat?.surfaceRole(ofWindow: number))
        }
    }

    /// "window 7631 "Change Clip Speed" (dialog)", leaving out what nothing could read.
    static func windowName(
        _ number: Int,
        role    : SurfaceRole?
    ) -> String {
        let row = CGWindowID(exactly: number).flatMap {
            (CGWindowListCopyWindowInfo(.optionIncludingWindow, $0) as? [[String: Any]])?.first
        }
        let title = row?[kCGWindowName as String] as? String ?? ""
        let kind: String? = switch role {
            case .document?        : "window"
            case .dialog?          : "dialog"
            case .interactivePanel?: "panel"
            case .contextualMenu?  : "menu"
            case .tooltip?         : "tooltip"
            case .decoration?      : "decoration"
            case nil               : nil
        }
        return "window \(number)" + (title.isEmpty ? "" : " \"\(title)\"") + (kind.map { " (\($0))" } ?? "")
    }

    /// The refusal for a missing grant: which one, that nothing was opened, and what to do, naming
    /// `grantee` as the one to allow in System Settings.
    static func refusal(
        missing kind: PermissionKind,
        grantee     : String = "Braus"
    ) -> String {
        let (name, pane) = switch kind {
            case .screenRecording: ("Screen Recording", "Screen & System Audio Recording")
            case .accessibility  : ("Accessibility", "Accessibility")
            case .postEvent      : ("Keyboard and Mouse Control", "Accessibility")
        }
        return "Braus is missing the macOS \(name) permission, so this worker cannot use the computer, "
            + "and nothing was opened. macOS was asked to show its prompt; if none appears, allow \(grantee) in "
            + "System Settings > Privacy & Security > \(pane)"
            + (kind == .screenRecording ? ", then quit and reopen \(grantee)" : "")
            + ". Do not retry until it is granted."
    }

    /// The worker's sentence for an application that showed no window or a seat that could not
    /// observe, and every other error as it came, so a cancellation stays a cancellation.
    static func refusal(for error: any Error) -> any Error {
        if case .initialWindowChanged(let expected, let observed)? = error as? SeatDrivingFailure {
            let actual = observed.map { String($0.windowNumber) } ?? "an unattested window"
            return AutomationFailure(
                "The first observation did not match the adopted identity of window \(expected.windowNumber) "
                    + "(reported window: \(actual)). "
                    + "No scene from that window was returned and no input was sent. "
                    + "List the current windows and open the intended one again.")
        }
        // The seat's own reason reaches the agent as the router prints it, which for an enum is its
        // case and payload: the sentence is the one the seat's mapper writes for a person.
        if error is ObservationUnavailable {
            return AutomationFailure(SeatErrorMapper.message(for: error))
        }
        if let refused = error as? SeatBrokerError, case .windowOnAnotherDesktop = refused {
            return AutomationFailure(refused.localizedDescription)
        }
        guard case .noWindowShown(let name, let seconds, let wasLaunched, let wasQuit)? = error as? SeatBrokerError
        else { return error }
        let fact = wasLaunched
            ? "\(name) was launched in the background and showed no window within \(seconds) s."
            : "\(name) is running and showed no window within \(seconds) s."
        return AutomationFailure(fact
            + " Some applications show their first window only once they are brought to the front "
            + "(TextEdit's iCloud Open panel waits for that), and the seat never brings an application "
            + "to the front. Nothing was adopted and the computer was given back. "
            + ApplicationOpening.unseated(name, wasLaunched: wasLaunched, wasQuit: wasQuit)
            + " Open \(name) with a window yourself and ask again, or use another application.")
    }
}
