//
//  HumanControlOverlay.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit
import QuartzCore
import SeatBroker

/// HumanControlOverlay is the companion on the person's screen while they work in an app Braus holds:
/// the worker standing at the top-right corner of the screen they work on (`PersonScreen`), lit by the
/// house's own room light as it is outside its room (`HouseWorkerPortrait`), which pops up out of a hole,
/// looks toward the pointer when it comes near, asks "Are you done?" when clicked and, on Yes, jumps
/// back into the hole and is gone.
///
/// The light on the worker's front follows what lies behind it on the screen (`BackdropSampler`), and
/// its depth from the shadows of the room's lamp above and to its left: the one it casts on the screen
/// behind it, a soft pool on the ground and a dark core under its foot. At rest only Core
/// Animation runs: the brows' and body's loop the room bakes once, a slow float, and one tiny capture
/// of the backdrop every few seconds, which lights the worker again only when the backdrop changed.
/// Only while the pointer is over the worker does a soft halo blur the screen behind it
/// (`CompanionHalo`).
///
/// It lives in a borderless panel that never becomes key or main and never activates Braus, so the
/// person's app keeps its focus through every click. It moves no window and decides nothing: Yes
/// reaches `onFinishRequested` inside its click and the exit plays as the caller hides it, and
/// `askBeforeTakingBack(seconds:)` asks the same question with a countdown for the caller that is
/// about to take the app back.
final class HumanControlOverlay: NSObject {

    /// Called as the person answers Yes to the worker's question, inside the click.
    var onFinishRequested: (() -> Void)?

    /// Called as any exit begins.
    var onLeaving: (() -> Void)?

    private let panel = HumanControlPanel.make(ignoresMouse: false)
    private let stage : Stage
    private var bubble: ControlSpeechBubble?

    /// The countdown asked for and the caller waiting for its answer, while one is shown.
    private var countdown: TakeBackCountdown?
    private var asker    : CheckedContinuation<TakeBackAnswer, Never>?
    private var ticker   : Task<Void, Never>?

    /// What runs once the exit has played, while it plays, and the exit's number: a removed exit's
    /// late completion must not end a later one.
    private var leaving  : (() -> Void)?
    private var exitCount = 0

    /// The display the overlay was last shown on.
    private var displayID: CGDirectDisplayID?

    /// The backdrop's light, and the pointer the worker looks at, once the entrance has played.
    private let backdrop       = BackdropSampler()
    private var pointerMonitor : Any?
    private var isLooking      = false

    /// The soft halo behind the worker while the pointer is over it.
    private let halo = CompanionHalo()

    /// The overlay for `worker`, which waits playing `behaviour`: watching the person work, or for the
    /// debug check pondering and chuckling at once (`WorkerBehaviour.showcase`).
    init(
        worker   : HouseWorker,
        behaviour: WorkerBehaviour = .watching
    ) {
        stage = Stage(
            worker   : worker,
            behaviour: behaviour
        )
        super.init()
        panel.setContentSize(HumanControlLayout.panelSize)
        panel.contentView = stage
        stage.onMascotClick = { [weak self] in self?.mascotClicked() }
        stage.onPointer     = { [weak self] in self?.pointerMoved() }
        stage.onHover       = { [weak self] in self?.showHalo() }
        backdrop.onLight    = { [weak self] light in
            self?.stage.light(light)
            self?.halo.tint(light)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name    : NSApplication.didChangeScreenParametersNotification,
            object  : nil
        )
    }

    /// Whether the overlay is on screen, its entrance and exit included.
    var isShown: Bool { panel.isVisible }

    /// Puts the worker at the top-right corner of `screen`, below its menu bar: the screen
    /// `PersonScreen.current()` gives as the person takes control. It pops up out of a hole, or
    /// fades in under Reduce Motion. Shown already, it moves there.
    func show(on screen: NSScreen) {
        displayID = PersonScreen.displayID(of: screen)
        place(on: screen)
        guard !panel.isVisible else { return }
        stage.reset()
        panel.bringOn()
        stage.enter { [weak self] in self?.startWatching() }
    }

    /// Keeps the worker above every window while the lent application is in front, and right above
    /// the lent `window` while another one is, under that application's windows. A question with its
    /// countdown is asked in front of everything and the worker goes back there once it is answered.
    func stack(above window: Int?) {
        resting = window
        if countdown == nil { panel.stack(above: window) }
    }

    /// Where `stack(above:)` last put the worker, which a question leaves for its countdown.
    private var resting: Int?

    private func place(on screen: NSScreen) {
        panel.setFrame(
            HumanControlLayout.panelFrame(in: screen.visibleFrame),
            display: false
        )
        stage.matchScale(screen.backingScaleFactor)
        if pointerMonitor != nil { sampleBackdrop(on: screen) }
    }

    /// The screen last shown on while it is still connected, otherwise the person's screen now.
    private var screen: NSScreen? {
        NSScreen.screens.first { PersonScreen.displayID(of: $0) == displayID } ?? PersonScreen.current()
    }

    /// Screens came, went or changed size: the overlay keeps its corner, on its screen if it is still
    /// there, or moves to the person's screen.
    @objc private func screensChanged() {
        guard panel.isVisible, let screen else { return }
        place(on: screen)
    }

    /// Asks "Are you done?" with a countdown of `seconds`, showing the overlay if it is hidden, on the
    /// screen it was last on or on the person's.
    /// Yes and the timeout play the exit before they return; No closes the bubble and returns at once.
    /// A question still waiting ends as No when another is asked or the overlay is hidden; while the
    /// overlay is leaving, nothing is asked and the answer is No.
    func askBeforeTakingBack(seconds: Int) async -> TakeBackAnswer {
        end(with: .no)
        if leaving != nil { return .no }
        if !panel.isVisible {
            guard let screen else { return .no }
            show(on: screen)
        }
        closeBubble()
        let countdown = TakeBackCountdown(seconds: seconds)
        if countdown.answer == .timeout { return await leave(answer: .timeout) }
        self.countdown = countdown
        // Asked while the person works in another application: in front of its windows to be seen.
        panel.stack(above: nil)
        openBubble(countdown: countdown)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, var countdown = self.countdown else { return }
                countdown.tick()
                self.countdown = countdown
                self.bubble?.count(
                    line         : countdown.label,
                    remaining    : countdown.remaining,
                    reducesMotion: HouseMotion.reducesMotion
                )
                if let answer = countdown.answer { self.end(with: answer) }
            }
        }
        return await withCheckedContinuation { asker = $0 }
    }

    /// Closes the question still waiting for an answer as No, quietly: the person went back to the app.
    /// A question already answered, or run out, ends as it did.
    func withdrawQuestion() {
        guard let countdown, countdown.answer == nil else { return }
        end(with: .no)
    }

    /// Takes the overlay off the screen: with the exit when `animated`, at once otherwise. A question
    /// still waiting ends as No.
    func hide(animated: Bool) {
        end(with: .no)
        closeBubble()
        guard panel.isVisible else { return }
        if animated {
            if leaving == nil { playExit {} }
        } else {
            let completion = leaving
            leaving = nil
            stopWatching()
            halo.remove()
            stage.stopAnimations()
            panel.orderOut(nil)
            completion?()
        }
    }

    /// Glances at the window the person works in, `screenFrame` in AppKit screen space, as if checking
    /// their work, then goes back to its loop; nothing while the pointer or a button holds its look.
    func lookToward(screenFrame: CGRect) {
        guard panel.isVisible, leaving == nil, !isLooking, stage.focus == nil else { return }
        stage.glance(at: panel.convertPoint(fromScreen: CGPoint(
            x: screenFrame.midX,
            y: screenFrame.midY
        )))
    }

    // MARK: Watching

    /// Starts following the pointer and the backdrop, once the worker stands on the screen.
    private func startWatching() {
        guard panel.isVisible, leaving == nil, pointerMonitor == nil else { return }
        stage.startIdling()
        // The panel sees the pointer only over what it draws; elsewhere it moves over other apps.
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        if let screen { sampleBackdrop(on: screen) }
        showHalo()
    }

    private func stopWatching() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        backdrop.stop()
        isLooking = false
        stage.releaseGaze()
        showHalo()
    }

    /// Shows the halo while the pointer is over the worker, or fades it: only while the worker watches,
    /// so never through the entrance or the exit, never while a question is open, whose bubble the
    /// pointer goes to, and never under Reduce Transparency, where nothing shows through.
    private func showHalo() {
        let shows = stage.isHovered
            && pointerMonitor != nil
            && bubble == nil
            && !HouseMotion.reducesTransparency
        guard shows else {
            halo.hide()
            return
        }
        halo.show(
            in    : HumanControlLayout.haloFrame.offsetBy(
                dx: panel.frame.minX,
                dy: panel.frame.minY
            ),
            behind: panel
        )
    }

    /// Samples what lies behind the worker on `screen`; under Reduce Transparency nothing shows through.
    private func sampleBackdrop(on screen: NSScreen) {
        guard !HouseMotion.reducesTransparency else {
            backdrop.stop()
            return
        }
        backdrop.start(
            region: HumanControlLayout.mascotCell.offsetBy(
                dx: panel.frame.minX,
                dy: panel.frame.minY
            ),
            on    : screen
        )
    }

    /// The pointer moved: the worker looks at the button it is over, at the pointer while it is near,
    /// and back to its loop once it left.
    private func pointerMoved() {
        if let focus = stage.focus {
            stage.look(at: focus)
            return
        }
        let pointer = NSEvent.mouseLocation
        if HumanControlLayout.isNear(
            pointer,
            panelOrigin: panel.frame.origin
        ) {
            isLooking = true
            stage.look(at: panel.convertPoint(fromScreen: pointer))
        } else if isLooking {
            isLooking = false
            stage.releaseGaze()
        }
    }

    // MARK: Question

    private func mascotClicked() {
        guard leaving == nil, countdown == nil, !stage.isReacting else { return }
        if bubble != nil {
            closeBubble()
        } else {
            openBubble(countdown: nil)
        }
    }

    private func openBubble(countdown: TakeBackCountdown?) {
        let bubble = ControlSpeechBubble(
            stage    : HumanControlLayout.panelSize,
            countdown: countdown.map { (line: $0.label, seconds: $0.remaining) },
            opaque   : HouseMotion.reducesTransparency
        )
        bubble.onAnswer = { [weak self] yes in self?.answered(yes: yes) }
        bubble.onHover  = { [weak self, weak bubble] yes in
            guard let self, let bubble else { return }
            stage.hover(
                answer : yes,
                balloon: bubble.balloonFrame
            )
        }
        stage.addSubview(bubble)
        bubble.appear(reducesMotion: HouseMotion.reducesMotion)
        if let countdown {
            bubble.count(
                line         : countdown.label,
                remaining    : countdown.remaining,
                reducesMotion: HouseMotion.reducesMotion
            )
        }
        self.bubble     = bubble
        stage.isAsking  = true
        showHalo()
    }

    private func closeBubble() {
        bubble?.disappear()
        bubble = nil
        stage.hover(
            answer : nil,
            balloon: .zero
        )
        stage.isAsking = false
        showHalo()
    }

    /// The person answered: the worker reacts, Yes leading into the exit, No back into its loop.
    private func answered(yes: Bool) {
        if var countdown {
            countdown.reply(yes: yes)
            guard let answer = countdown.answer else { return }
            self.countdown = countdown
            ticker?.cancel()
            ticker = nil
            closeBubble()
            guard answer == .yes else {
                end(with: answer)
                if answer == .no { stage.react(.no) {} }
                return
            }
            stage.react(.yes) { [weak self] in self?.end(with: .yes) }
            return
        }
        closeBubble()
        guard yes else {
            stage.react(.no) {}
            return
        }
        stage.react(.yes) {}
        // Inside the click, so Braus may take the focus from the lent application now; the worker's
        // exit then plays while the application is taken back (`hide(animated:)`).
        onFinishRequested?()
    }

    /// Ends the countdown shown, if any, with `answer`: Yes and the timeout leave first.
    private func end(with answer: TakeBackAnswer) {
        guard let asker else { return }
        self.asker = nil
        countdown  = nil
        ticker?.cancel()
        ticker = nil
        closeBubble()
        if answer == .no { panel.stack(above: resting) }
        guard answer != .no, panel.isVisible else {
            asker.resume(returning: answer)
            return
        }
        playExit { asker.resume(returning: answer) }
    }

    private func leave(answer: TakeBackAnswer) async -> TakeBackAnswer {
        await withCheckedContinuation { continuation in
            playExit { continuation.resume(returning: answer) }
        }
    }

    // MARK: Exit

    /// Plays the exit, takes the panel off the screen and then runs `completion`.
    private func playExit(then completion: @escaping () -> Void) {
        leaving    = completion
        exitCount += 1
        stopWatching()
        let number = exitCount
        let exit   = HumanControlExit(reducesMotion: HouseMotion.reducesMotion)
        stage.beginLeaving()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.finishExit(number) }
        }
        stage.playExit(exit)
        CATransaction.commit()
        onLeaving?()
    }

    private func finishExit(_ number: Int) {
        guard number == exitCount, leaving != nil else { return }
        panel.orderOut(nil)
        stage.stopAnimations()
        let completion = leaving
        leaving = nil
        completion?()
    }
}

/// HumanControlPanel makes the overlays' panels: borderless, transparent, above normal windows, on
/// every Space, out of the window cycle, and unable to become key or main.
final class HumanControlPanel: NSPanel {

    override var canBecomeKey : Bool { false }
    override var canBecomeMain: Bool { false }

    /// The lent window the panel stays right above while another application is in front; nil while
    /// the lent one is, and the panel floats above every window.
    private(set) var anchor: Int?

    /// Floats the panel above every window, or with `window` keeps it among ordinary windows right
    /// above that one, so the windows of an application the person brought forward cover it as they
    /// cover the lent window.
    func stack(above window: Int?) {
        anchor = window
        level  = window == nil ? .floating : .normal
        if isVisible { bringOn() }
    }

    /// Puts the panel on screen where `stack(above:)` keeps it: in front, or right above its anchor,
    /// or behind every ordinary window while the anchor is off the screen (hidden, minimized).
    func bringOn() {
        guard let anchor else {
            orderFrontRegardless()
            return
        }
        let row = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(clamping: anchor)) as? [[String: Any]])?.first
        if row?[kCGWindowIsOnscreen as String] as? Bool == true {
            order(
                .above,
                relativeTo: anchor
            )
        } else {
            orderBack(nil)
        }
    }

    /// Stays where it is put: AppKit would otherwise move it down below the menu bar as it comes on
    /// screen, by however far it reaches above the screen's visible frame, off what it marks.
    override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen  : NSScreen?
    ) -> NSRect {
        frameRect
    }

    static func make(ignoresMouse: Bool) -> HumanControlPanel {
        let panel = HumanControlPanel(
            contentRect: .zero,
            styleMask  : [.borderless, .nonactivatingPanel],
            backing    : .buffered,
            defer      : true
        )
        panel.isFloatingPanel      = true
        panel.level                = .floating
        panel.collectionBehavior   = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate    = false
        panel.isOpaque             = false
        panel.backgroundColor      = .clear
        panel.hasShadow            = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior    = .none
        // Clicks on the clear parts pass through to the app below; the border lets every click through.
        if ignoresMouse { panel.ignoresMouseEvents = true }
        return panel
    }
}

extension HumanControlOverlay {

    /// Stage is the panel's content: the hole and the shadows on the ground, the worker standing over
    /// them with the shadow it casts behind it, and the bubble when one is open. The worker leans
    /// toward the answer under the pointer and reacts to the one given with its whole figure. It
    /// answers clicks only on the worker and the bubble's buttons, and reports the pointer moving over
    /// what it draws.
    final class Stage: NSView {

        var onMascotClick: (() -> Void)?
        var onPointer    : (() -> Void)?
        var onHover      : (() -> Void)?

        /// The gaze the worker's brows follow the pointer with.
        let gaze = WorkerGaze()

        /// Whether a question is open: the worker raises its brows while it asks, and thinks nothing.
        var isAsking = false {
            didSet {
                guard isAsking != oldValue else { return }
                dress(animated: true)
                showThoughts()
            }
        }

        /// Where the worker looks while the pointer is over an answer: the button's centre.
        private(set) var focus: CGPoint?

        /// Whether the worker is reacting to an answer, until the reaction has played.
        private(set) var isReacting = false

        /// Whether the pointer is over the worker.
        private(set) var isHovered = false

        /// The status the worker shows: free, relaxed, its light green.
        static let status = WorkerStatus.free

        private let worker     : HouseWorker
        private let groundView = InertView()
        private let pit        = InertView()
        private let figure     = InertView()
        private let pose       = InertView()
        private let cast       = InertView()
        private let portrait   = HouseWorkerPortrait.HostView()
        private let spot       = MascotSpot(frame: HumanControlLayout.mascotCell)
        private let thoughts   = ThoughtBubbleView()
        private let hole       = CAShapeLayer()
        private let contact    = CAGradientLayer()
        private let occlusion  = CAGradientLayer()

        private var isGazing    = false
        private var isLeaving   = false
        private var preparation = 0
        private var frontLight  = SIMD4<Float>.zero
        private var reaction    : CompanionReaction?
        private var heldBrows   = (left: BrowPose.rest, right: BrowPose.rest)
        private var heldPose    = FigurePose.rest
        private var glanceEnd   : DispatchWorkItem?

        /// The scale the cast shadow was last drawn at.
        private var castScale: CGFloat = 0

        init(
            worker   : HouseWorker,
            behaviour: WorkerBehaviour
        ) {
            self.worker = worker
            super.init(frame: CGRect(origin: .zero, size: HumanControlLayout.panelSize))
            wantsLayer = true
            portrait.face.mascot.behaviourSource = behaviour
            let ground = HumanControlLayout.ground
            let size   = HumanControlLayout.figureSize(of: worker.shape)

            hole.bounds      = CGRect(origin: .zero, size: HumanControlLayout.hole)
            hole.position    = ground
            hole.path        = CGPath(ellipseIn: hole.bounds, transform: nil)
            hole.fillColor   = CGColor(gray: 0.02, alpha: 0.95)
            hole.strokeColor = CGColor(gray: 1, alpha: 0.08)
            hole.lineWidth   = 1
            hole.transform   = CATransform3DMakeScale(0, 0, 1)

            // The soft dark pool on the ground the worker stands on, a little right of its foot, away
            // from the lamp, and the darker core right under its foot.
            contact.type       = .radial
            contact.bounds     = CGRect(origin: .zero, size: HumanControlLayout.contactShadow)
            contact.position   = CGPoint(
                x: ground.x + HumanControlLayout.contactShift,
                y: ground.y
            )
            contact.startPoint = CGPoint(x: 0.5, y: 0.5)
            contact.endPoint   = CGPoint(x: 1, y: 1)
            contact.colors     = [
                CGColor(gray: 0, alpha: 0.6),
                CGColor(gray: 0, alpha: 0.26),
                CGColor(gray: 0, alpha: 0),
            ]
            contact.locations  = [0, 0.5, 1]

            occlusion.type       = .radial
            occlusion.bounds     = CGRect(origin: .zero, size: HumanControlLayout.occlusion)
            occlusion.position   = ground
            occlusion.startPoint = CGPoint(x: 0.5, y: 0.5)
            occlusion.endPoint   = CGPoint(x: 1, y: 1)
            occlusion.colors     = [
                CGColor(gray: 0, alpha: 0.75),
                CGColor(gray: 0, alpha: 0.4),
                CGColor(gray: 0, alpha: 0),
            ]
            occlusion.locations  = [0, 0.45, 1]

            groundView.frame = bounds
            for sublayer in [hole, contact, occlusion] {
                groundView.layer?.addSublayer(sublayer)
            }

            // The figure floats and jumps; its pose, within it, leans and reacts, carrying the worker
            // and the shadow it casts on the screen behind it, drawn once (`matchScale(_:)`).
            let shadow = HumanControlLayout.castShadow
            pit.frame      = bounds
            figure.frame   = CGRect(
                x     : ground.x - size.width / 2,
                y     : ground.y,
                width : size.width,
                height: size.height
            )
            pose.frame     = figure.bounds
            cast.frame     = pose.bounds.insetBy(
                dx: -2 * shadow.blur,
                dy: -2 * shadow.blur
            ).offsetBy(
                dx: shadow.offset.width,
                dy: shadow.offset.height
            )
            portrait.frame = pose.bounds
            for view in [cast, portrait] as [NSView] {
                pose.addSubview(view)
            }
            figure.addSubview(pose)
            pit.addSubview(figure)

            spot.setAccessibilityLabel(worker.name)
            spot.onClick = { [weak self] in self?.clicked() }
            spot.onHover = { [weak self] hovered in self?.hovered(hovered) }
            thoughts.frame = bounds
            for view in [groundView, pit, thoughts, spot] as [NSView] {
                addSubview(view)
            }
            addTrackingArea(NSTrackingArea(
                rect    : .zero,
                options : [.mouseMoved, .activeAlways, .inVisibleRect],
                owner   : self,
                userInfo: nil
            ))
            dress(animated: false)
        }

        required init?(coder: NSCoder) {
            nil
        }

        /// Only the worker and the bubble's buttons take clicks; the rest of the panel is not there.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }

        override func mouseMoved(with event: NSEvent) {
            onPointer?()
        }

        /// Shows the worker as the portrait draws it: its brows reacting, asking, attentive under the
        /// pointer, or its status's own, the backdrop's light on its front, a squash for each click, and
        /// its body's reaction, whose poses the room bakes as it appears.
        private func dress(animated: Bool) {
            let reduces = HouseMotion.reducesMotion
            portrait.show(
                HouseWorkerPortrait(
                    shape       : worker.shape,
                    status      : Self.status,
                    size        : HumanControlLayout.sphere,
                    brows       : reaction?.brows ?? (isAsking ? .asking : (isHovered ? .listening : nil)),
                    seed        : WorkerBehaviour.seed(for: worker.id),
                    gaze        : gaze,
                    capsuleLight: frontLight,
                    changeFade  : reduces ? nil : HeroLight.fade,
                    preparation : preparation,
                    action      : reduces || isLeaving ? nil : reaction?.action,
                    takesActions: true
                ),
                animated: animated
            )
            showThoughts()
        }

        /// The thought bubble on the loop now playing, hidden while a question is open, while the
        /// worker looks at something, and while it leaves.
        private func showThoughts() {
            thoughts.isHidden = !ThoughtBubble.shows(
                isAsking : isAsking,
                isGazing : isGazing,
                isLeaving: isLeaving
            )
            thoughts.sync(
                loop : portrait.face.mascot.behaviour,
                start: portrait.face.mascot.behaviourStart
            )
        }

        /// Looks at `point` in the panel, pausing the loop and the thoughts.
        func look(at point: CGPoint) {
            glanceEnd?.cancel()
            glanceEnd = nil
            isGazing  = true
            showThoughts()
            gaze.pointerMoved(toWindow: point)
        }

        /// Stops looking: the loop starts again, and the thoughts with it.
        func releaseGaze() {
            glanceEnd?.cancel()
            glanceEnd = nil
            gaze.pointerLeft(after: 0)
            isGazing = false
            showThoughts()
        }

        /// Looks at `point` for a moment, as if checking the person's work, then back to the loop.
        func glance(at point: CGPoint) {
            look(at: point)
            let end = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.releaseGaze() }
            }
            glanceEnd = end
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 1.6,
                execute : end
            )
        }

        /// The pointer is over Yes, over No, or over neither, under `balloon`: the worker looks at the
        /// button, leaning toward Yes with its brows lifted in expectation, or tilting its head away
        /// from No with one brow raised as if asking for a bit longer. Under Reduce Motion it only looks.
        func hover(
            answer yes: Bool?,
            balloon   : CGRect
        ) {
            focus = yes.map {
                HumanControlLayout.gazeTarget(
                    yes  : $0,
                    under: balloon
                )
            }
            let held   = yes.map(CompanionReaction.hover) ?? (left: .rest, right: .rest)
            let leaned = yes.map(CompanionReaction.lean) ?? .rest
            if !HouseMotion.reducesMotion {
                if held != heldBrows {
                    portrait.face.mascot.holdBrows(
                        from: heldBrows,
                        to  : held
                    )
                }
                if leaned != heldPose { lean(to: leaned) }
            }
            heldBrows = held
            heldPose  = leaned
            if let focus { look(at: focus) }
        }

        /// Springs the figure from where it shows now to `target` and holds it there.
        private func lean(to target: FigurePose) {
            guard let layer = pose.layer else { return }
            let spring = CASpringAnimation(keyPath: "transform")
            spring.damping               = 18
            spring.stiffness             = 300
            spring.fromValue             = NSValue(caTransform3D: (layer.presentation() ?? layer).transform)
            spring.toValue               = NSValue(caTransform3D: Self.transform(
                target,
                of: layer
            ))
            spring.duration              = spring.settlingDuration
            spring.fillMode              = .forwards
            spring.isRemovedOnCompletion = false
            layer.add(spring, forKey: Self.leanKey)
        }

        /// Reacts to an answer, then runs `completion`: the brows' expression and their motion, the
        /// whole figure's, the body's reaction from the poses baked ahead within it, the shadows on the
        /// ground paling as it hops, and for No the loop back afterwards. Under Reduce Motion only the
        /// expression changes, and `completion` runs at once.
        func react(
            _ reaction: CompanionReaction,
            then completion: @escaping () -> Void
        ) {
            hover(
                answer : nil,
                balloon: .zero
            )
            self.reaction = reaction
            isReacting    = true
            dress(animated: true)
            // Only the brows' finite reaction joins this transaction; the room's body loops for ever.
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isReacting = false
                    if reaction == .no {
                        self.reaction = nil
                        self.dress(animated: true)
                    }
                    completion()
                }
            }
            if !HouseMotion.reducesMotion {
                portrait.face.mascot.playBrows(
                    reaction.keys,
                    duration: reaction.duration
                )
                play(reaction)
            }
            CATransaction.commit()
        }

        /// Plays `reaction`'s whole figure once, added to its lean, and pales and shrinks the shadows
        /// on the ground as it rises off it, the core under its foot most.
        private func play(_ reaction: CompanionReaction) {
            guard let layer = pose.layer else { return }
            let keys   = reaction.figure
            let times  = keys.map { NSNumber(value: $0.time / reaction.duration) }
            let curves = keys.dropFirst().map { HoleJump.timing($0.curve) }
            let motion = CAKeyframeAnimation(keyPath: "transform")
            motion.values          = keys.map {
                NSValue(caTransform3D: Self.transform(
                    $0.pose,
                    of: layer
                ))
            }
            motion.keyTimes        = times
            motion.timingFunctions = curves
            motion.duration        = reaction.duration
            motion.isAdditive      = true
            layer.add(motion, forKey: Self.reactKey)

            let tracks: [(CALayer, String, Double)] = [
                (contact, "transform.scale", 1.6),
                (contact, "opacity", 1.6),
                (occlusion, "transform.scale", 1.6),
                (occlusion, "opacity", 4),
            ]
            for (shadow, keyPath, fall) in tracks {
                let pale = CAKeyframeAnimation(keyPath: keyPath)
                pale.values          = keys.map { -fall * $0.pose.dy }
                pale.keyTimes        = times
                pale.timingFunctions = curves
                pale.duration        = reaction.duration
                pale.isAdditive      = true
                shadow.add(pale, forKey: Self.reactKey + keyPath)
            }
        }

        /// The transform that shows `pose` on `layer`: turned, sized and moved about the foot of its box,
        /// where the figure stands on the ground.
        private static func transform(
            _ pose  : FigurePose,
            of layer: CALayer
        ) -> CATransform3D {
            // The layer turns and scales about its anchor; the foot is from there, y up.
            let foot   = CGPoint(
                x: (0.5 - layer.anchorPoint.x) * layer.bounds.width,
                y: -layer.anchorPoint.y * layer.bounds.height
            )
            let height = layer.bounds.height
            var shown  = CATransform3DMakeTranslation(
                foot.x + pose.dx * height,
                foot.y + pose.dy * height,
                0
            )
            shown = CATransform3DRotate(
                shown,
                pose.turn,
                0,
                0,
                1
            )
            shown = CATransform3DScale(
                shown,
                1 + pose.width,
                1 + pose.height,
                1
            )
            return CATransform3DTranslate(
                shown,
                -foot.x,
                -foot.y,
                0
            )
        }

        /// Lights the worker's front with the backdrop's `light`.
        func light(_ light: SIMD4<Float>) {
            frontLight = light
            dress(animated: true)
        }

        private func clicked() {
            preparation += 1
            dress(animated: true)
            onMascotClick?()
        }

        private func hovered(_ hovered: Bool) {
            isHovered = hovered
            dress(animated: true)
            onHover?()
        }

        /// Puts the worker back on its feet, visible, with the hole closed, its brows its own.
        func reset() {
            stopAnimations()
            isHovered  = false
            isLeaving  = false
            isReacting = false
            reaction   = nil
            focus      = nil
            heldPose   = .rest
            if heldBrows != (left: .rest, right: .rest) {
                portrait.face.mascot.holdBrows(
                    from: heldBrows,
                    to  : (left: .rest, right: .rest)
                )
                heldBrows = (left: .rest, right: .rest)
            }
            dress(animated: false)
        }

        /// Renders the ground at the screen's `scale`, and draws the cast shadow for it once; the
        /// portrait follows its window itself.
        func matchScale(_ scale: CGFloat) {
            for layer in [hole, contact, occlusion] as [CALayer] {
                layer.contentsScale = scale
            }
            guard scale != castScale, let layer = cast.layer else { return }
            castScale = scale
            layer.opacity       = HumanControlLayout.castShadow.opacity
            layer.contentsScale = scale
            layer.contents      = Self.castShadow(
                of   : HumanControlLayout.outline(of: worker.shape),
                size : pose.bounds.size,
                in   : cast.frame,
                scale: scale
            )
        }

        /// The `shadow` the worker casts on the screen behind it, at `scale` pixels per point, in `box`,
        /// in the figure's space: its silhouette of `size`, moved and blurred, whole near the ground and
        /// paler toward its top, and cut where the ground meets it, past which the pool and the core
        /// on the ground carry it on. The screen window's worker casts it too (`ScreenPresenceView`).
        static func castShadow(
            of outline: CGPath,
            size      : CGSize,
            in box    : CGRect,
            scale     : CGFloat,
            shadow    : (offset: CGSize, blur: CGFloat) = (
                offset: HumanControlLayout.castShadow.offset,
                blur  : HumanControlLayout.castShadow.blur
            )
        ) -> CGImage? {
            guard let context = CGContext(
                data            : nil,
                width           : Int((box.width * scale).rounded(.up)),
                height          : Int((box.height * scale).rounded(.up)),
                bitsPerComponent: 8,
                bytesPerRow     : 0,
                space           : CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.scaleBy(
                x: scale,
                y: scale
            )
            // Only the blurred shadow lands in the box: the silhouette is drawn a box's width right of it.
            context.saveGState()
            context.setShadow(
                offset: CGSize(
                    width : -box.width * scale,
                    height: 0
                ),
                blur  : shadow.blur * scale,
                color : CGColor(gray: 0, alpha: 1)
            )
            context.translateBy(
                x: box.width - box.minX + shadow.offset.width,
                y: -box.minY + shadow.offset.height
            )
            context.addPath(outline)
            context.fillPath()
            context.restoreGState()

            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors     : [0, 1, 1, 0.3].map {
                    CGColor(
                        gray : 0,
                        alpha: $0
                    )
                } as CFArray,
                locations  : [0, 0.06, 0.3, 1]
            )
            if let gradient {
                // The ground is at the figure's foot, y up.
                context.setBlendMode(.destinationIn)
                context.drawLinearGradient(
                    gradient,
                    start  : CGPoint(x: 0, y: -box.minY),
                    end    : CGPoint(x: 0, y: -box.minY + size.height),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            return context.makeImage()
        }

        /// Starts a slow float of the whole worker, its shadows on the ground growing smaller and fainter
        /// as it rises. Nothing under Reduce Motion.
        func startIdling() {
            guard !HouseMotion.reducesMotion, let body = figure.layer else { return }
            let tracks: [(CALayer, String, Double, Double)] = [
                (body, "transform.translation.y", 0, Double(HumanControlLayout.sphere) * 0.04),
                (contact, "transform.scale", 1, 0.9),
                (contact, "opacity", 1, 0.7),
                (occlusion, "transform.scale", 1, 0.85),
                (occlusion, "opacity", 1, 0.55),
            ]
            for (layer, keyPath, from, to) in tracks {
                let float = CABasicAnimation(keyPath: keyPath)
                float.fromValue      = from
                float.toValue        = to
                float.duration       = HouseTiming.waitingBreath
                float.autoreverses   = true
                float.repeatCount    = .infinity
                float.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                float.isAdditive     = keyPath.hasPrefix("transform.translation")
                layer.add(float, forKey: Self.floatKey + keyPath)
            }
        }

        func stopAnimations() {
            for layer in [hole, contact, occlusion, figure.layer, pose.layer, layer].compactMap({ $0 }) {
                layer.removeAllAnimations()
            }
            pit.layer?.mask = nil
        }

        /// Plays `entrance` and then `completion`: the worker pops up out of a hole, or the stage
        /// fades in.
        func enter(then completion: @escaping () -> Void) {
            let entrance = HumanControlEntrance(reducesMotion: HouseMotion.reducesMotion)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    self?.settle()
                    completion()
                }
            }
            switch entrance {
            case .fade:
                layer?.add(
                    Self.fade(from: 0, to: 1, duration: entrance.duration),
                    forKey: Self.moveKey
                )
            case .rise:
                jump(
                    HumanControlBeats.entrance,
                    duration: entrance.duration
                )
            }
            CATransaction.commit()
        }

        /// Takes the finished entrance off the layers, the worker standing at rest.
        private func settle() {
            for layer in [hole, contact, occlusion, figure.layer, layer].compactMap({ $0 }) {
                layer.removeAnimation(forKey: Self.moveKey)
            }
            pit.layer?.mask = nil
        }

        /// Readies the worker to leave, before the exit's transaction: no thoughts, and the body back from
        /// its reaction to its loop, whose animations repeat for ever and so must stay out of it.
        func beginLeaving() {
            isLeaving = true
            dress(animated: true)
        }

        /// Adds `exit`'s animations, in the caller's transaction.
        func playExit(_ exit: HumanControlExit) {
            switch exit {
            case .fade:
                layer?.add(
                    Self.fade(from: 1, to: 0, duration: exit.duration),
                    forKey: Self.moveKey
                )
            case .fall:
                for shadow in [contact, occlusion] {
                    for key in ["transform.scale", "opacity"] {
                        shadow.removeAnimation(forKey: Self.floatKey + key)
                    }
                }
                jump(
                    HumanControlBeats.exit,
                    duration: exit.duration
                )
            }
        }

        /// Plays `beats` through the hole: the hole opening and closing, the worker scaled about its
        /// foot and risen, its shadows on the ground following, the pit clipped to the ground meanwhile.
        private func jump(
            _ beats : HumanControlBeats,
            duration: Double
        ) {
            guard let body = figure.layer else { return }
            pit.layer?.mask = HoleJump.groundMask(
                hole: hole.position,
                size: HumanControlLayout.hole,
                in  : bounds
            )
            hole.add(HoleJump.opening(duration: duration), forKey: Self.moveKey)
            body.add(
                HoleJump.figure(
                    beats,
                    of      : body,
                    duration: duration
                ),
                forKey: Self.moveKey
            )
            for shadow in [contact, occlusion] {
                shadow.add(
                    HoleJump.group(
                        [
                            ("transform.scale", beats.shadowScale),
                            ("opacity", beats.shadowOpacity),
                        ],
                        beats   : beats,
                        duration: duration
                    ),
                    forKey: Self.moveKey
                )
            }
        }

        private static func fade(
            from    : Double,
            to      : Double,
            duration: Double
        ) -> CAAnimation {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue   = to
            return HoleJump.held(fade, duration: duration)
        }

        private static let floatKey = "control.float"
        private static let moveKey  = "control.move"
        private static let leanKey  = "control.lean"
        private static let reactKey = "control.react"
    }
}

/// InertView is a layer-backed view that never takes a click.
private final class InertView: NSView {

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// MascotSpot is the clickable box over the worker: it answers the first click without activating
/// Braus, tells when the pointer is over it, and VoiceOver presses it as a button.
private final class MascotSpot: NSView {

    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Asks whether you are done with this app")
        addTrackingArea(NSTrackingArea(
            rect    : .zero,
            options : [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner   : self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
