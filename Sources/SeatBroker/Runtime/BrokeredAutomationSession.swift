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
import SeatInput
import AccessibilityFacts
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

    /// The bundle ID of the application `word` names, as the seat would open it, before anything is launched or
    /// adopted. A seam for the controlled tests; the public init resolves as `AgentSession.open` does.
    typealias Resolving = @MainActor (_ word: String) async throws -> String

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
    @ObservationIgnored private let runningApplication: @MainActor (pid_t) -> NSRunningApplication?
    @ObservationIgnored private let idleWindow: Duration
    @ObservationIgnored private let waitIdle: IdleWaiting
    @ObservationIgnored private let readDialog: DialogReading

    /// Whether the seat a held target borrows stopped for good, which ends this session.
    @ObservationIgnored private let stoppedForGood: @MainActor (SeatTarget) -> Bool

    @ObservationIgnored private var lease: SeatLease?
    @ObservationIgnored private var target: SeatTarget?
    @ObservationIgnored private var runtime: EngineRuntime?
    /// The application open on the seat, recorded in `SeatHolds` under `holdKey` while it is set, so no other
    /// session's adapter changes it behind the seat.
    @ObservationIgnored private var application: NSRunningApplication? {
        didSet { SeatHolds.set(memoryApplication, for: holdKey) }
    }
    @ObservationIgnored let holdKey = UUID()
    @ObservationIgnored private var closing: Task<Void, Never>?
    public private(set) var closeWarning: String?
    @ObservationIgnored private var isInTurn = false
    @ObservationIgnored private var humanDetails: HumanInterventionDetails?
    @ObservationIgnored private var idleRelease: Task<Void, Never>?
    /// Pins the current lease across turn endings while the person controls its preview.
    @ObservationIgnored
    private var humanIntervention: UUID?
    @ObservationIgnored private var lendingWatch: Task<Void, Never>?
    @ObservationIgnored private weak var previewControl: HumanPreviewControl?

    /// All visible held windows, in WindowServer coordinates and front-to-back order.
    public private(set) var heldWindows: [HeldWindow] = []
    @ObservationIgnored private var windowPreviews = WindowPreviewStreams()
    @ObservationIgnored private var heldWindowsDelivery: Task<Void, Never>?

    /// The application the last successful `open` seated, with its window's title in the first scene,
    /// empty when the scene had none. Kept across `close`, so a later turn can name it.
    @ObservationIgnored private var lastOpened: (name: String, bundleID: String, window: String)?

    /// The claims every route of every Braus process takes on an app (`AppClaims`, I03), this session's owner in
    /// them (its worker, as the worker's native session), and its hold of the app it opened: dropped at `close`, or
    /// with the session.
    @ObservationIgnored private let claims    : AppClaims
    @ObservationIgnored private let claimOwner: AnyHashable
    @ObservationIgnored private let resolving : Resolving
    @ObservationIgnored private var claim     : AppClaims.Hold?

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
        grantee           : String = "Braus",
        claims            : AppClaims = .shared
    ) {
        self.init(
            broker            : broker,
            workerID          : workerID,
            knowledgeDirectory: knowledgeDirectory,
            allowsDestructive : allowsDestructive,
            grantee           : grantee,
            claims            : claims,
            resolving         : Self.resolvedByTheSeat,
            missingGrant      : { Permissions.firstMissing(of: [.screenRecording, .accessibility, .postEvent]) },
            requestGrants     : { _ = broker.requestMissingPermissions() },
            seating           : Self.seatedByTheBroker,
            perceiving        : Self.perceivedThroughTheEngine
        )
    }

    /// The seat's own resolution, the one `AgentSession.open(applicationNamed:)` makes, without opening anything.
    static let resolvedByTheSeat: Resolving = { word in
        try await ApplicationOpening.resolvedOffMain(word, in: TargetEnumerator.preparedTargets()).bundleID
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
        let reading = ContinuousClock.now
        BrokeredAutomationSession.log.info("scene read: capture/perception starting")
        let perceived = try await runtime.scenes.currentScene(of: pid)
        BrokeredAutomationSession.log.info("scene read: capture/perception finished in \(reading.duration(to: .now).description, privacy: .public)")
        try Task.checkCancellation()
        let recording = ContinuousClock.now
        let scene = await recorder(runtime, sessionID: nil).observe(perceived)
        BrokeredAutomationSession.log.info("scene read: memory observation finished in \(recording.duration(to: .now).description, privacy: .public)")
        try Task.checkCancellation()
        return scene
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

    // A session dropped without close still forgets its hold.
    deinit { SeatHolds.set(nil, for: holdKey) }

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
        claims            : AppClaims = AppClaims(),
        resolving         : @escaping Resolving = { $0 },
        missingGrant      : @escaping @MainActor () -> PermissionKind?,
        requestGrants     : @escaping @MainActor () -> Void,
        seating           : @escaping Seating,
        perceiving        : @escaping Perceiving,
        runningApplication: @escaping @MainActor (pid_t) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) },
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
        self.claims             = claims
        self.claimOwner         = AnyHashable(workerID)
        self.resolving          = resolving
        self.knowledgeDirectory = knowledgeDirectory
        self.allowsDestructive  = allowsDestructive
        self.grantee            = grantee
        self.missingGrant       = missingGrant
        self.requestGrants      = requestGrants
        self.seating            = seating
        self.perceiving         = perceiving
        self.runningApplication = runningApplication
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

    /// How many fixed-window views stream at once, the main window's included; the observation's
    /// stream is reserved apart.
    nonisolated public static let windowStreamLimit = WindowStreamTiers.streamLimit

    /// Returns a fixed-window capture view, or nil when absent or `windowStreamLimit` is reached.
    /// The main window runs at 30 fps capped to 1080p; the others at the tier `WindowStreamTiers`
    /// gives them as windows open, close and change order.
    /// A view waiting for a retiring slot starts after confirmed release. Views stop on closure
    /// or session release and never follow another window.
    public func makeWindowView(windowNumber: Int, contentsScale: CGFloat) -> NSView? {
        guard hasScreen, lease != nil else { return nil }
        return windowPreviews.makeView(windowNumber: windowNumber, contentsScale: contentsScale)
    }

    /// Resizes a held window as the person resizes its picture on their screen, and answers the size
    /// the window took (`AgentSeat.resizeHeldWindow`); nil while the person has the application or
    /// the seat cannot write it now.
    public func resizeHeldWindow(_ windowNumber: Int, to size: CGSize) -> CGSize? {
        guard hasScreen, humanIntervention == nil, closing == nil else { return nil }
        return heldSeat?.resizeHeldWindow(windowNumber, to: size)
    }

    private func watchHeldWindows() {
        guard let seat = heldSeat, let lease else { return }
        windowPreviews = lease.session.windowPreviews
        windowPreviews.begin()
        seat.heldWindowsChanged = { [weak self, weak seat] in
            guard let self, let seat, self.heldSeat === seat, self.heldWindowsDelivery == nil else { return }
            // Coalesce event bursts, without starting a repeating timer or another inventory reader.
            self.heldWindowsDelivery = Task { @MainActor [weak self, weak seat] in
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, let seat, self.heldSeat === seat, self.lease != nil else { return }
                self.heldWindowsDelivery = nil
                self.updateHeldWindows(seat.heldWindowSurfaces, metadata: seat.heldWindowMetadata)
            }
        }
        seat.refreshHeldWindows()
        updateHeldWindows(seat.heldWindowSurfaces, metadata: seat.heldWindowMetadata)
    }

    func updateHeldWindows(_ surfaces: [WindowSurface], metadata: [WindowIdentity: WindowPresentationMetadata]) {
        let windows = surfaces.enumerated().map { order, surface in
            HeldWindow(surface: surface, metadata: surface.reference.identity.flatMap { metadata[$0] }, order: order)
        }
        let main = windows.filter { $0.kind == .main }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            ?? windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        windowPreviews.update(surfaces, mainWindowNumber: main?.windowNumber)
        guard windows != heldWindows else { return }
        heldWindows = windows
        Self.log.info("held windows changed: \(windows.map(\.windowNumber), privacy: .public)")
    }

    /// Creates the preview's temporary control adapter. The caller supplies host suspension and drain.
    public func makeHumanPreviewControl(
        suspend: @escaping @MainActor () throws -> Void,
        waitForAgent: @escaping @MainActor () async throws -> Void,
        endAgent: @escaping @MainActor () -> Void,
        waitForWorker: @escaping @MainActor () async -> Void = {},
        withholding: @escaping @MainActor (String) -> String = { $0 },
        resumeAgent: (@MainActor (String, @escaping @MainActor () async throws -> Void) async throws -> Void)? = nil
    ) -> HumanPreviewControl {
        let control = HumanPreviewControl(session: self, suspend: suspend,
            waitForAgent: waitForAgent, endAgent: endAgent,
            waitForWorker: waitForWorker, withholding: withholding, resumeAgent: resumeAgent)
        previewControl = control
        return control
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

    /// The route this session is when no routing session fronts it (M05).
    public var dispatchRoute: CallRoute.Route? { .desktop }

    /// Checks the grants, waits for a seat, opens the application on it and returns the first
    /// scene, which the Brain observes. A missing grant is asked for through the broker and
    /// refused at once, before the queue. Failures close and return the seat before throwing.
    /// Human takeover during the first scene read preserves the completed adoption and rethrows
    /// CancellationError for the tool to answer with the opened session and no scene.
    public func open(application word: String, window title: String?) async throws -> SceneSnapshot {
        let started = ContinuousClock.now
        Self.log.info("open_session: waiting for prior close")
        defer { Self.log.info("open_session: ended after \(started.duration(to: .now).description, privacy: .public)") }
        // A release between turns may still be finishing; this open comes after it.
        await closing?.value
        Self.log.info("open_session: prior close finished after \(started.duration(to: .now).description, privacy: .public)")
        // A seat that stopped for good ends its session: this open replaces it, as close_session would.
        if case .holding = phase, let target, stoppedForGood(target) { await close() }
        if case .holding = phase, let target, let running = application, let title,
           (running.bundleIdentifier?.caseInsensitiveCompare(word) == .orderedSame
            || running.localizedName?.caseInsensitiveCompare(word) == .orderedSame
            || lastOpened?.name.caseInsensitiveCompare(word) == .orderedSame) {
            try await switching(target, running.processIdentifier, title)
            let scene = try await AutomationCallInterruption.openingScene { try await perceivedScene() }
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
            let queued = ContinuousClock.now
            Self.log.info("open_session: acquiring seat")
            lease = try await broker.queue.acquire(label)
            Self.log.info("open_session: seat acquired in \(queued.duration(to: .now).description, privacy: .public)")
        } catch {
            phase = .idle
            throw error
        }
        self.lease = lease
        phase = .holding(application: nil)
        do {
            // The queue can admit an entry in the same turn its wait was cancelled.
            try Task.checkCancellation()
            // Claimed before anything is launched or adopted: another owner's session, on any route or in another
            // Braus process, holding it refuses this open with nothing sent.
            let bundleID = try await resolving(word)
            switch claims.acquire(bundleID, owner: claimOwner) {
                case .success(let hold): claim = hold
                case .failure(let refusal): throw AutomationFailure(AppClaims.sentence(refusal, name: word))
            }
            // Opened by the bundle ID claimed, never the word again: a resolution that changed meanwhile cannot launch
            // or adopt another application.
            let adopting = ContinuousClock.now
            Self.log.info("open_session: launch/adoption starting")
            let seated = try await seating(lease.session, bundleID, title)
            Self.log.info("open_session: launch/adoption finished in \(adopting.duration(to: .now).description, privacy: .public)")
            guard seated.opened.bundleID == bundleID else {
                throw AutomationFailure("\(seated.opened.name) is not the application claimed for \(word); nothing "
                    + "more was sent to it. Open it again by its bundle ID.")
            }
            target  = seated.target
            runtime = EngineRuntime(knowledgeDirectory: knowledgeDirectory, seat: seated.target)
            guard let pid = seated.opened.pid, let running = runningApplication(pid) else {
                throw AutomationFailure("\(seated.opened.name) opened and then could not be found running.")
            }
            application = running
            phase = .holding(application: seated.opened.name)
            watchHeldWindows()
            id = UUID()
            let reading = ContinuousClock.now
            Self.log.info("open_session: first scene starting, seat consistent")
            defer { Self.log.info("open_session: first scene ended after \(reading.duration(to: .now).description, privacy: .public)") }
            let scene: SceneSnapshot
            do {
                scene = try await AutomationCallInterruption.openingScene { try await perceivedScene() }
            } catch is CancellationError where AutomationCallInterruption.current?.wasInterrupted == true {
                lastOpened = (seated.opened.name, seated.opened.bundleID, title ?? "")
                watchQueue(for: lease)
                throw CancellationError()
            }
            lastOpened = (seated.opened.name, seated.opened.bundleID, scene.windowTitle)
            watchQueue(for: lease)
            return scene
        } catch is CancellationError where AutomationCallInterruption.current?.wasInterrupted == true && id != nil {
            Self.log.info("open_session: first scene interrupted for human control, retaining session")
            throw CancellationError()
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
        Self.candidates(await ApplicationOpening.rankedOffMain(query, in: TargetEnumerator.preparedTargets()))
    }

    /// The bundle ID `open` resolves `application` to, through the same `ApplicationOpening.resolve`, so a name in
    /// the person's language routes as the app's own does. Nil, by design, for a name `open` would refuse: that
    /// open then says why. Needs no seat and no grant.
    public func resolvedBundleID(of application: String) async -> String? {
        try? await ApplicationOpening.resolvedOffMain(application, in: TargetEnumerator.preparedTargets()).bundleID
    }

    /// The windows of `processID`, the seat's already adopted windows included: a held floating window keeps its
    /// row with its current identity even when the system's list no longer shows it.
    public func windowCandidates(ownedBy processID: pid_t) async throws -> [WindowRow] {
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
        // The engine's act through a menu item records no rung in this slice: its command gets no recorder (M05, open).
        let menus       = MenuItemCommands(
            menuCommand(application, runtime, try seat.agentSeat(), inFront: inFront, recorder: nil),
            inFront: inFront ? application.localizedName ?? "The application" : nil
        )
        let recorder = Self.recorder(runtime, sessionID: id)
        let outcome  = await runtime.engine(
            recorder                    : recorder,
            allowsDestructive           : allowsDestructive,
            contextMenusOnTextFieldsOnly: Self.drawsMenusUnderThePointer(application),
            selectsFieldsByTripleClick  : remotePanel,
            refusesMenuOpeningClicks    : remotePanel,
            windowClosure               : windowClosure(of: seat),
            menus                       : menus
        ).act(request)
        await Self.handRung(of: runtime, to: recorder)
        return await enriched(outcome, by: runtime)
    }

    /// The Seat's last send of this call, as its receipt says, handed once to the recorder the engine was given (M05):
    /// taken right after the engine, on every outcome, before the scene is enriched, so no later call reads it. The
    /// foreground's HID events carry no receipt and the web posts none: those actuators leave nothing to take, and
    /// nothing is inferred for them.
    static func handRung(of runtime: EngineRuntime, to recorder: CallRecorder) async {
        guard let seat = runtime.actuator as? SeatActuator, let send = await seat.takeLastSend() else { return }
        await recorder.dispatched(rung: CallRung(send))
    }

    public func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        try await deliver(input, section: section, withholdsText: false)
    }

    /// The Seat attests no field (W1): it classifies nothing, so a bound text is refused with nothing typed, and a
    /// withheld one is delivered with the engine told, so its answer quotes no value of the field and its check keeps
    /// none of the texts.
    public func deliver(_ input: InputRequest.Input, section: String?, dispatch: TextDispatch) async throws -> ActOutcome {
        guard dispatch == .withheld else {
            throw AutomationFailure("This session cannot type only into the field the call recorded, so nothing was typed.")
        }
        return try await deliver(input, section: section, withholdsText: true)
    }

    /// The engine's request for an input to `application`, telling it whether the call withholds the input's text.
    static func request(
        _ input      : InputRequest.Input,
        section      : String?,
        application  : NSRunningApplication,
        withholdsText: Bool
    ) -> InputRequest {
        InputRequest(
            processID    : application.processIdentifier,
            bundleID     : application.bundleIdentifier ?? "pid.\(application.processIdentifier)",
            appName      : application.localizedName ?? "application",
            input        : input,
            section      : section,
            withholdsText: withholdsText
        )
    }

    private func deliver(_ input: InputRequest.Input, section: String?, withholdsText: Bool) async throws -> ActOutcome {
        let (application, runtime, seat) = try current()
        if case .refuse(let sentence) = try await SeatAdmission.awaited(
            seat.agentSeat(),
            application: application.localizedName ?? "the application"
        ) {
            throw AutomationFailure(sentence)
        }
        if case .contextMenu(let control, let item) = input {
            // The call's recorder, bound once before the selector runs: it takes the selector's perceptions, and the
            // Seat's receipt the selector returns is handed to it before the scene is enriched (M05).
            let recorder = Self.recorder(runtime, sessionID: id)
            let selector = SeatContextMenuSelector(target: seat, pipeline: ProductionPerception.pipeline())
            let chosen = try await selector.selectWithReceipt(
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
                    to: recorder,
                    bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
                )
            )
            await Self.handContextMenuRung(of: chosen.receipt, to: recorder)
            return await enriched(chosen.outcome, by: runtime)
        }
        let request = Self.request(input, section: section, application: application, withholdsText: withholdsText)
        // Of these inputs only Escape closes a window: the engine refuses text that carries one.
        var closesTheWindow = false
        if case .pressKey(let chord, _) = input { closesTheWindow = chord.key == .escape }
        let recorder = Self.recorder(runtime, sessionID: id)
        let outcome  = await runtime.engine(
            recorder                    : recorder,
            allowsDestructive           : allowsDestructive,
            contextMenusOnTextFieldsOnly: Self.drawsMenusUnderThePointer(application),
            selectsFieldsByTripleClick  : try seat.agentSeat().holdsRemoteFilePanel,
            windowClosure               : closesTheWindow ? windowClosure(of: seat) : WindowClosureGuard()
        ).deliver(request)
        await Self.handRung(of: runtime, to: recorder)
        return await enriched(outcome, by: runtime)
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
        // The call's recorder, bound once before anything is awaited: the perceptions and the press's rung go to it (M05).
        let recorder = Self.recorder(runtime, sessionID: id)
        let command = menuCommand(application, runtime, agentSeat, inFront: inFront, recorder: recorder)
        return try await PerceivedCommand.perform(
            bundleID: application.bundleIdentifier ?? "pid.\(processID)",
            recorder: recorder,
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
        inFront      : Bool,
        recorder     : CallRecorder?
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
                    recorder: recorder,
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
                recorder         : recorder,
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
        // The call's recorder, bound once before the selector runs: the selector reports its perceptions to it, and
        // the receipt it returns is handed to it before the scene is enriched (M05).
        let recorder = Self.recorder(runtime, sessionID: id)
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
                to: recorder,
                bundleID: application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
            )
        )
        await Self.handSelectRung(of: result.receipt, to: recorder)
        return (await enriched(result.outcome, by: runtime), result.receipt)
    }

    /// The last receipt the Seat's dropdown returned for this call, the last key's or, when no key went out, the
    /// opener's click, handed once to the recorder the selector reported to (M05): the receipt the selector returned,
    /// not the last gesture of the whole call nor the menu's cleanup. A native popup (accessibility actions, which
    /// carry no receipt), a refusal or a dry run before any gesture (no receipt) and a selector that threw (the
    /// receipts of what went out are not returned) hand nothing, erase nothing the recorder holds, and nothing is
    /// inferred for them.
    package static func handSelectRung(of receipt: PopupMenuReceipt?, to recorder: CallRecorder) async {
        guard let last = receipt?.choosing.last ?? receipt?.opening else { return }
        await recorder.dispatched(rung: CallRung(SeatSend(last)))
    }

    /// The last receipt the Seat returned for this call's contextual menu, the row's click when one went out or the
    /// opener's right click, handed once to the recorder the selector reported to (M05): the receipt returned, not the
    /// menu's cleanup (its Escape is posted outside the receipts) nor the whole call. A choice refused before the Seat
    /// was asked (no receipt) and a Seat that threw (no outcome returned) hand nothing, erase nothing the recorder
    /// holds, and nothing is inferred for them.
    package static func handContextMenuRung(of receipt: SeatMenuOutcome?, to recorder: CallRecorder) async {
        guard let last = receipt?.insideMenu.last ?? receipt?.opening else { return }
        await recorder.dispatched(rung: CallRung(SeatSend(last)))
    }

    /// Flushes the Brain, ends the borrow, finishes with the application and gives the seat back.
    ///
    /// The cleanup runs in a task of its own, so a cancelled caller still gives the seat back and a
    /// second call waits for the first. What finishing leaves the person to do (an application the
    /// seat could not confirm home, so left running) has no channel in this role, so it is logged.
    public func close() async {
        let details = humanDetails
        humanDetails = nil
        lendingWatch?.cancel()
        lendingWatch = nil
        humanIntervention = nil
        idleRelease?.cancel()
        idleRelease = nil
        if let closing { await closing.value; return }
        guard phase != .idle else { await details?.finish(); return }
        closeWarning = nil
        let previewControl = self.previewControl
        previewControl?.sessionWillClose()
        heldSeat?.heldWindowsChanged = nil
        heldWindowsDelivery?.cancel()
        heldWindowsDelivery = nil
        if !heldWindows.isEmpty { heldWindows = [] }
        let windowPreviews = self.windowPreviews
        let runtime = self.runtime
        let target  = self.target
        let lease   = self.lease
        self.runtime = nil
        self.target  = nil
        self.lease   = nil
        application  = nil
        id           = nil
        let cleanup = Task {
            await windowPreviews.stop()
            await details?.finish()
            await previewControl?.drainForSessionClose()
            await runtime?.finish()
            await target?.stop()
            if let lease {
                closeWarning = await lease.session.finishUsingApp()
                if let left = closeWarning {
                    Self.log.error("A worker's session closed with this left to do: \(left, privacy: .public)")
                }
                lease.giveBack()
            }
            previewControl?.sessionDidClose()
            // Given back once the application is finished with: only this session's hold.
            claim = nil
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

    /// Retains the existing session for one human episode, without granting input authority. The
    /// composer calls this before suspending the agent, on MainActor without an intervening await.
    /// Repeated calls return the same token. Explicit close always overrides this retention.
    public func retainForHumanIntervention() throws -> UUID {
        guard lease != nil, id != nil, closing == nil else {
            throw AutomationFailure("Human control requires an open application session.")
        }
        if let humanIntervention { return humanIntervention }
        let details = humanDetails
        humanDetails = nil
        if let details { Task { await details.finish() } }
        let token = UUID()
        humanIntervention = token
        idleRelease?.cancel()
        idleRelease = nil
        return token
    }

    /// Lends after the caller has suspended and drained its worker. The episode retains the lease.
    @discardableResult
    public func lendApplication(
        on screen: NSScreen,
        around anchor: CGRect? = nil,
        willMove: ((WindowReference, CGRect) async -> Void)? = nil
    ) async throws -> ApplicationLendingReport {
        try await lendApplication(on: screen, around: anchor, willMove: willMove, willMoveAll: nil)
    }

    /// Forwards the whole application layout to the human presentation adapter.
    func lendApplication(
        on screen: NSScreen,
        around anchor: CGRect? = nil,
        lendingFrames: [Int: CGRect] = [:],
        willMove: ((WindowReference, CGRect) async -> Void)? = nil,
        willMoveAll: (([WindowReference]) async -> Void)?
    ) async throws -> ApplicationLendingReport {
        guard humanIntervention != nil, let lease, closing == nil else {
            throw AutomationFailure("Human control no longer owns this application session.")
        }
        let episode = humanIntervention
        let heldID = id
        let report = try await lease.session.lendApplication(
            on: screen,
            around: anchor,
            lendingFrames: lendingFrames,
            willMove: willMove,
            willMoveAll: willMoveAll
        )
        guard id == heldID, humanIntervention == episode, closing == nil else { throw CancellationError() }
        watchLentApplication(heldID: heldID)
        return report
    }

    /// A person can quit while suspended. A preview retains its decision; otherwise close the lease.
    private func watchLentApplication(heldID: UUID?) {
        guard lendingWatch == nil else { return }
        lendingWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.id == heldID, closing == nil, heldSeat?.isApplicationLent == true else { return }
                if heldSeat?.lentApplicationHasExited == true {
                    // Keep the episode available for Yes to report the vanished app and resume its worker.
                    if previewControl?.hasStarted == true, previewControl?.isFinished == false { return }
                    await close()
                    return
                }
            }
        }
    }

    /// Takes back before resume. End Control, explicit Stop and close instead abandon lending.
    @discardableResult
    public func takeBackApplication() async throws -> ApplicationLendingReport {
        guard let lease, closing == nil else { throw AutomationFailure("The application session has ended.") }
        lendingWatch?.cancel()
        lendingWatch = nil
        let heldID = id
        let report = try await lease.session.takeBackApplication(willMoveAll: { [weak self] windows in
            await self?.previewControl?.prepareTakeBack(windows)
        })
        guard id == heldID, closing == nil else { throw CancellationError() }
        try Self.requireCompleteLending(report)
        if report.applicationVanished, previewControl?.isFinishing != true { await close() }
        return report
    }

    private static func requireCompleteLending(_ report: ApplicationLendingReport) throws {
        guard report.failures.isEmpty else {
            throw AutomationFailure(report.failures.map { "Window \($0.windowNumber): \($0.reason)" }.joined(separator: " "))
        }
    }

    /// Ends only the matching episode and restores normal idle/queue release. To keep the lease
    /// for a reviewed continuation, call inside its new turn. Ending alone never starts an agent.
    public func endHumanIntervention(_ token: UUID) async throws {
        guard humanIntervention == token else {
            throw AutomationFailure("This human intervention no longer owns the session.")
        }
        _ = try await takeBackApplication()
        try await completeHumanIntervention(token)
    }

    /// Completes the matching, already returned episode inside its new turn, without moving twice.
    func completeHumanIntervention(_ token: UUID, details: HumanInterventionDetails? = nil) async throws {
        guard humanIntervention == token, heldSeat?.isApplicationLent != true else {
            await details?.finish()
            throw AutomationFailure("This human intervention is stale or its application is still lent.")
        }
        humanIntervention = nil
        if let details { await retainHumanDetails(details) }
        await releaseIfSomeoneWaits()
        releaseWhenIdle()
    }

    private func endTurn() async {
        isInTurn = false
        let details = humanDetails
        humanDetails = nil
        await details?.finish()
        await releaseIfSomeoneWaits()
        releaseWhenIdle()
    }

    /// Installs lazy history inside the resumed worker turn, after the human lease has returned.
    func retainHumanDetails(_ details: HumanInterventionDetails) async {
        guard isInTurn, humanIntervention == nil, closing == nil else {
            await details.finish()
            return
        }
        let previous = humanDetails
        humanDetails = details
        await previous?.finish()
    }

    public func humanStep(_ request: HumanStepRequest) async -> HumanStepResult {
        guard isInTurn, humanIntervention == nil, closing == nil, let humanDetails else { return .unavailable }
        return humanDetails.result(request)
    }

    /// Closes once an open session has gone `idleWindow` without a turn. The wait is tied to the
    /// lease held now, so one that outlives a close, or returns under a later lease, closes nothing.
    private func releaseWhenIdle() {
        guard let lease, id != nil, closing == nil, !isInTurn, humanIntervention == nil else { return }
        idleRelease?.cancel()
        idleRelease = Task { [weak self, waitIdle, idleWindow] in
            do {
                try await waitIdle(idleWindow)
            } catch {
                // The wait ends early only when cancelled: a turn started or the session closed.
                return
            }
            guard let self, !Task.isCancelled, self.lease === lease,
                  !isInTurn, humanIntervention == nil, closing == nil else { return }
            await close()
        }
    }

    /// Closes when an open session is idle between turns and an entry is waiting for the seat.
    private func releaseIfSomeoneWaits() async {
        guard !isInTurn, humanIntervention == nil, id != nil, closing == nil,
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

extension CallRung {
    /// The Seat's send as the record keeps it: the receipt's posting call, the counts as `how`, nothing skipped.
    init(_ send: SeatSend) {
        let rung: Rung = switch send.poster {
            case .publicProcess      : .seatPublicProcess
            case .skyLightProcess    : .seatSkyLightProcess
            case .accessibilityAction: .seatAccessibilityAction
        }
        self.init(rung: rung, how: "\(send.eventCount) events, \(send.routedEventCount) routed to window \(send.windowNumber)")
    }
}
