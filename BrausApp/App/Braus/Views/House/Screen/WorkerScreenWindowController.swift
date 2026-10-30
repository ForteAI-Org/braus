//
//  WorkerScreenWindowController.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import os
import SeatBroker
import SwiftUI

/// WorkerScreenWindowController shows one worker's screen in a window that is the held application's
/// window itself: the window has the held window's size, one point to one point, and no chrome of
/// its own, so it looks as that window would on the person's screen, and taking control lands the
/// real window exactly on it (`LendStill`). The screen's buttons sit in a glass bar over it
/// (`ScreenWindowContent`); the picture is where the window is held to be moved.
///
/// The worker and what it says sit on the window's top-right corner, half over it and half outside
/// (`ScreenWorkerPresence`), in the companion's kind of panel (`HumanControlPanel`) made ordinary: a
/// child of the window, ordered just above it at its normal level, so it moves with it, goes behind
/// Braus's other windows with it, stays on its Space and never takes the keyboard. It follows the
/// window's corner as the window moves or resizes, kept on screen, and hides while the window is
/// minimised, in full screen or closed.
///
/// Where it is moved in to stay on screen, the window server would carry it off its place with the
/// window, so while the window moves it leaves the window and is placed for the window's frame at
/// each move and each display frame, and rejoins it once free or at rest. A change of its place the
/// window's move does not explain, such as the window reaching another screen, eases in. While the
/// person drags the window, whose frame AppKit reports only now and then, the pointer places it.
///
/// The window reaches past the picture by the neon's margin, where it draws the neon and the shadow
/// itself (`ScreenWindowFrame`), so they move with it; the picture's frame (`pictureFrame`) is the
/// held window's, where the application lands as control is taken and where the window comes back.
///
/// The window is a panel that never activates Braus: a click on its buttons, Take Control's above
/// all, leaves the active app as it is, so no other window of Braus comes forward as it leaves.
///
/// The window follows the held window's size, keeping its top-left corner, and only its place is
/// remembered per worker. A held window larger than the screen's visible frame is shown scaled down
/// to fit; lending still gives the person the real size, centred on it.
///
/// It opens on its own, without the keyboard, as the worker's seat starts holding an application
/// (`TeamModel.screenHeld`), once per hold.
///
/// One window per worker: opening a worker whose window is open brings that window forward. The
/// window leaves `openWindows` when it closes. It shows the worker's real screen in place of the
/// inspector's and the conversation's (`TeamModel.screenPlace(of:)`), and closes when the worker's
/// screen ends or the toolbar's toggle puts the screen back in one of them.
final class WorkerScreenWindowController: NSWindowController, NSWindowDelegate {
    let worker: HouseWorker

    /// The team whose worker's screen the window shows.
    private let team: TeamModel

    /// The panel on the window's corner that holds the worker and what it says.
    private let presence = HumanControlPanel.make(ignoresMouse: false)

    /// The window's content: the picture in its margin, with the neon and the shadow.
    private let frameView = ScreenWindowFrame()

    /// The neon around the picture, in the colour of who has the application; the window check
    /// recolours it.
    var neon: NeonTube { frameView.tube }

    /// The picture and its bar, for the window check.
    var pictureView: NSView { frameView.picture }

    /// The picture's frame, the held window's, in AppKit's screen space.
    var pictureFrame: CGRect? { window.map { Self.picture(in: $0.frame) } }

    /// The picture's frame in a window of `frame`, and the window's frame around a picture of `frame`.
    static func picture(in frame: CGRect) -> CGRect {
        frame.insetBy(
            dx: ScreenWindowFrame.margin,
            dy: ScreenWindowFrame.margin
        )
    }

    static func window(around frame: CGRect) -> CGRect {
        frame.insetBy(
            dx: -ScreenWindowFrame.margin,
            dy: -ScreenWindowFrame.margin
        )
    }

    /// The highest the window's top goes on a screen whose visible frame is `visible`: its picture's
    /// top at the bottom of the menu bar, as a window's own top goes, the margin above it under the
    /// menu bar or off the screen.
    static func windowTop(under visible: CGRect) -> CGFloat {
        visible.maxY + ScreenWindowFrame.margin
    }

    /// That panel, for the window check and tests.
    var presencePanel: NSPanel { presence }

    /// The twins of the held application's other windows beside this one, once a source gives them.
    private(set) var twins: WindowTwins?

    /// Shows a twin of each of the application's other windows that `source` gives, beside this one.
    func showTwins(of source: TwinSource) {
        guard let window else { return }
        let team = team
        let id   = worker.id
        twins = WindowTwins(
            source     : source,
            main       : window,
            mainPicture: { [weak self] in self?.pictureFrame },
            movesWindow: { !ScreenHoverControls.isUnderway(team.humanControls[id]) },
            raiseAbove : { [weak self] in self?.raisePresence() }
        )
        twins?.sync(because: "the twins start")
    }

    /// The screen window's picture and the frame of its display when the twins last stood around it.
    private var grouped: (picture: CGRect, display: CGRect)?

    /// Carries the twins that stood on the display the window left along with it, once it rests on
    /// another, so the group and every still of Take Control stay where the person sees them; never
    /// while the windows are the person's or come back from them, whose frames place the twins.
    private func regroupTwins() {
        guard let window, let picture = pictureFrame, let screen = window.screen else { return }
        defer { grouped = (picture, screen.frame) }
        guard let grouped, grouped.display != screen.frame, !isAside, !team.handingBack.contains(worker.id)
        else { return }
        twins?.carry(
            from   : grouped.picture,
            to     : picture,
            leaving: grouped.display,
            within : screen.visibleFrame,
            because: "the screen window reached another display"
        )
    }

    /// The wait for the window to settle on a display of another scale before its stream follows.
    private var restreaming: Task<Void, Never>?

    /// Asks for the held window's stream at the new display's scale once the window has stood still
    /// there for `WindowTwin.settle`, the button up: never on every move of a drag across displays.
    private func restreamWhenSettled(from old: CGFloat) {
        restreaming?.cancel()
        restreaming = Task { [weak self] in
            var last  = self?.window?.frame
            var still = Duration.zero
            while still < WindowTwin.settle {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, let window else { return }
                still = window.frame == last && NSEvent.pressedMouseButtons & 1 == 0 ? still + .milliseconds(50) : .zero
                last  = window.frame
            }
            guard let self, let window else { return }
            let scale = window.backingScaleFactor
            guard scale != old, team.restreamMainWindow(of: worker.id, at: scale) else { return }
            Self.log.notice("Screen window rescaled \(Int(old), privacy: .public)x → \(Int(scale), privacy: .public)x")
        }
    }

    /// Where each held window lands as the person takes control, in window-server space by window
    /// number: the main window on this window's picture, each other window on its twin's.
    func lendingFrames() -> [Int: CGRect] {
        var frames = twins?.lendingFrames() ?? [:]
        if let picture = pictureFrame, let main = team.mainWindow(of: worker.id) {
            frames[main.windowNumber] = LendingCompanion.appKitFrame(
                picture,
                menuBarScreen: NSScreen.screens.first?.frame ?? .zero
            )
        }
        Self.log.notice("take control: the windows land at \(frames, privacy: .public)")
        return frames
    }

    /// Puts the worker on the corner back above the twins, ordered again above the window.
    private func raisePresence() {
        guard let window, presence.parent === window else { return }
        window.removeChildWindow(presence)
        window.addChildWindow(
            presence,
            ordered: .above
        )
        // Taken off the window, the panel went back where AppKit last had it.
        shownOffset = nil
        placePresence()
    }

    /// The display link that follows the window every frame while it moves or the panel eases, the
    /// window's frame at the last frame and the frames it has rested for since, and what following
    /// one move did, for its log line.
    private var link    : CADisplayLink?
    private var followed: CGRect?
    private var resting = 0
    private var trace   : FollowTrace?

    /// The person's drag of the window under way, which places the panel from the pointer.
    private var carry: Carry?

    /// The window frame the panel was last placed for, its place then without easing, its offset
    /// from the window's top-right corner as shown, and the easing under way: how far that offset
    /// stood from the new one when it began, fading out from `start`.
    private var placedFor  : CGRect?
    private var target     : CGRect?
    private var shownOffset: CGVector?
    private var easing     : (lag: CGVector, start: CFTimeInterval)?

    /// How long a change of the panel's place eases in, and the frames the window rests for before
    /// the link stops.
    static let easeDuration : CFTimeInterval = 0.2
    static let restingFrames = 12

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "ScreenWindow"
    )

    /// The open screen windows, by worker.
    private(set) static var openWindows: [HouseWorker.ID: WorkerScreenWindowController] = [:]

    /// Puts a controller's window on screen, taking the keyboard or not (`show(makingKey:)`). Tests
    /// replace it, so no window comes in front of the person's work, and reset it when they end.
    static var present: (WorkerScreenWindowController, Bool) -> Void = { $0.show(makingKey: $1) }

    /// The window's size until the person gives it another.
    static let contentSize = CGSize(
        width : 720,
        height: 480
    )

    /// The smallest the window goes, which still fits the control bar.
    static let minimumSize = CGSize(
        width : 480,
        height: 300
    )

    /// Opens `worker`'s screen window, or brings its open one forward, and returns its controller.
    /// `makesKey` false leaves the keyboard and the active app where the person has them.
    @discardableResult
    static func open(
        worker  : HouseWorker,
        team    : TeamModel,
        makesKey: Bool = true
    ) -> WorkerScreenWindowController {
        let controller = openWindows[worker.id] ?? WorkerScreenWindowController(
            worker: worker,
            team  : team
        )
        openWindows[worker.id] = controller
        team.setScreenWindowed(
            worker.id,
            true
        )
        present(
            controller,
            makesKey
        )
        return controller
    }

    /// Opens through `opener`, which the house's shell sets over its team; nothing without one.
    static func open(
        worker: HouseWorker,
        via opener: ((UUID) -> Void)?
    ) {
        opener?(worker.id)
    }

    /// Opens the real screen of `workerID` in `team`; nothing while it has no screen to watch.
    static func open(
        workerID: UUID,
        team    : TeamModel,
        makesKey: Bool = true
    ) {
        guard team.hasScreen(workerID),
              let worker = HouseRoster.workers(of: team).first(where: { $0.id == workerID }) else { return }

        open(
            worker  : worker,
            team    : team,
            makesKey: makesKey
        )
    }

    /// `makePicture` draws the held window in place of the team's live view, and `makeSpeech` says
    /// what the worker says in place of its turn; the window check passes a still and a state.
    init(
        worker     : HouseWorker,
        team       : TeamModel,
        makePicture: ScreenStage.Picture?   = nil,
        makeSpeech : (() -> WorkerSpeech?)? = nil
    ) {
        self.worker = worker
        self.team   = team
        let window = ScreenWindow(
            contentRect: Self.window(around: CGRect(
                origin: .zero,
                size  : Self.contentSize
            )),
            styleMask  : [.borderless, .nonactivatingPanel],
            backing    : .buffered,
            defer      : true
        )
        // An ordinary window in all but activation: at the normal level, in Spaces, Stage Manager and
        // the window cycle, and kept on screen while another app is active.
        window.isFloatingPanel           = false
        window.hidesOnDeactivate         = false
        window.becomesKeyOnlyIfNeeded    = false
        window.isExcludedFromWindowsMenu = false
        window.collectionBehavior        = [.managed, .participatesInCycle]
        window.appearance                = NSAppearance(named: .darkAqua)
        // Clear, so the held window's own corners show; the content casts the window's shadow, which
        // the window server would cast from the neon too.
        window.isOpaque                  = false
        window.backgroundColor           = .clear
        window.hasShadow                 = false
        window.isReleasedWhenClosed      = false
        // Unseen, the title still names the window in the Window menu and to VoiceOver.
        window.title = worker.name
        super.init(window: window)
        // A press brings the screen window to the front of its twins, as any window of a group.
        window.pressed = { [weak self] in
            self?.twins?.bringForward(
                TwinLayout.screenMember,
                because: "the person pressed the screen window"
            )
        }
        let picture = NSHostingView(rootView: ScreenWindowContent(
            worker     : worker,
            team       : team,
            makePicture: makePicture,
            openInBraus: Self.openInBraus,
            windowFrame: { [weak window] in window.map { Self.picture(in: $0.frame) } },
            fitWindow  : { [weak self] in
                self?.fit(
                    to  : $0,
                    from: .application
                )
            },
            close      : { [weak self] in self?.close() }
        ))
        picture.sizingOptions = []
        frameView.picture     = picture
        window.contentView    = frameView
        // Its edges resize the held window with the picture while the worker holds the application.
        let id = worker.id
        frameView.minimumPicture = Self.minimumSize
        frameView.canResize      = { [team] in !ScreenHoverControls.isUnderway(team.humanControls[id]) }
        frameView.resizes        = { [weak self] from, to, ended in
            self?.pictureResized(
                from : from,
                to   : to,
                ended: ended
            )
        }
        // On the window's own Space only, and never over another app's full screen.
        presence.collectionBehavior = [.ignoresCycle]
        // An ordinary panel at the window's level, ordered by its window alone and never floating over Braus.
        presence.isFloatingPanel    = false
        presence.level              = .normal
        let presenceContent = NSHostingView(rootView: ScreenWorkerPresence(
            team      : team,
            worker    : worker,
            makeSpeech: makeSpeech,
            open      : { [team] in
                team.selection = worker.id
                // The panel never activates Braus, so its click does here.
                NSApp.activate()
                Self.openInBraus()
            }
        ))
        presenceContent.sizingOptions = []
        presence.contentView = presenceContent
        presence.setContentSize(ScreenPresenceView.size)
        window.delegate = self
        window.setContentSize(Self.window(around: CGRect(
            origin: .zero,
            size  : Self.contentSize
        )).size)
        window.center()
        // The person's size for this worker, if any; a check or test run leaves saved sizes alone.
        if !BrausApp.isCheckRun {
            let name = "WorkerScreen \(worker.id.uuidString)"
            _ = window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
        fit(
            to  : team.screenFrame(of: worker.id).size,
            from: .opening
        )
        // A twin of each of the application's other windows, as the seat holds them.
        if let desktop = team.desktopSession(of: worker.id) {
            showTwins(of: HeldWindowSource(session: desktop))
        }
        watchScreen()
        watchControl()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        showPresence()
    }

    /// Shows the window in front, as the key window or, without `makingKey`, leaving the keyboard and
    /// the active app as they are: Braus is not activated.
    func show(makingKey: Bool) {
        guard !makingKey else { return showWindow(nil) }
        window?.orderFront(nil)
        showPresence()
    }

    func windowWillMove(_ notification: Notification) {
        follow()
        startCarry()
    }

    func windowDidMove(_ notification: Notification) { windowChanged() }
    func windowDidResize(_ notification: Notification) { windowChanged() }
    func windowDidChangeScreen(_ notification: Notification) {
        leaveSeatDisplay()
        windowChanged()
        // Another screen may fit the held window at another scale; a drag under way refits at rest.
        if link == nil {
            refit(from: .display)
            regroupTwins()
        } else {
            refitsAtRest = true
        }
        Self.log.notice("Screen window reached \(self.window?.screen?.localizedName ?? "no screen", privacy: .public) at \(String(describing: self.window?.frame), privacy: .public); \(self.frameView.margins, privacy: .public)")
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let window else { return }
        let old = notification.userInfo?[NSWindow.oldScaleFactorUserInfoKey] as? CGFloat ?? 0
        frameView.backingChanged(to: window.backingScaleFactor)
        restreamWhenSettled(from: old)
        Self.log.notice("Screen window went from \(old, privacy: .public)x to \(window.backingScaleFactor, privacy: .public)x at \(String(describing: window.frame), privacy: .public); \(self.frameView.margins, privacy: .public)")
    }
    func windowWillMiniaturize(_ notification: Notification) { hidePresence() }
    func windowDidDeminiaturize(_ notification: Notification) { showPresence() }
    func windowWillEnterFullScreen(_ notification: Notification) { hidePresence() }
    func windowDidExitFullScreen(_ notification: Notification) { showPresence() }

    func windowDidBecomeKey(_ notification: Notification) {
        twins?.restack(because: "the screen window became key")
    }

    func windowWillClose(_ notification: Notification) {
        hidePresence()
        twins?.removeAll(because: "the screen window closes")
        team.setHandingBack(
            worker.id,
            false
        )
        if team.humanControls[worker.id]?.hasStarted == true {
            Task { await team.finishHumanControl(worker.id) }
        }
        Self.openWindows[worker.id] = nil
        team.setScreenWindowed(
            worker.id,
            false
        )
    }

    /// Puts the worker on the window's corner, just above the window at its level, while the window
    /// is on screen as a window.
    private func showPresence() {
        guard let window, window.isVisible, !window.isMiniaturized, !window.styleMask.contains(.fullScreen)
        else { return }
        presence.level = window.level
        placePresence()
        frameView.showsMargin(true)
        regroupTwins()
        twins?.sync(because: "the screen window shows")
        if presence.parent == nil {
            window.addChildWindow(
                presence,
                ordered: .above
            )
        }
    }

    private func hidePresence() {
        frameView.showsMargin(false)
        twins?.hide(because: "the screen window goes off the screen")
        stopFollowing()
        window?.removeChildWindow(presence)
        presence.orderOut(nil)
        placedFor   = nil
        target      = nil
        shownOffset = nil
    }

    /// Moves the panel to the window's corner, kept inside the screen's visible frame.
    @discardableResult
    private func placePresence() -> Bool {
        guard let window else { return false }
        return placePresence(for: window.frame)
    }

    /// Places the panel for the window's frame as it changes, and follows it until it rests.
    private func windowChanged() {
        if team.handingBack.contains(worker.id), let window {
            Self.log.notice("hand back: the window's frame is now \(String(describing: window.frame), privacy: .public)")
        }
        follow()
        let start = CACurrentMediaTime()
        guard let frame = liveFrame()?.frame else { return }
        if placePresence(for: frame) {
            trace?.moved(
                spent  : CACurrentMediaTime() - start,
                movedIn: presence.parent == nil
            )
        }
    }

    /// Puts the panel on the corner of a window of `frame`, kept inside the screen's visible frame,
    /// easing in a change of its place the window's move does not explain. Moved in while shown, it
    /// leaves the window, which would carry it off its place; free, it rejoins it. Returns whether
    /// the panel moved.
    @discardableResult
    private func placePresence(
        for frame: CGRect,
        at time  : CFTimeInterval = CACurrentMediaTime()
    ) -> Bool {
        guard let window, let screen = window.screen ?? NSScreen.main else { return false }
        let target = ScreenPresenceView.panelFrame(
            around: Self.picture(in: frame),
            in    : screen.visibleFrame
        )
        if let placedFor, let last = self.target, let shownOffset, !HouseMotion.reducesMotion,
           Self.jumps(
               from: last,
               to  : target,
               as  : placedFor,
               goes: frame
           ) {
            easing = (
                lag  : CGVector(
                    dx: shownOffset.dx - (target.minX - frame.maxX),
                    dy: shownOffset.dy - (target.minY - frame.maxY)
                ),
                start: time
            )
        }
        placedFor   = frame
        self.target = target
        let lag     = lag(at: time)
        let shown   = target.offsetBy(
            dx: lag.dx,
            dy: lag.dy
        )
        let offset  = CGVector(
            dx: shown.minX - frame.maxX,
            dy: shown.minY - frame.maxY
        )
        let isFree  = shown.origin == ScreenPresenceView.panelFrame(
            around: Self.picture(in: frame),
            in    : .infinite
        ).origin
        let leaves  = presence.isVisible && !isFree && presence.parent != nil
        if leaves {
            window.removeChildWindow(presence)
            // The window server carried it where AppKit does not know, and AppKit skips a frame it
            // has: a point aside first makes the move below reach the window server.
            presence.setFrameOrigin(CGPoint(
                x: shown.minX + 1,
                y: shown.minY
            ))
        }
        // Joined, the window server keeps the panel's offset: only a new one needs placing.
        let moves   = leaves || (presence.parent == nil ? shown != presence.frame : offset != shownOffset)
        if moves {
            presence.setFrame(
                shown,
                display: false
            )
        }
        shownOffset = offset
        if presence.isVisible, isFree, presence.parent == nil {
            attachPresence()
        }
        return moves
    }

    /// Whether the panel's place going from `last` to `next` is more than the window's frame going
    /// from `before` to `after` explains: on each axis the panel stays, follows the window's corner,
    /// or lands between, as it does where it is moved in, free, or crosses from one to the other.
    static func jumps(
        from last : CGRect,
        to next   : CGRect,
        as before : CGRect,
        goes after: CGRect
    ) -> Bool {
        func beyond(
            _ panel : CGFloat,
            _ corner: CGFloat
        ) -> Bool {
            panel < min(0, corner) - 0.5 || panel > max(0, corner) + 0.5
        }
        return beyond(
            next.minX - last.minX,
            after.maxX - before.maxX
        ) || beyond(
            next.minY - last.minY,
            after.maxY - before.maxY
        )
    }

    /// What is left of the easing's lag at `time`, which ends it once spent.
    private func lag(at time: CFTimeInterval) -> CGVector {
        guard let easing else { return .zero }

        let progress = (time - easing.start) / Self.easeDuration
        guard progress < 1 else {
            self.easing = nil
            return .zero
        }
        let left = 1 - progress * progress * (3 - 2 * progress)
        return CGVector(
            dx: easing.lag.dx * left,
            dy: easing.lag.dy * left
        )
    }

    private func attachPresence() {
        guard let window, presence.parent == nil else { return }
        window.addChildWindow(
            presence,
            ordered: .above
        )
    }

    // MARK: Following

    /// Follows the window once per frame of its screen until it rests: from the start of a drag,
    /// whose moves may reach the window's frame late, or from a move.
    private func follow() {
        guard link == nil, let window, presence.isVisible, let screen = window.screen else { return }
        let link = screen.displayLink(
            target  : self,
            selector: #selector(followFrame(_:))
        )
        link.add(
            to     : .main,
            forMode: .common
        )
        self.link = link
        followed  = nil
        resting   = 0
        trace     = FollowTrace()
        pausesPresence(true)
    }

    /// Pauses the worker's animations on the corner while the window moves, or plays them on: drawn
    /// again at every frame of a move, they cost the window server for nothing it can show.
    private func pausesPresence(_ paused: Bool) {
        guard let layer = presence.contentView?.layer, paused == (layer.speed != 0) else { return }
        if paused {
            let now = layer.convertTime(
                CACurrentMediaTime(),
                from: nil
            )
            layer.speed      = 0
            layer.timeOffset = now
        } else {
            let held = layer.timeOffset
            layer.speed      = 1
            layer.timeOffset = 0
            layer.beginTime  = 0
            layer.beginTime  = layer.convertTime(
                CACurrentMediaTime(),
                from: nil
            ) - held
        }
    }

    /// The display link's rates: every frame while the panel is placed by hand, and a few a second
    /// while it rides on the window, which the window server moves with it, only to notice it
    /// reaching an edge.
    private static let placing = CAFrameRateRange(
        minimum  : 60,
        maximum  : 120,
        preferred: 120
    )
    private static let riding  = CAFrameRateRange(
        minimum  : 15,
        maximum  : 30,
        preferred: 30
    )

    /// Places the panel for the window's latest frame. Stops, the panel back on the window, once the
    /// window has rested a few frames and the easing ended.
    @objc private func followFrame(_ link: CADisplayLink) {
        guard let window, let live = liveFrame() else { return }
        let start    = CACurrentMediaTime()
        let frame    = live.frame
        let reported = window.frame
        // The pointer carrying the window, it never rests: AppKit's frame stands still between reports.
        let still    = reported == followed && !live.fromPointer
        trace?.ticked(
            at         : link.timestamp,
            pressed    : NSEvent.pressedMouseButtons & 1 != 0,
            pointer    : NSEvent.mouseLocation,
            step       : followed.map {
                hypot(
                    reported.minX - $0.minX,
                    reported.minY - $0.minY
                )
            } ?? 0,
            fromPointer: live.fromPointer
        )
        followed  = reported
        if placePresence(
            for: frame,
            at : link.timestamp
        ) {
            trace?.moved(
                spent  : CACurrentMediaTime() - start,
                movedIn: presence.parent == nil
            )
        }
        let rides = presence.parent != nil && easing == nil
        if link.preferredFrameRateRange != (rides ? Self.riding : Self.placing) {
            link.preferredFrameRateRange = rides ? Self.riding : Self.placing
        }
        resting = still ? resting + 1 : 0
        guard easing == nil, resting >= (rides ? Self.restingFrames / 4 : Self.restingFrames) else { return }
        stopFollowing()
        if presence.isVisible { attachPresence() }
    }

    /// The link retains the controller as its target until it is invalidated here.
    private func stopFollowing() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        pausesPresence(false)
        if refitsAtRest {
            refitsAtRest = false
            refit(from: .display)
        }
        regroupTwins()
        twins?.sync(because: "the screen window rests")
        twins?.restack(because: "the screen window rests")
        easing    = nil
        carry     = nil
        if let trace { Self.log.notice("\(trace.summary, privacy: .public)") }
        trace = nil
    }

    // MARK: Carrying

    /// Starts placing the panel from the pointer while the left button drags the window: the grab is
    /// the press of the event that started the move, or the pointer now when there is none.
    private func startCarry() {
        guard link != nil, let window, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        let event = NSApp.currentEvent.flatMap {
            [.leftMouseDown, .leftMouseDragged].contains($0.type) && $0.window === window ? $0 : nil
        }
        carry = Carry(
            frame: window.frame,
            grab : event.map { window.convertPoint(toScreen: $0.locationInWindow) } ?? NSEvent.mouseLocation
        )
    }

    /// The frame to place the panel for and whether the pointer gave it: where the pointer puts the
    /// window while it carries it, otherwise the window's frame, which ends a carry once the button is
    /// up or the window's size changed.
    private func liveFrame() -> (frame: CGRect, fromPointer: Bool)? {
        guard let window else { return nil }
        let reported = window.frame
        guard var carry, NSEvent.pressedMouseButtons & 1 != 0, carry.frame.size == reported.size else {
            self.carry = nil
            return (reported, false)
        }
        let pointer = NSEvent.mouseLocation
        let screen  = NSScreen.screens.first { $0.frame.contains(pointer) } ?? window.screen
        let frame   = carry.frame(
            reported: reported,
            pointer : pointer,
            under   : screen.map { Self.windowTop(under: $0.visibleFrame) } ?? .infinity
        )
        self.carry  = carry
        return (frame, true)
    }

    /// Carry is a drag of the window by the pointer, all in AppKit's screen space: the window's frame
    /// and the pointer's place when last known together, from which the pointer places the window.
    struct Carry {
        private(set) var frame: CGRect
        private(set) var grab : CGPoint

        /// The last frame the window reported.
        private var reported: CGRect

        init(
            frame: CGRect,
            grab : CGPoint
        ) {
            self.frame = frame
            self.grab  = grab
            reported   = frame
        }

        /// Where the window is with the pointer at `pointer`, its top kept under `top`. A frame the
        /// window `reported` anew is trusted first and the grab taken again from it; held under the top,
        /// it keeps the grab's height, as the window server does until the pointer comes back down.
        mutating func frame(
            reported fresh: CGRect,
            pointer       : CGPoint,
            under top     : CGFloat
        ) -> CGRect {
            if fresh != reported {
                let held = fresh.maxY >= top - 0.5
                frame    = CGRect(
                    x     : fresh.minX,
                    y     : held ? frame.minY : fresh.minY,
                    width : fresh.width,
                    height: fresh.height
                )
                grab     = CGPoint(
                    x: pointer.x,
                    y: held ? grab.y : pointer.y
                )
                reported = fresh
            }
            return frame.carried(
                from : grab,
                to   : pointer,
                under: top
            )
        }
    }

    /// Follows the team: the window closes once the worker has no screen, or its screen shows in the
    /// inspector or the conversation instead. Re-armed after each change, it stops with the window.
    private func watchScreen() {
        let team = team
        let id   = worker.id
        withObservationTracking {
            _ = team.hasScreen(id)
            _ = team.screenPlace(of: id)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, Self.openWindows[id] === self else { return }

                if team.hasScreen(id), team.screenPlace(of: id) == .window {
                    self.watchScreen()
                } else {
                    self.close()
                }
            }
        }
    }

    /// Gives the picture the held window's `size`, keeping the window's top-left corner, scaled down
    /// with its proportions when it does not fit the screen's visible frame.
    /// What asked the window for a size: the held application, the window opening, the window reaching
    /// another display, or the hand-back's end applying the application's last size.
    enum SizeSource: String {
        case application, opening, display, handBack
    }

    /// The held window's size as last reported, and whether a display change waits for the window to
    /// rest before it refits.
    private var heldSize    : CGSize?
    private var refitsAtRest = false

    /// The held window's size reported while the hand-back holds the person's frame, applied once it
    /// ends.
    private var heldBack: CGSize?

    /// Fits the window to the held window's last size again, as the display it is on changed.
    private func refit(from source: SizeSource) {
        guard let heldSize else { return }
        fit(
            to  : heldSize,
            from: source
        )
    }

    /// Gives the picture the held window's `size`, from `source`; while the hand-back holds the
    /// person's frame, the application's sizes wait for its end.
    func fit(
        to size    : CGSize,
        from source: SizeSource
    ) {
        guard size.width > 0, size.height > 0 else { return }
        var size = size
        if source == .application || source == .opening {
            let followed = Self.followed(
                size    : size,
                observed: team.desktopSession(of: worker.id)?.observedWindowNumber,
                rows    : CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements],
                    kCGNullWindowID
                ) as? [[String: Any]] ?? []
            )
            Self.log.notice("Screen window follows \(String(describing: followed.size), privacy: .public) for a reported \(String(describing: size), privacy: .public): \(followed.why, privacy: .public)")
            size     = followed.size
            heldSize = size
        }
        // The person's resize under way decides the size; the application's last one ends it.
        if source == .application, frameView.isResizing { return }
        if source == .application, team.handingBack.contains(worker.id) {
            heldBack = size
            Self.log.notice("Screen window size \(String(describing: size), privacy: .public) from the application waits for the hand-back to end")
            return
        }
        fit(to: size)
        if source == .application { followCorner(of: size) }
        Self.log.notice("Screen window size \(String(describing: size), privacy: .public) from \(source.rawValue, privacy: .public): picture \(String(describing: self.pictureFrame), privacy: .public); \(self.frameView.margins, privacy: .public)")
    }

    /// The size the window takes for a `size` the stream reports of the `observed` window: the held
    /// application's largest window at the normal level in the window server's `rows`, its main or
    /// document window, when the seat watches a smaller one of its windows, such as a palette, a strip
    /// or a dialog; never less than `minimumSize`. Says why, for the log.
    // ponytail: the largest window stands for the main one; follow each window's own size once every
    // window of the application has a screen of its own.
    static func followed(
        size    : CGSize,
        observed: Int?,
        rows    : [[String: Any]]
    ) -> (size: CGSize, why: String) {
        func frame(of number: Int) -> CGRect? {
            rows.first { $0[kCGWindowNumber as String] as? Int == number }
                .flatMap { $0[kCGWindowBounds as String] as? NSDictionary }
                .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        }
        var chosen = size
        var why    = "the watched window is unknown"
        let watched = rows.first { $0[kCGWindowNumber as String] as? Int == observed }
        if let observed, let owner = watched?[kCGWindowOwnerPID as String] as? pid_t {
            if let largest = LendingCompanion.largestWindow(of: owner, rows: rows), largest != observed,
               let main = frame(of: largest), main.width * main.height > size.width * size.height {
                chosen = main.size
                why    = "the watched window \(observed) is smaller than the application's largest, \(largest)"
            } else {
                why = "the watched window \(observed) is the application's largest"
            }
        }
        let floor = CGSize(
            width : max(chosen.width, minimumSize.width),
            height: max(chosen.height, minimumSize.height)
        )
        if floor != chosen { why += ", raised to the least size \(minimumSize)" }
        return (floor, why)
    }

    /// Gives the neon and the shadow the corner of the held window as its picture shows it, a window
    /// `size` big, at the picture's scale: read as the application gives a size, not per frame.
    private func followCorner(of size: CGSize) {
        guard let picture = team.screenView(in: .window), let layer = picture.layer,
              let radius = WindowCorner.radius(of: layer, windowWidth: size.width),
              let shown = pictureFrame else { return }
        let corner = (radius * shown.width / max(size.width, 1)).rounded()
        guard corner != frameView.corner else { return }
        frameView.setCorner(corner)
        Self.log.notice("Screen window follows the held window's corner of \(radius, privacy: .public) pt")
    }

    /// The held window's size per point of the picture while the person resizes it.
    private var resizeScale: CGFloat?

    /// The person resized the picture from `from` to `to`, in AppKit's screen space: the held window
    /// takes that size at the picture's scale, at the frame view's pace, and as the press ends the
    /// window takes the size the application kept, which snaps it back where the application refused.
    private func pictureResized(
        from  : CGRect,
        to    : CGRect,
        ended : Bool
    ) {
        let scale = resizeScale ?? (heldSize?.width ?? from.width) / max(from.width, 1)
        resizeScale = ended ? nil : scale
        let wanted  = CGSize(
            width : (to.width * scale).rounded(),
            height: (to.height * scale).rounded()
        )
        let took    = team.mainWindow(of: worker.id).flatMap { main in
            team.desktopSession(of: worker.id)?.resizeHeldWindow(
                main.windowNumber,
                to: wanted
            )
        }
        Self.log.notice("Screen window resized by the person to \(String(describing: to), privacy: .public): the held window asked for \(String(describing: wanted), privacy: .public), took \(String(describing: took), privacy: .public)\(ended ? ", the press ended" : "", privacy: .public)")
        guard ended, let size = took ?? heldSize else { return }
        fit(
            to  : size,
            from: .application
        )
    }

    func fit(to size: CGSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? size
        let scale   = min(1, visible.width / size.width, visible.height / size.height)
        let fitted  = CGSize(
            width : (size.width * scale).rounded(),
            height: (size.height * scale).rounded()
        )
        let outer   = Self.window(around: CGRect(
            origin: .zero,
            size  : fitted
        )).size
        guard outer != window.frame.size else { return }
        window.setFrame(
            CGRect(
                x     : window.frame.minX,
                y     : window.frame.maxY - outer.height,
                width : outer.width,
                height: outer.height
            ),
            display: true
        )
        twins?.sync(because: "the screen window took a new size")
    }

    /// ScreenWindow is a window with no chrome that still takes the keyboard, for the bar's buttons,
    /// and never activates Braus: a panel, with first clicks and drags as any window's.
    private final class ScreenWindow: NSPanel {
        override var canBecomeKey : Bool { true }
        override var canBecomeMain: Bool { true }

        /// Told of each press in the window before the window handles it.
        var pressed: (() -> Void)?

        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown { pressed?() }
            super.sendEvent(event)
        }

        // Its picture's top may reach the menu bar, the margin above it going under it.
        override func constrainFrameRect(
            _ frameRect: NSRect,
            to screen  : NSScreen?
        ) -> NSRect {
            guard let screen else { return frameRect }
            return frameRect.offsetBy(
                dx: 0,
                dy: min(0, WorkerScreenWindowController.windowTop(under: screen.visibleFrame) - frameRect.maxY)
            )
        }
    }

    /// Whether the window stepped aside for the lent application.
    private var isAside = false

    /// Follows the person's control of the worker's application: the application lands where this
    /// window was, so the window steps aside, out of the screen and of its Stage Manager stage, as the
    /// application's picture grows over it (`stepAside()`) or at the latest once it is lent; it comes
    /// back, without the keyboard, as control ends or the lend fails. Re-armed after each change, it
    /// stops with the window.
    private func watchControl() {
        let team = team
        let id   = worker.id
        withObservationTracking {
            let control = team.humanControls[id]
            _ = team.lendingBegun.contains(id)
            _ = control?.hasStarted
            _ = control?.lentWindow
            _ = control?.isFinishing
            _ = control?.isFinished
            _ = control?.isBlocked
            _ = control?.lendingRefused
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, Self.openWindows[id] === self else { return }

                self.controlChanged()
                self.watchControl()
            }
        }
    }

    private func controlChanged() {
        // The hand-back after Yes brings the window back and recolours it itself, and lifts its
        // curtain once the report is made, or control ended without one.
        if team.handingBack.contains(worker.id) {
            reportMayBeReady()
            return
        }
        guard let control = team.humanControls[worker.id] else { return }
        let ended = control.isFinishing || control.isFinished || control.isBlocked || control.lendingRefused
        // The neon says who has the application: the person once it is on its way to them, the worker
        // until then and again after.
        let begun = team.lendingBegun.contains(worker.id) || control.lentWindow != nil
        neon.recolour(to: control.hasStarted && begun && !ended ? .person : .worker)
        if ended {
            comeBack()
        } else if control.lentWindow != nil {
            stepAside()
        }
    }

    /// The window's wait to leave until Braus is no longer active.
    private var leaving: Task<Void, Never>?

    /// The longest the window waits, under the still, for the lent application to be activated.
    static let leavingLimit: Duration = .seconds(2)

    /// Takes the window off the screen, leaving its place to the lent application; once. While Braus
    /// is active the window waits under the still that covers it until the lent application is
    /// activated, before the windows move: ordered out from an active Braus it would make another of
    /// Braus's windows key and bring it, or Braus's stage, forward.
    func stepAside() {
        guard !isAside, let window else { return }
        isAside = true
        Self.log.notice("Screen window steps aside for the lent application; \(LendingCompanion.stacking, privacy: .public)")
        hidePresence()
        leaving = Task { [weak self] in
            let started = ContinuousClock.now
            while NSApp.isActive, ContinuousClock.now - started < Self.leavingLimit {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard !Task.isCancelled, let self, isAside else { return }
            window.orderOut(nil)
            Self.log.notice("Screen window ordered out after \(ContinuousClock.now - started, privacy: .public), visible \(window.isVisible, privacy: .public); \(LendingCompanion.stacking, privacy: .public)")
        }
    }

    /// The curtain over the window while the application is handed back.
    private var handBackCurtain: TakeControlCurtain?

    /// The least the hand-back's curtain shows, for its words to be read.
    static let handBackHold = 1.4

    /// Brings the window back over the lent window as the person answers Yes, at `frame`, where they
    /// left it, already dark under a curtain that says they handed back control: the application then
    /// leaves their screen behind it (`handedBack()`).
    func handBack(at frame: CGRect?) {
        guard let window else { return }
        let content = frameView.picture
        team.setHandingBack(
            worker.id,
            true
        )
        isAside   = false
        isReading = false
        leaving?.cancel()
        heldBack  = nil
        // The person's frame, around the lent window as read at Yes; `handBack(leavingFrom:)` corrects it.
        if let frame, !Self.isOnSeat(frame) {
            window.setFrame(
                Self.window(around: frame),
                display: false
            )
            Self.log.notice("hand back: the window's frame set once to \(String(describing: window.frame), privacy: .public) around the person's \(String(describing: frame), privacy: .public)")
        } else if let frame {
            Self.log.notice("hand back: \(String(describing: frame), privacy: .public) is on the Seat's display; the window stays at \(String(describing: window.frame), privacy: .public)")
        }
        handBackCurtain?.removeFromSuperview()
        let curtain = TakeControlCurtain(
            title  : "You handed back control",
            picture: team.screenView(in: .window)
        )
        curtain.startsDark       = true
        curtain.minimumHold      = Self.handBackHold
        curtain.frame            = content.frame
        curtain.autoresizingMask = [.width, .height]
        curtain.onGone           = { [weak curtain] in curtain?.removeFromSuperview() }
        // Over the hosting view, whose own drawing would cover a subview.
        frameView.addSubview(
            curtain,
            positioned: .above,
            relativeTo: content
        )
        handBackCurtain = curtain
        // Key, so the activation that follows the person's Yes raises it rather than Braus's other
        // windows; as a panel it takes the keyboard without activating Braus itself.
        show(makingKey: true)
        curtain.play()
        Self.log.notice("hand back: the screen window covers the lent window at \(String(describing: window.frame), privacy: .public); \(LendingCompanion.stacking, privacy: .public)")
    }

    /// Moves the window over the lent window's `frame`, in AppKit's space, as read when it leaves the
    /// person's screen, which the frame read at Yes may miss; only during the hand-back.
    func handBack(leavingFrom frame: CGRect) {
        guard team.handingBack.contains(worker.id), let window, !Self.isOnSeat(frame) else { return }
        let around = Self.window(around: frame)
        guard around != window.frame else { return }
        window.setFrame(
            around,
            display: false
        )
        Self.log.notice("hand back: the window's frame set to \(String(describing: window.frame), privacy: .public) around the lent window as it leaves, \(String(describing: frame), privacy: .public)")
    }

    /// Whether most of `frame`, in AppKit's screen space, lies on a Seat's virtual display.
    private static func isOnSeat(_ frame: CGRect) -> Bool {
        WindowTwins.screen(holding: frame).map(PersonScreen.isSeat) ?? false
    }

    /// Moves the window off a Seat's virtual display, where nobody sees it, onto the person's screen,
    /// centred there: whatever placed it, a frame read off a window the seat kept must not hide it.
    private func leaveSeatDisplay() {
        guard let window, let screen = window.screen, PersonScreen.isSeat(screen),
              let person = PersonScreen.current() else { return }
        let visible = person.visibleFrame
        window.setFrameOrigin(CGPoint(
            x: (visible.midX - window.frame.width / 2).rounded(),
            y: (visible.midY - window.frame.height / 2).rounded()
        ))
        Self.log.notice("Screen window left the Seat's display \(screen.localizedName, privacy: .public) for \(person.localizedName, privacy: .public) at \(String(describing: window.frame), privacy: .public)")
    }

    /// The lent window has left the person's screen: the curtain fades off the application, back in
    /// the window, as the neon turns to the worker's amber and the worker pops out on the corner.
    func handedBack() {
        guard let curtain = handBackCurtain, !isReading else { return }
        guard !controlEnded else { return liftHandBack(because: "control ended as the application left") }
        isReading = true
        let id    = worker.id
        Task { [weak self] in
            // The curtain's own words are read first; a quick report lifts it before it says more.
            try? await Task.sleep(for: .seconds(Self.handBackHold))
            guard let self, handBackCurtain === curtain, !controlEnded else { return }
            curtain.retitle(
                Self.readingTitle,
                mist: true
            )
            neon.recolour(to: .worker)
            Self.log.notice("hand back: Braus reads what the person did")
            try? await Task.sleep(for: Self.readingLimit)
            guard handBackCurtain === curtain, team.handingBack.contains(id) else { return }
            liftHandBack(because: "no report came within \(Self.readingLimit)")
        }
    }

    /// What the hand-back's curtain says while Braus reads what the person did with the application.
    static let readingTitle = "Reading what you did"

    /// The longest the curtain waits for the report before it lifts all the same.
    static let readingLimit: Duration = .seconds(20)

    /// Whether the application has left the person's screen and the curtain waits for the report.
    private(set) var isReading = false

    /// Whether the person's control is over: the report made and the worker resumed, or control
    /// ended without one. The window check stands in for the control.
    var endsControl: (() -> Bool)?

    private var controlEnded: Bool {
        if let endsControl { return endsControl() }
        guard let control = team.humanControls[worker.id] else { return true }
        return control.isFinished || control.isBlocked
    }

    /// Lifts the hand-back's curtain once control is over, while it waits for the report.
    func reportMayBeReady() {
        if isReading, controlEnded { liftHandBack(because: "the report is ready") }
    }

    /// Fades the hand-back's curtain off the application: the worker comes back on the corner and
    /// the neon is the worker's around the window's final frame.
    private func liftHandBack(because reason: String) {
        guard let curtain = handBackCurtain else { return }
        handBackCurtain  = nil
        isReading        = false
        Self.log.notice("hand back: the curtain lifts, \(reason, privacy: .public)")
        curtain.onFading = { [weak self] in
            guard let self else { return }
            Self.log.notice("hand back: the curtain fades off the application; \(LendingCompanion.stacking, privacy: .public)")
            team.setHandingBack(
                worker.id,
                false
            )
            // A size the application gave meanwhile, then the neon around the final frame.
            if let size = heldBack {
                heldBack = nil
                fit(
                    to  : size,
                    from: .handBack
                )
            }
            neon.recolour(to: .worker)
        }
        curtain.release()
    }

    private func comeBack() {
        guard isAside else { return }
        isAside = false
        leaving?.cancel()
        show(makingKey: false)
        twins?.show(because: "control ended")
        Self.log.notice("Screen window comes back as control ends; \(LendingCompanion.stacking, privacy: .public)")
    }

    /// FollowTrace counts what following one move did, for the one line logged when it stops: how
    /// regularly the display link came, the frames that moved the panel and the slowest, and while the
    /// left button was down, how often the window's frame stood still as the pointer moved and its
    /// largest step in one frame, which show whether a drag reaches the frame every frame.
    private struct FollowTrace {
        private let started    = CACurrentMediaTime()
        private var ticks      = 0
        private var lastTick   : CFTimeInterval?
        private var longestGap : CFTimeInterval = 0
        private var moves      = 0
        private var movedIn    = 0
        private var slowestMove: CFTimeInterval = 0
        private var pointer    : CGPoint?
        private var dragging   = 0
        private var stood      = 0
        private var largestStep: CGFloat = 0
        private var carried    = 0

        mutating func ticked(
            at time    : CFTimeInterval,
            pressed    : Bool,
            pointer    : CGPoint,
            step       : CGFloat,
            fromPointer: Bool
        ) {
            ticks   += 1
            carried += fromPointer ? 1 : 0
            if let lastTick { longestGap = max(longestGap, time - lastTick) }
            lastTick = time
            if pressed, let last = self.pointer, last != pointer {
                dragging += 1
                stood    += step == 0 ? 1 : 0
            }
            self.pointer = pressed ? pointer : nil
            largestStep  = max(largestStep, step)
        }

        mutating func moved(
            spent  : CFTimeInterval,
            movedIn: Bool
        ) {
            moves        += 1
            self.movedIn += movedIn ? 1 : 0
            slowestMove   = max(slowestMove, spent)
        }

        var summary: String {
            String(
                format: "Screen window follow stopped after %.0f ms: %d ticks, longest gap %.1f ms; %d frames moved "
                    + "the panel, %d of them moved in, slowest update %.2f ms; %d frames placed from the pointer; "
                    + "window frame stood still in %d of %d frames the pressed pointer moved, largest step %.1f pt",
                (CACurrentMediaTime() - started) * 1000,
                ticks,
                longestGap * 1000,
                moves,
                movedIn,
                slowestMove * 1000,
                carried,
                stood,
                dragging,
                largestStep
            )
        }
    }

    /// Brings Braus's own window forward; the screen window stays open beside it. Its click does not
    /// activate Braus, so this does.
    private static func openInBraus() {
        NSApp.activate()
        NSApp.windows
            .first { !($0.windowController is Self) && $0.isVisible && $0.canBecomeMain }?
            .makeKeyAndOrderFront(nil)
    }
}
