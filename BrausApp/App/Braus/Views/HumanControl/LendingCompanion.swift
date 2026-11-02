//
//  LendingCompanion.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit
import ApplicationServices
import os
import SeatBroker

/// LendingCompanion is what the person sees while an app is lent to them: the border around its main
/// window (`ControlWindowBorder`) and the worker in the corner (`HumanControlOverlay`). It follows one
/// human control's `lentWindow`: both come once lending succeeded and go when it ends. Control taken
/// from the screen window, which is the app's window at its real size, lands the app exactly where
/// that window is: on the swap's beat (`TakeControlBeats`, which `HumanPreviewControl.willLend` holds
/// the move until) a still of the screen covers the window, which steps aside (`LendStill`); the
/// windows move under the still, and it fades into them once they stand still. Nothing stands
/// behind the app: a backdrop of Braus's own took Stage Manager's centre and left the app in the strip,
/// and a black screen read as strange. Yes returns the application and resumes the worker with a reviewed handoff.
///
/// The border fades as the worker's exit begins, and both go as soon as control finishes, is blocked or
/// loses its window: the lent window itself is cleared only after the take-back and the resume, seconds
/// later. With Stage Manager on, the border goes while the lent window is in the strip (`StageWatch`).
///
/// The border follows the window through the app's own accessibility notifications, with no polling at rest.
/// They are registered on the application, since reaching the window's own element needs a private
/// call; each one reads the tracked window's frame from the window server, so other windows' moves
/// change nothing. The border goes while that window is off screen, minimised, its app hidden or the
/// window closed, and comes back around it, or the app's largest window, once one is on the person's
/// screen again; the worker in the corner stays. A window left on the Seat's display, one whose move
/// failed, is never marked: the person cannot see it. While the person holds the left button on it, the border follows every
/// display frame: Qt apps such as Pro Tools send their notices in bursts or only once the drag ends. Each read waits
/// for the window server's next turn, so a press's reads run on a thread of their own and each display
/// frame takes the latest; once a read shows the window carried by the pointer, the pointer alone
/// places the border until the button comes up.
///
/// What the person does with the lent app decides when the worker asks whether they are done, or takes it
/// back by itself (`LendActivityWatch`): the watch runs from the lend until a hand-back is asked, asks
/// through the worker's bubble, and takes back on Yes or the countdown's end exactly as Yes does.
@MainActor
final class LendingCompanion: NSObject {

    /// Lifecycle orders what the companion does: shown once on lend, the border leaving as the worker's
    /// exit begins, finish asked once on Yes, gone when the episode or its lending ends.
    struct Lifecycle {
        enum Phase: Equatable { case waiting, shown, leaving, finishing, ended }

        /// What a change of the control asks: the companion comes on screen, or what is on it goes.
        enum Step: Equatable { case present, dismiss }

        private(set) var phase = Phase.waiting

        /// Lending succeeded: true when the companion comes on screen.
        mutating func lent() -> Bool {
            guard phase == .waiting else { return false }
            phase = .shown
            return true
        }

        /// The worker's exit began: true once, when the border starts to fade with it.
        mutating func exitStarted() -> Bool {
            guard phase == .shown else { return false }
            phase = .leaving
            return true
        }

        /// The person answered Yes: true once, when control should finish.
        mutating func finishRequested() -> Bool {
            guard phase == .shown || phase == .leaving else { return false }
            phase = .finishing
            return true
        }

        /// Lending or the episode ended: true when what is on screen goes.
        mutating func ended() -> Bool {
            defer { phase = .ended }
            return phase != .waiting && phase != .ended
        }

        /// The control changed: `lent` while it has a lent window, `ending` once it is finishing, finished
        /// or blocked. Any of those ends the companion at once, before the take-back or the close runs,
        /// and so does the lent window going.
        mutating func control(
            lent  : Bool,
            ending: Bool
        ) -> Step? {
            if lent, !ending, self.lent() { return .present }
            guard ending || !lent && phase != .waiting else { return nil }
            return ended() ? .dismiss : nil
        }
    }

    /// StageWatch follows the tracked window for a moment after an app came to the front with Stage
    /// Manager on. A window leaving for the strip is drawn smaller and in perspective, and the window
    /// server reports that drawing: its frame shrinks for 0.7 s, with no accessibility notice, and grows
    /// back the same way (TextEdit). The shrink began 0.1 s after the activation, or 0.45 s
    /// after an app that had just launched. Shrinking from the size the border marks with another app in
    /// front, it left the stage; moved from where the watch found it and nearly still again, it is on
    /// the stage, back from the strip or moved within it.
    struct StageWatch {
        enum Verdict: Equatable { case left, back(CGRect) }

        /// How long the watch lasts at most, how long a window that never moved is watched, how long a
        /// moved one must hold still, and the step that counts as nearly still.
        private static let longest    : Double  = 2
        private static let quiet      : Double  = 1
        private static let settle     : Double  = 0.15
        private static let nearlyStill: CGFloat = 2

        private let marked : CGSize?
        private let inFront: Bool
        private let begun  : Double
        private var first  : CGRect?
        private var last   : CGRect?
        private var changed: Double
        private var moved  = false
        private(set) var isOver = false

        /// `marked` is the size the border marks, nil while it is hidden; `inFront` whether the lent app
        /// came to the front.
        init(
            marked : CGSize?,
            inFront: Bool,
            at time: Double
        ) {
            self.marked  = marked
            self.inFront = inFront
            begun        = time
            changed      = time
        }

        /// Takes the window's frame read at `time`, nil while it is off screen.
        mutating func read(
            _ frame: CGRect?,
            at time: Double
        ) -> Verdict? {
            guard !isOver else { return nil }
            guard let frame, inFront || marked != nil else {
                isOver = true
                return nil
            }
            if !inFront, let marked, max(
                abs(frame.width - marked.width),
                abs(frame.height - marked.height)
            ) > Self.nearlyStill {
                isOver = true
                return .left
            }
            let step = last.map { Self.distance($0, frame) } ?? 0
            if frame != last {
                changed = time
                last    = frame
            }
            // A strip thumbnail twitches by a point before it grows: only a real move counts.
            let first  = self.first ?? frame
            self.first = first
            moved      = moved || Self.distance(first, frame) > Self.nearlyStill
            if time - changed >= (moved ? Self.settle : Self.quiet) || time - begun >= Self.longest {
                isOver = true
                // Never moved, it is on the stage only if it was all along: a thumbnail gets no border.
                return moved || marked != nil ? .back(frame) : nil
            }
            return moved && step <= Self.nearlyStill ? .back(frame) : nil
        }

        private static func distance(
            _ a: CGRect,
            _ b: CGRect
        ) -> CGFloat {
            max(
                abs(a.minX - b.minX),
                abs(a.minY - b.minY),
                abs(a.width - b.width),
                abs(a.height - b.height)
            )
        }
    }

    /// `frame` in window-server space (y down from the top of the menu-bar screen) in AppKit's screen
    /// space (y up from its bottom), given the menu-bar screen's frame.
    static func appKitFrame(
        _ frame      : CGRect,
        menuBarScreen: CGRect
    ) -> CGRect {
        CGRect(
            x     : frame.minX,
            y     : menuBarScreen.maxY - frame.maxY,
            width : frame.width,
            height: frame.height
        )
    }

    private let control: HumanPreviewControl
    private let worker : () -> HouseWorker?
    private(set) var lifecycle = Lifecycle()

    /// True once the lent application stands on the person's screen with the still faded into it,
    /// the end of the lend's animation.
    private(set) var hasLanded = false

    /// True while Yes can still be answered: the hand-back was not asked yet.
    var asksHandBack: Bool { lifecycle.phase == .shown || lifecycle.phase == .leaving }

    private let border = ControlWindowBorder()
    private var overlay: HumanControlOverlay?

    /// What the person does with the lent app decides when the worker asks whether they are done, or takes
    /// it back by itself (`LendActivity`): from the lend until a hand-back is asked or the episode ends.
    private var activity: LendActivityWatch?

    /// The live view of the worker's screen, nil while there is none, and the still of it that covers
    /// the screen window's place while the windows move.
    private let picture: () -> NSView?
    private var still  : LendStill?

    /// When control was taken from the screen window, which the swap is timed from.
    private var takenAt: ContinuousClock.Instant?

    /// Takes the screen window off the screen as the still covers it, brings it back for the
    /// hand-back, moves it over the lent window's frame as the window leaves, and tells it the lent
    /// window has left.
    private let stepAside : () -> Void
    private let handBack  : (CGRect?) -> Void
    private let leavesFrom: (CGRect) -> Void
    private let handedBack: () -> Void
    private let lendBegins: () -> Void
    private let twins     : () -> WindowTwins?

    /// When the windows move, the main one and the others on the same beat, once the lend began; and
    /// the stills on the twins of the application's other windows, until those windows stand still.
    private var swapAt    : ContinuousClock.Instant?
    private var twinStills: [Int: LendStill] = [:]

    /// The lent app, the window the border marks, and that window's frame as the border last drew it,
    /// in AppKit's screen space, nil while the border is hidden.
    private var processID: pid_t = 0
    private var tracked  : Int?
    private var shown    : CGRect?
    /// The largest window actually lent, which the border falls back to while the person's focus is
    /// on none of the lent windows, and which the hand-back follows: a resize that makes another
    /// window larger does not take the hand-back away from it.
    private var anchor   : Int?
    /// The windows actually lent, among which the border follows the one the person focused.
    private var lent     : Set<Int> = []
    /// Whether Stage Manager keeps the tracked window in its strip, where no notice brings the border
    /// back, and the watch that decides it after an activation.
    private var offStage = false
    private var stage    : Task<Void, Never>?

    private var observer   : AXObserver?
    private var application: AXUIElement?
    /// The observer's context holds the companion until `unwatch`, so no notice reaches a freed one.
    private var context    : Unmanaged<LendingCompanion>?
    private var workspace  : [NSObjectProtocol] = []
    private var settle     : Task<Void, Never>?
    private var glance     : Task<Void, Never>?
    private var presses    : Any?

    /// The display link that follows a press, the frame the border had when the press began, and
    /// where the button went down when the press was caught as it began.
    private var link     : CADisplayLink?
    private var pressedAt: CGRect?
    private var grab     : CGPoint?
    /// The press's reads, the number of the reading the border last took, and whether a reading
    /// showed the window carried by the pointer.
    private var reader   : FrameReader?
    private var taken    = 0
    private var dragged  = false
    private var trace    : PressTrace?

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "HumanControl"
    )

    private static let notifications = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMenuOpenedNotification,
        kAXMenuClosedNotification,
    ] + windowsNotifications

    /// Notices that a window left the screen or came back, after which the border may go or return.
    private static let windowsNotifications = [
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
    ]

    /// Follows `control`; `worker` gives the worker the corner shows, nil for none. `picture` is the
    /// screen window's live view, `stepAside` takes that window off the screen as the still covers it,
    /// `handBack` brings it back over the lent window's last frame as the person answers Yes, and
    /// `leavesFrom` moves it over that window's frame as read when the window leaves the person's
    /// screen, `handedBack` tells it the window has left, and `lendBegins` that the application has
    /// started on its way to the person, the worker's step done.
    init(
        control   : HumanPreviewControl,
        picture   : @escaping () -> NSView? = { nil },
        stepAside : @escaping () -> Void = {},
        handBack  : @escaping (CGRect?) -> Void = { _ in },
        leavesFrom: @escaping (CGRect) -> Void = { _ in },
        handedBack: @escaping () -> Void = {},
        twins     : @escaping () -> WindowTwins? = { nil },
        lendBegins: @escaping () -> Void = {},
        worker    : @escaping () -> HouseWorker?
    ) {
        self.control    = control
        self.picture    = picture
        self.stepAside  = stepAside
        self.handBack   = handBack
        self.leavesFrom = leavesFrom
        self.handedBack = handedBack
        self.lendBegins = lendBegins
        self.twins      = twins
        self.worker     = worker
        super.init()
        control.willLend     = { [weak self] planned in await self?.lendWillMove(planned) }
        control.willLendAll  = { [weak self] planned in await self?.lendWillMoveAll(planned) }
        control.willTakeBack = { [weak self] current in self?.takeBackWillMove(current) }
        follow()
    }

    private func follow() {
        withObservationTracking {
            _ = control.lentWindow
            _ = control.isFinishing
            _ = control.isFinished
            _ = control.isBlocked
            _ = control.lendingRefused
        } onChange: { [weak self] in
            Task { @MainActor in self?.controlChanged() }
        }
    }

    /// The lent window goes only once the take-back and the worker's resume are done, seconds after
    /// Yes: control finishing already ends the companion.
    private func controlChanged() {
        let wasWaiting = lifecycle.phase == .waiting
        switch lifecycle.control(
            lent  : control.lentWindow != nil,
            ending: control.isFinishing || control.isFinished || control.isBlocked
        ) {
        case .present: if let lent = control.lentWindow { present(lent) }
        case .dismiss: dismiss()
        case nil     : break
        }
        // A lend that will not happen takes the still and its border away.
        if control.lendingRefused || control.isFinishing || control.isFinished || control.isBlocked {
            if wasWaiting { border.hide(fade: ControlWindowBorder.quick) }
            still?.land()
            landTwinStills()
        }
        if lifecycle.phase != .ended { follow() }
    }

    private func present(_ lent: LentWindow) {
        processID = lent.processID
        tracked   = lent.windowNumber
        anchor    = control.lentWindows
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?
            .windowNumber ?? lent.windowNumber
        self.lent = Set(control.lentWindows.map(\.windowNumber) + [lent.windowNumber])
        let frame  = Self.appKitFrame(
            lent.frame,
            menuBarScreen: NSScreen.screens.first?.frame ?? .zero
        )
        let centre = CGPoint(
            x: frame.midX,
            y: frame.midY
        )
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) }) ?? PersonScreen.current()
        else { return }
        // The lent application comes to the front: the border floats again, wherever the last lend left it.
        border.stack(above: nil)
        border.show(frame: frame)
        shown = frame
        startActivity()
        Self.log.notice("take control: lent; \(Self.stacking, privacy: .public)")
        Self.log.notice("take control: while lent, Braus's windows that take the mouse: \(Self.mouseCatchers, privacy: .public)")
        reveal(lent)
        showOverlay(on: screen)
        watch()
        // After the worker's entrance, it checks on the work it just handed over.
        glanceSoon(after: .seconds(3))
    }

    /// The worker on the screen's corner, popping up out of its hole; nothing when it is already there.
    private func showOverlay(on screen: NSScreen) {
        guard overlay == nil, let worker = worker() else { return }
        let overlay = HumanControlOverlay(worker: worker)
        overlay.onLeaving         = { [weak self] in self?.exitStarted() }
        overlay.onFinishRequested = { [weak self] in self?.finishRequested() }
        overlay.show(on: screen)
        self.overlay = overlay
    }

    /// Control was taken from the screen window: the swap is timed from now.
    func controlTaken() {
        let takenAt = ContinuousClock.now
        self.takenAt = takenAt
        swapAt       = nil
        Self.log.notice("take control: clicked; \(Self.stacking, privacy: .public)")
        // The still is copied ahead, off the main thread, while the curtain fades off the picture.
        Task { [weak self] in
            try? await Task.sleep(until: takenAt + .seconds(TakeControlBeats.revealStart))
            guard let self, lifecycle.phase == .waiting, still == nil,
                  let still = picture().flatMap(LendStill.init(picture:)) else { return }
            self.still = still
            await still.prepare()
        }
    }

    /// Just before the windows move: holds the move until the swap's beat, when the still covers the
    /// screen window and the window steps aside. At once when control was not taken from the screen
    /// window. A lend that begins once the curtain already says the worker is finishing its step, as
    /// it does while that step drains, waits for the curtain to say the person is in control and lift,
    /// and takes a still of the picture as it is now.
    private func lendWillMove(_ planned: LentWindow) async {
        guard let swapAt = swapBeat() else { return }
        try? await Task.sleep(until: swapAt)
        guard lifecycle.phase == .waiting, !control.isFinishing, !control.isFinished else { return }

        Self.log.notice("take control: the windows move to \(String(describing: planned.frame), privacy: .public) in window-server space; \(Self.stacking, privacy: .public)")
        if still == nil { still = picture().flatMap(LendStill.init(picture:)) }
        await still?.prepare()
        still?.show()
        // The person's blue, which the screen window's neon turned to, goes on around the still.
        if let still { border.show(frame: still.frame) }
        // The still is on screen before the window leaves.
        try? await Task.sleep(for: .milliseconds(30))
        stepAside()
    }

    /// The swap's beat, set by the first of the lend's hooks to ask: on the curtain's beat after the
    /// click, or past the curtain's change of words for a lend that begins late. Nil when control was
    /// not taken from the screen window.
    private func swapBeat() -> ContinuousClock.Instant? {
        if let swapAt { return swapAt }
        guard let takenAt else { return nil }
        let begun = ContinuousClock.now
        lendBegins()
        let beat: ContinuousClock.Instant
        if begun > takenAt + .seconds(TakeControlCurtain.timing.words) {
            Self.log.notice("take control: the lend began \(begun - takenAt, privacy: .public) after the click; the curtain says so and lifts first")
            if begun > takenAt + .seconds(TakeControlBeats.revealStart) { still = nil }
            beat = max(
                takenAt + .seconds(TakeControlBeats.swap),
                begun + .seconds(TakeControlCurtain.lateReveal)
            )
        } else {
            beat = takenAt + .seconds(TakeControlBeats.swap)
        }
        swapAt = beat
        return beat
    }

    /// Just before all the windows move, each to its planned frame: on the swap's beat, as the main
    /// window's still covers it, the twins of the other windows step aside under stills of their own,
    /// which fade once the lent windows stand still.
    private func lendWillMoveAll(_ planned: [LentWindow]) async {
        Self.log.notice("take control: the windows will land at \(planned.map { "\($0.windowNumber) \($0.frame)" }, privacy: .public)")
        if let swapAt = swapBeat() {
            try? await Task.sleep(until: swapAt)
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard lifecycle.phase == .waiting, !control.isFinishing, !control.isFinished else { return }
        twinStills = twins()?.stepAside(because: "the windows come to the person") ?? [:]
    }

    /// Just before the lent windows go back to the seat, each at the frame the person left it at:
    /// the screen window, back over the tracked one since Yes, moves to that window's frame as read
    /// now, and the twins of the application's other windows come back at theirs.
    private func takeBackWillMove(_ current: [LentWindow]) {
        Self.log.notice("hand back: the windows leave from \(current.map { "\($0.windowNumber) \($0.frame)" }, privacy: .public)")
        if let main = current.first(where: { $0.windowNumber == (anchor ?? tracked) }) {
            leavesFrom(Self.appKitFrame(
                main.frame,
                menuBarScreen: NSScreen.screens.first?.frame ?? .zero
            ))
        }
        guard let twins = twins() else { return }
        twins.comeBack(at: Dictionary(
            current.map { ($0.windowNumber, $0.frame) },
            uniquingKeysWith: { first, _ in first }
        ))
        twins.show(because: "the application is handed back")
    }

    /// Fades the stills on the twins into the lent windows.
    private func landTwinStills() {
        twinStills.values.forEach { $0.land() }
        twinStills = [:]
    }

    /// Fades the still into the lent window once that window stands still on screen: under Stage
    /// Manager it may arrive from the strip with the stage's own animation, which the window server's
    /// frame follows. Gives up waiting after `settleLimit`.
    private func reveal(_ lent: LentWindow) {
        guard let still else {
            landed()
            return
        }
        let started = ContinuousClock.now
        Self.log.notice("take control: waiting for the lent window to stand still")
        Task {
            var last  : CGRect?
            var steady = 0
            var reads  = 0
            while steady < Self.settleReads, ContinuousClock.now - started < Self.settleLimit {
                let frame = await Self.readFrame(of: lent.windowNumber)
                steady = frame != nil && frame == last ? steady + 1 : 0
                last   = frame
                reads += 1
                try? await Task.sleep(for: Self.settleStep)
            }
            let waited = ContinuousClock.now - started
            Self.log.notice("take control: the lent window stood still after \(waited, privacy: .public), \(reads, privacy: .public) reads, at \(String(describing: last), privacy: .public), planned \(String(describing: lent.frame), privacy: .public); \(Self.stacking, privacy: .public)")
            still.land()
            self.landTwinStills()
            self.landed()
            Self.log.notice("take control: once the still landed, Braus's windows that take the mouse: \(Self.mouseCatchers, privacy: .public)")
        }
    }

    /// How the lent window is watched until it stands still: the reads that must agree, their pace,
    /// and the longest wait.
    static let settleReads           = 2
    static let settleStep : Duration = .milliseconds(40)
    static let settleLimit: Duration = .milliseconds(1500)

    /// The longest the hand-back waits for the lent window to leave the person's screen.
    static let handBackLimit: Duration = .seconds(5)

    /// The lent application stands on the person's screen: from now on the worker may ask.
    private func landed() {
        hasLanded = true
        activity?.landed()
    }

    // MARK: Activity

    /// Starts reading what the person does with the lent application, held until it lands.
    private func startActivity() {
        activity?.stop()
        let activity = LendActivityWatch(processID: processID) { [weak self] decision, reason in
            self?.activityDecided(
                decision,
                because: reason
            )
        }
        self.activity = activity
        control.onActivity = { [weak activity] evidence, age in
            activity?.receive(
                evidence,
                age: age
            )
        }
        if hasLanded { activity.landed() }
    }

    private func stopActivity() {
        activity?.stop()
        activity           = nil
        control.onActivity = nil
    }

    /// The activity policy asks through the worker's bubble, withdraws the question when the person went
    /// back to the application, or takes it back as Yes does. A question it cannot show ends as No.
    private func activityDecided(
        _ decision: LendActivity.Decision,
        because reason: String
    ) {
        switch decision {
        case .ask:
            Task { [weak self] in
                guard let self else { return }
                guard let overlay, lifecycle.phase == .shown else {
                    activity?.answered(.no)
                    return
                }
                let answer = await overlay.askBeforeTakingBack(seconds: LendActivity.countdown)
                activity?.answered(answer)
            }
        case .withdraw:
            overlay?.withdrawQuestion()
        case .takeBack:
            finishRequested(automatically: reason)
        }
    }

    private func exitStarted() {
        guard lifecycle.exitStarted() else { return }
        leave()
    }

    /// Yes, from the worker in the corner or from ⌃⌥Tab (`ControlShortcut`), or the activity policy taking the
    /// application back by itself, `automatically` saying why.
    func finishRequested(automatically reason: String? = nil) {
        guard lifecycle.finishRequested() else { return }
        stopActivity()
        // The screen window comes back over the lent window where the person left it, and lets go of
        // its curtain once the window has left their screen.
        let lent  = anchor ?? tracked
        let frame = lent.flatMap(Self.windowServerFrame(of:)).map {
            Self.appKitFrame(
                $0,
                menuBarScreen: NSScreen.screens.first?.frame ?? .zero
            )
        } ?? shown
        Self.log.notice("hand back: Yes, the screen window comes back at \(String(describing: frame), privacy: .public); \(Self.stacking, privacy: .public)")
        handBack(frame)
        // The screen window's own neon is around the same frame now: the blue one goes at once.
        border.hide()
        shown = nil
        // The overlay never activates Braus, so the lent application stays frontmost and the take-back waits for
        // the person to click elsewhere; only this click may move focus away from it. The screen window, key
        // and in front by now, is the one the activation raises.
        NSApp.activate()
        Self.log.notice("hand back: Braus activated; \(Self.stacking, privacy: .public)")
        Task { await control.finish(
            .resumingWorker,
            automatically: reason
        ) }
        Task { [weak self] in
            let started = ContinuousClock.now
            // The flip between the two spaces is its own inverse.
            let person  = frame.map {
                LendingCompanion.appKitFrame(
                    $0,
                    menuBarScreen: NSScreen.screens.first?.frame ?? .zero
                )
            }
            while let lent, ContinuousClock.now - started < Self.handBackLimit,
                  await Self.readFrame(of: lent) == person {
                try? await Task.sleep(for: Self.settleStep)
            }
            Self.log.notice("hand back: the lent window left the person's screen after \(ContinuousClock.now - started, privacy: .public); \(Self.stacking, privacy: .public)")
            self?.handedBack()
        }
    }

    private func dismiss() {
        stopActivity()
        still?.land()
        landTwinStills()
        leave()
        overlay?.hide(animated: true)
    }

    /// Stops following the window and fades the border out with the worker's exit.
    private func leave() {
        unwatch()
        border.hide(fade: ControlWindowBorder.leaving)
        shown = nil
    }

    // MARK: Following the window

    private func watch() {
        var created: AXObserver?
        guard AXObserverCreate(processID, { _, _, notification, context in
            guard let context else { return }
            let name = notification as String
            MainActor.assumeIsolated {
                Unmanaged<LendingCompanion>.fromOpaque(context).takeUnretainedValue().noticed(name)
            }
        }, &created) == .success, let created else { return }
        let application = AXUIElementCreateApplication(processID)
        let context     = Unmanaged.passRetained(self)
        AXUIElementSetMessagingTimeout(application, 0.05)
        for name in Self.notifications {
            AXObserverAddNotification(
                created,
                application,
                name as CFString,
                context.toOpaque()
            )
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(created),
            .commonModes
        )
        observer         = created
        self.application = application
        self.context     = context
        let center = NSWorkspace.shared.notificationCenter
        workspace = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ].map { name in
            center.addObserver(
                forName: name,
                object : nil,
                queue  : .main
            ) { [weak self] note in
                let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                MainActor.assumeIsolated {
                    if name == NSWorkspace.didActivateApplicationNotification {
                        self?.activated(app)
                    } else if app == self?.processID {
                        self?.windowsChanged()
                    }
                }
            }
        }
        // A window drag may send no notice until it ends, so the press itself starts the following.
        presses = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            // An event from another app has no window: its location is on screen.
            let grab = event.type == .leftMouseDown ? event.locationInWindow : nil
            MainActor.assumeIsolated { self?.pressed(at: grab) }
        }
    }

    private func unwatch() {
        glance?.cancel()
        settle?.cancel()
        settling?.cancel()
        stage?.cancel()
        stopFollowingPress()
        if let presses { NSEvent.removeMonitor(presses) }
        presses = nil
        if let observer, let application {
            for name in Self.notifications {
                AXObserverRemoveNotification(
                    observer,
                    application,
                    name as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer    = nil
        application = nil
        context?.release()
        context     = nil
        workspace.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspace = []
    }

    private func noticed(_ notification: String) {
        guard lifecycle.phase == .shown else { return }
        if notification == kAXMenuOpenedNotification as String || notification == kAXMenuClosedNotification as String {
            activity?.receive(.menu(open: notification == kAXMenuOpenedNotification as String))
        } else if notification == kAXFocusedWindowChangedNotification as String {
            retrack()
        } else if Self.windowsNotifications.contains(where: { $0 as String == notification }) {
            windowsChanged()
        } else {
            // A notice while the button is down is a drag the press monitor missed; its reads follow it.
            followPress()
            if link == nil {
                refreshBorder()
                settleAfterNotice()
            }
            // Once the person stops moving or resizing, the worker looks at the result.
            glanceSoon(after: .milliseconds(800))
        }
    }

    /// The lent app coming back to the front: the border follows its main window again and the worker
    /// looks at it. Another app coming in front is the person leaving: the border and the worker go
    /// under its windows, right above the lent window, until the lent app is in front again; and Stage
    /// Manager taking the lent window to its strip takes the border away until it is back.
    private func activated(_ activated: pid_t?) {
        guard lifecycle.phase == .shown else { return }
        let inFront = activated == processID
        border.stack(above: inFront ? nil : tracked)
        overlay?.stack(above: inFront ? nil : tracked)
        if Self.stageManagerIsOn {
            if inFront, !offStage { retrack() }
            watchStage(inFront: inFront)
        } else {
            offStage = false
            guard inFront else { return }
            retrack()
        }
        if inFront { glanceSoon(after: .milliseconds(600)) }
    }

    /// Whether Stage Manager is on, read afresh from its preferences.
    private static var stageManagerIsOn: Bool {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesGetAppBooleanValue(
            "GloballyEnabled" as CFString,
            domain,
            nil
        )
    }

    /// Reads the tracked window's frame every 33 ms off the main thread until `StageWatch` decides.
    private func watchStage(inFront: Bool) {
        stage?.cancel()
        guard let tracked else { return }
        var watch = StageWatch(
            marked : shown?.size,
            inFront: inFront,
            at     : CACurrentMediaTime()
        )
        stage = Task { [weak self] in
            while !Task.isCancelled {
                let frame = await Self.readFrame(of: tracked)
                guard !Task.isCancelled, let self, lifecycle.phase == .shown else { return }
                let read = frame.map {
                    Self.appKitFrame(
                        $0,
                        menuBarScreen: NSScreen.screens.first?.frame ?? .zero
                    )
                }
                switch watch.read(
                    read,
                    at: CACurrentMediaTime()
                ) {
                case .left:
                    offStage = true
                    hideBorder(fade: ControlWindowBorder.quick)
                case .back(let frame):
                    offStage = false
                    place(frame)
                case nil:
                    break
                }
                if watch.isOver { return }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// A window of the lent app was minimised, restored, opened or closed, or the app hidden or shown:
    /// the border goes or comes back now, and again once the window server has caught up.
    private func windowsChanged() {
        refreshBorder()
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.refreshBorder()
            self?.activity?.windowsChanged()
        }
    }

    /// Tracks the lent window the person focused, otherwise the anchor while it is on the person's
    /// screen, otherwise the lent app's largest window there (`trackedWindow`). With none on screen
    /// the border goes.
    private func retrack() {
        guard lifecycle.phase == .shown, !offStage else { return }
        if let window = Self.trackedWindow(
            of     : processID,
            anchor : anchor,
            focused: focusedFrame(),
            lent   : lent,
            rows   : CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? [],
            seats  : Self.seatFrames
        ) { tracked = window }
        if !placeTracked() { hideBorder() }
    }

    /// The frame of the lent app's focused window, or of its main one, in window-server space, as
    /// Accessibility reads it: the window the person works in, whose number Accessibility does not say.
    private func focusedFrame() -> CGRect? {
        guard let application else { return nil }
        func value(
            _ attribute: String,
            of element : AXUIElement
        ) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
        }
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let found = value(attribute, of: application), CFGetTypeID(found) == AXUIElementGetTypeID() else { continue }
            let window = unsafeDowncast(found, to: AXUIElement.self)
            var origin = CGPoint.zero
            var extent = CGSize.zero
            guard let position = value(kAXPositionAttribute, of: window), CFGetTypeID(position) == AXValueGetTypeID(),
                  let size = value(kAXSizeAttribute, of: window), CFGetTypeID(size) == AXValueGetTypeID(),
                  AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &origin),
                  AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent) else { continue }
            return CGRect(
                origin: origin,
                size  : extent
            )
        }
        return nil
    }

    /// Moves the border to the tracked window's frame, only when the frame changed; with that window off
    /// screen, or another than the anchor, to the window `retrack` picks.
    private func refreshBorder() {
        if !offStage, tracked != anchor || !placeTracked() { retrack() }
    }

    /// Places the border around the tracked window: false while it is off screen or gone, or its app
    /// hidden, which the window server may not show yet as the notice comes.
    private func placeTracked() -> Bool {
        guard lifecycle.phase == .shown, let tracked,
              NSRunningApplication(processIdentifier: processID)?.isHidden != true,
              let frame = Self.windowServerFrame(of: tracked) else { return false }
        place(Self.appKitFrame(
            frame,
            menuBarScreen: NSScreen.screens.first?.frame ?? .zero
        ))
        return true
    }

    /// Takes the border off screen until a window of the app is on screen again; a press no longer follows it.
    private func hideBorder(fade: CFTimeInterval = 0) {
        guard shown != nil else { return }
        stopFollowingPress()
        border.hide(fade: fade)
        shown = nil
    }

    /// Moves the border to `frame`, in AppKit's screen space, only when it changed, putting it back on
    /// screen when it was hidden.
    private func place(
        _ frame    : CGRect,
        fromPointer: Bool = false
    ) {
        guard frame != shown else { return }
        let start = CACurrentMediaTime()
        if shown == nil { border.show(frame: frame) } else { border.update(frame: frame) }
        shown = frame
        trace?.changed(
            spent      : CACurrentMediaTime() - start,
            fromPointer: fromPointer
        )
    }

    // MARK: Following a notice

    /// NoticeSettle follows a window's frame after a notice that it moved or changed size with no press
    /// to follow: a zoom from the title bar or the green button, or the application resizing itself, is
    /// animated by the window server, and the notice comes as the animation starts or runs. The frame is
    /// read once per display frame until it has stood still for `stillReads` reads, or for `limit`.
    struct NoticeSettle {
        static let stillReads           = 3
        static let limit     : Duration = .milliseconds(1500)

        private let begun : ContinuousClock.Instant
        private var last  : CGRect?
        private var steady = 0

        init(at begun: ContinuousClock.Instant) {
            self.begun = begun
        }

        /// Takes the frame read at `time`, nil once the window is off screen: true while reads go on.
        mutating func read(
            _ frame: CGRect?,
            at time: ContinuousClock.Instant
        ) -> Bool {
            steady = frame != nil && frame == last ? steady + 1 : 0
            last   = frame
            return frame != nil && steady < Self.stillReads && time - begun < Self.limit
        }
    }

    private var settling: Task<Void, Never>?

    /// Reads the tracked window's frame once per display frame after a notice until it stands still,
    /// placing the border at each new one, and says when its size changed without a press.
    private func settleAfterNotice() {
        guard let tracked else { return }
        settling?.cancel()
        let before = shown
        settling   = Task { [weak self] in
            var settle = NoticeSettle(at: .now)
            var going  = true
            while going {
                try? await Task.sleep(for: .milliseconds(16))
                let frame = await Self.readFrame(of: tracked)
                guard !Task.isCancelled, let self, lifecycle.phase == .shown, link == nil else { return }
                if let frame {
                    place(Self.appKitFrame(
                        frame,
                        menuBarScreen: NSScreen.screens.first?.frame ?? .zero
                    ))
                }
                going = settle.read(
                    frame,
                    at: .now
                )
            }
            guard let self, let before, let after = shown, after.size != before.size else { return }
            Self.log.notice("neon: follows a change of size with no press, \(String(describing: before.size), privacy: .public) to \(String(describing: after.size), privacy: .public) at \(String(describing: after), privacy: .public)")
        }
    }

    // MARK: Following a press

    /// How far outside a window its resize edges still take a press.
    private static let grabMargin: CGFloat = 8

    /// Whether a press at `pointer` can move or resize `window`, both in AppKit's screen space: anywhere
    /// on it, or just outside it where the resize edges reach.
    static func pressGrabs(
        _ pointer: CGPoint,
        window   : CGRect
    ) -> Bool {
        window.insetBy(
            dx: -grabMargin,
            dy: -grabMargin
        ).contains(pointer)
    }

    private static var leftButtonDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    /// The left button went down at `grab`, or dragged somewhere (nil): on the tracked window, the
    /// border follows it.
    private func pressed(at grab: CGPoint?) {
        guard link == nil, let shown, Self.pressGrabs(
            grab ?? NSEvent.mouseLocation,
            window: shown
        ) else { return }
        followPress(grab: grab)
    }

    /// Follows the tracked window once per display frame while the left button stays down. `grab` is
    /// where the button went down, nil when the press was caught late and only reads may place it.
    private func followPress(grab: CGPoint? = nil) {
        let pointer = NSEvent.mouseLocation
        guard lifecycle.phase == .shown, !offStage, link == nil, Self.leftButtonDown,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        else { return }
        let link = screen.displayLink(
            target  : self,
            selector: #selector(pressFrame(_:))
        )
        link.add(
            to     : .main,
            forMode: .common
        )
        self.link = link
        pressedAt = shown
        self.grab = grab
        dragged   = false
        trace     = PressTrace()
        taken     = 0
        reader    = tracked.map { FrameReader(windowNumber: $0) }
        let start = grab == nil ? "caught late" : "from the press"
        Self.log.notice(
            "Press follow started \(start, privacy: .public) on a \(screen.maximumFramesPerSecond, privacy: .public) Hz screen"
        )
    }

    @objc private func pressFrame(_ link: CADisplayLink) {
        trace?.ticked(at: link.timestamp)
        guard Self.leftButtonDown else {
            // The button is up: one last read settles the border, and notices take over again.
            refreshBorder()
            let moved = shown != pressedAt
            stopFollowingPress()
            if moved { glanceSoon(after: .milliseconds(800)) }
            return
        }
        // Until a reading shows the window carried by the pointer, every new one is taken.
        if !dragged { takeReading() }
        guard dragged, let grab, let pressedAt else { return }
        // The window server carries a dragged window with the pointer: no round trip places it.
        let current = NSEvent.mouseLocation
        place(
            pressedAt.carried(
                from: grab,
                to  : current
            ),
            fromPointer: true
        )
    }

    /// Takes the reader's latest frame when it is new: carried by the pointer, the window is left to it
    /// and the reads stop; otherwise, as in a resize or a drag on its content, the frame places it.
    /// A read waits for the window server's next turn, which a moving window and Pro Tools keep busy:
    /// up to 17.5 ms, past a 120 Hz frame, so none is made here. The pointer needs no read.
    private func takeReading() {
        guard let reading = reader?.latest, reading.number != taken, let pressedAt else { return }
        taken = reading.number
        let menuBarScreen = NSScreen.screens.first?.frame ?? .zero
        let read          = Self.appKitFrame(
            reading.frame,
            menuBarScreen: menuBarScreen
        )
        dragged = grab.map {
            Self.movesWithPointer(
                read,
                pressed: pressedAt,
                grab   : $0,
                issued : CGPoint(
                    x: reading.issued.x,
                    y: menuBarScreen.maxY - reading.issued.y
                ),
                pointer: NSEvent.mouseLocation
            )
        } ?? false
        if dragged { stopReading() } else { place(read) }
    }

    private func stopReading() {
        guard let reader else { return }
        reader.stop()
        trace?.readOffMain(reader.reads)
        self.reader = nil
    }

    /// Whether a `read` frame shows the window carried by the pointer, all in AppKit's screen space:
    /// moved from where it was `pressed` and kept its size, lying where the pointer, gone from `grab`
    /// to `pointer`, puts it, give or take how far the pointer went since the read was `issued`.
    static func movesWithPointer(
        _ read : CGRect,
        pressed: CGRect,
        grab   : CGPoint,
        issued : CGPoint,
        pointer: CGPoint
    ) -> Bool {
        guard read.size == pressed.size, read.origin != pressed.origin else { return false }
        let carried = pressed.carried(
            from: grab,
            to  : pointer
        )
        let missed  = hypot(
            read.minX - carried.minX,
            read.minY - carried.minY
        )
        return missed <= hypot(pointer.x - issued.x, pointer.y - issued.y) + 2
    }

    /// The link retains the companion as its target until it is invalidated here.
    private func stopFollowingPress() {
        guard let link else { return }
        link.invalidate()
        stopReading()
        self.link = nil
        pressedAt = nil
        grab      = nil
        dragged   = false
        if let trace { Self.log.notice("\(trace.summary, privacy: .public)") }
        trace = nil
    }

    private func glanceSoon(after delay: Duration) {
        glance?.cancel()
        glance = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, lifecycle.phase == .shown,
                  let tracked, let frame = Self.windowServerFrame(of: tracked) else { return }
            overlay?.lookToward(screenFrame: Self.appKitFrame(
                frame,
                menuBarScreen: NSScreen.screens.first?.frame ?? .zero
            ))
        }
    }

    // MARK: Window server

    /// Braus's windows on screen that take the mouse, with their frames in AppKit's screen space: none
    /// of them may lie over the lent window while the person has it.
    static var mouseCatchers: String {
        let catching = NSApp.windows.filter { $0.isVisible && !$0.ignoresMouseEvents }
        guard !catching.isEmpty else { return "none" }
        return catching.map {
            "\(type(of: $0)) '\($0.title)' \($0.windowNumber) at \(Int($0.frame.minX)),\(Int($0.frame.minY)) "
                + "\(Int($0.frame.width))x\(Int($0.frame.height)) level \($0.level.rawValue)"
        }.joined(separator: " | ")
    }

    /// Who is in front, for the swap's log: the frontmost application, whether Braus is active, Braus's
    /// key window, its front window on screen at the normal level, the front one of all apps, and the
    /// first few on screen at that level, front to back, with their owners and frames in window-server
    /// space, which tell a window in front of another from one beside it.
    static var stacking: String {
        let rows   = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let normal = rows.filter { $0[kCGWindowLayer as String] as? Int == 0 }
        let own    = ProcessInfo.processInfo.processIdentifier
        func named(_ window: NSWindow?) -> String {
            window.map { "\(type(of: $0)) '\($0.title)' \($0.windowNumber)" } ?? "none"
        }
        let front  = normal.first { $0[kCGWindowOwnerPID as String] as? pid_t == own }
            .flatMap { $0[kCGWindowNumber as String] as? Int }
            .flatMap { NSApp.window(withWindowNumber: $0) }
        let top    = normal.first.map {
            "\($0[kCGWindowOwnerName as String] as? String ?? "?") \($0[kCGWindowNumber as String] as? Int ?? 0)"
        } ?? "none"
        let shown  = normal.prefix(5).map { row -> String in
            let bounds = (row[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            return "\(row[kCGWindowOwnerName as String] as? String ?? "?") \(row[kCGWindowNumber as String] as? Int ?? 0) "
                + "\(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(bounds.width))x\(Int(bounds.height))"
        }
        return "frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"), Braus active "
            + "\(NSApp.isActive), key \(named(NSApp.keyWindow)), front Braus window \(named(front)), top window \(top); "
            + "on screen \(shown.joined(separator: " | "))"
    }

    /// The window's frame in window-server space, nil once it is gone or off screen. Any thread may read it.
    nonisolated private static func windowServerFrame(of windowNumber: Int) -> CGRect? {
        onScreenFrame(in: CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber))
            as? [[String: Any]] ?? [])
    }

    /// The same read, made off the main thread: it waits for the window server's next turn.
    @concurrent nonisolated private static func readFrame(of windowNumber: Int) async -> CGRect? {
        windowServerFrame(of: windowNumber)
    }

    /// The frame in the window server's row for one window, nil when there is none or the window is off
    /// screen: minimised, on another Space, or its app hidden, which takes the row away altogether.
    nonisolated static func onScreenFrame(in rows: [[String: Any]]) -> CGRect? {
        guard let row = rows.first, row[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// The largest window of `processID` at the normal level in the window server's `rows`, which the
    /// border and the companion's glance follow; none whose centre lies in one of `seats`, the Seat's
    /// displays in window-server space.
    static func largestWindow(
        of processID: pid_t,
        rows        : [[String: Any]],
        outside seats: [CGRect] = []
    ) -> Int? {
        rows.compactMap { row -> (number: Int, area: CGFloat)? in
            guard row[kCGWindowOwnerPID as String] as? pid_t == processID,
                  row[kCGWindowLayer as String] as? Int == 0,
                  let number = row[kCGWindowNumber as String] as? Int,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  !seats.contains(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) })
            else { return nil }
            return (number, frame.width * frame.height)
        }.max { $0.area < $1.area }?.number
    }

    /// The window the border marks among the window server's on-screen `rows`: the `lent` window at the
    /// `focused` frame, the one the person works in, as Accessibility reads the app's focused or main
    /// window in window-server space; otherwise `anchor` while it is on the person's screen, otherwise
    /// the app's largest window there. With several windows lent the border stayed on the anchor while
    /// the person worked in another. Pro Tools keeps a 66 by 20 point decoration above its Edit window,
    /// which the border followed when it took the front one. A window on one of `seats` never counts:
    /// a Safari window whose move failed stayed there, larger than the lent one the person had made
    /// smaller, and the border and the hand-back went to it.
    static func trackedWindow(
        of processID: pid_t,
        anchor      : Int?,
        focused     : CGRect? = nil,
        lent        : Set<Int> = [],
        rows        : [[String: Any]],
        seats       : [CGRect]
    ) -> Int? {
        let worked   = rows.filter { row in
            guard let focused, let number = row[kCGWindowNumber as String] as? Int, lent.contains(number),
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return abs(frame.minX - focused.minX) <= 1 && abs(frame.minY - focused.minY) <= 1
                && abs(frame.width - focused.width) <= 1 && abs(frame.height - focused.height) <= 1
        }
        let anchored = rows.filter { $0[kCGWindowNumber as String] as? Int == anchor }
        return largestWindow(
            of     : processID,
            rows   : worked,
            outside: seats
        ) ?? largestWindow(
            of     : processID,
            rows   : anchored,
            outside: seats
        ) ?? largestWindow(
            of     : processID,
            rows   : rows,
            outside: seats
        )
    }

    /// The Seat's displays, in window-server space.
    private static var seatFrames: [CGRect] {
        let menuBarScreen = NSScreen.screens.first?.frame ?? .zero
        // The flip between the two spaces is its own inverse.
        return NSScreen.screens.filter(PersonScreen.isSeat).map {
            appKitFrame(
                $0.frame,
                menuBarScreen: menuBarScreen
            )
        }
    }

    /// FrameReader reads one window's frame from the window server on a thread of its own while a press
    /// is followed by reads, and keeps the latest for the display link to take: no read waits on the main
    /// thread. A read the window server is not busy with comes back in a tenth of a millisecond, ten
    /// thousand a second back to back (TextEdit), so reads begin at most every 2 ms. Every
    /// press on the window is followed, a click or a drag on its content too: once the frame has held for
    /// 0.1 s, reads begin every 16 ms until it changes. A still press cost 2.9 to 6.1 % of a core with
    /// reads every 2 ms, 1.9 to 2.3 % so, the display link included.
    private nonisolated final class FrameReader: Sendable {

        /// A frame read, in window-server space, where the pointer was in that space as the read began,
        /// and how many reads the reader had made with it.
        struct Reading: Sendable {
            let frame : CGRect
            let issued: CGPoint
            let number: Int
        }

        /// How many frames the reader read, how many of them differed from the one before, and the
        /// time the reads took in all and at the slowest.
        struct Reads: Sendable {
            var count   = 0
            var changed = 0
            var spent  : CFTimeInterval = 0
            var slowest: CFTimeInterval = 0
        }

        private struct State: Sendable {
            var running = true
            var latest  : Reading?
            var reads   = Reads()
        }

        /// How often reads begin while the frame changes or the press is new, and once it held for `quiet`.
        private static let interval: CFTimeInterval = 0.002
        private static let held    : CFTimeInterval = 0.016
        private static let quiet   : CFTimeInterval = 0.1

        private let state = OSAllocatedUnfairLock(initialState: State())

        /// Reads `windowNumber`'s frame until `stop()`, or until the window is gone. The thread holds
        /// the reader until its last read ends, and nothing else.
        init(windowNumber: Int) {
            let thread = Thread { [self] in read(windowNumber) }
            thread.name             = "Lent window frames"
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        var latest: Reading? { state.withLock { $0.latest } }
        var reads : Reads    { state.withLock { $0.reads } }

        func stop() { state.withLock { $0.running = false } }

        private func read(_ windowNumber: Int) {
            var changed = CACurrentMediaTime()
            while state.withLock({ $0.running }) {
                let issued = CGEvent(source: nil)?.location ?? .zero
                let start  = CACurrentMediaTime()
                guard let frame = LendingCompanion.windowServerFrame(of: windowNumber) else { return }
                let spent  = CACurrentMediaTime() - start
                let moved  = state.withLock {
                    let moved         = frame != $0.latest?.frame
                    $0.reads.count   += 1
                    $0.reads.changed += moved ? 1 : 0
                    $0.reads.spent   += spent
                    $0.reads.slowest  = max($0.reads.slowest, spent)
                    $0.latest         = Reading(
                        frame : frame,
                        issued: issued,
                        number: $0.reads.count
                    )
                    return moved
                }
                if moved { changed = start }
                let interval = start - changed < Self.quiet ? Self.interval : Self.held
                if spent < interval { Thread.sleep(forTimeInterval: interval - spent) }
            }
        }
    }

    /// PressTrace counts what following one press did, for the one line logged when it stops: how
    /// regularly the display link came, the reads off the main thread and the border's moves.
    private struct PressTrace {
        private let started    = CACurrentMediaTime()
        private var ticks      = 0
        private var lastTick   : CFTimeInterval?
        private var longestGap : CFTimeInterval = 0
        private var reads      = FrameReader.Reads()
        private var changes    = 0
        private var byPointer  = 0
        private var updating   : CFTimeInterval = 0
        private var slowestMove: CFTimeInterval = 0

        mutating func ticked(at time: CFTimeInterval) {
            ticks += 1
            if let lastTick { longestGap = max(longestGap, time - lastTick) }
            lastTick = time
        }

        mutating func readOffMain(_ reads: FrameReader.Reads) {
            self.reads = reads
        }

        mutating func changed(
            spent      : CFTimeInterval,
            fromPointer: Bool
        ) {
            changes    += 1
            byPointer  += fromPointer ? 1 : 0
            updating   += spent
            slowestMove = max(slowestMove, spent)
        }

        var summary: String {
            let seconds = CACurrentMediaTime() - started
            return String(
                format: "Press follow stopped after %.0f ms: %d ticks, longest gap %.1f ms; %d frames read off the main "
                    + "thread (%.0f/s), %d new, mean %.2f ms, slowest %.1f ms; %d frames changed (%.0f/s), "
                    + "%d by the pointer; update %.2f ms in all, slowest %.2f ms",
                seconds * 1000,
                ticks,
                longestGap * 1000,
                reads.count,
                Double(reads.count) / max(seconds, 0.001),
                reads.changed,
                reads.spent / Double(max(reads.count, 1)) * 1000,
                reads.slowest * 1000,
                changes,
                Double(changes) / max(seconds, 0.001),
                byPointer,
                updating * 1000,
                slowestMove * 1000
            )
        }
    }
}
