//
//  ScreenPresenceView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit
import QuartzCore
import SwiftUI

/// ScreenPresenceView is the worker on the top-right corner of its screen window, half over the
/// window and half outside it, in a panel of its own (`WorkerScreenWindowController`): the
/// companion's worker (`HouseWorkerPortrait`, as `HumanControlOverlay` stands it) at a corner's
/// size, lit on its front by what lies behind it as the companion is (`BackdropSampler`), with the
/// shadow it casts, and what it says in a bubble to its left (`ScreenSpeechBubble`).
///
/// It plays its status's own loop. It squashes once, a small nod, as each new action starts, and
/// lifts its brows while it says something. Under the pointer it turns see-through, so what it
/// covers shows. While it says something, a click on the bubble opens its conversation and closes
/// the bubble; nothing else takes a click. At rest only Core Animation runs, the brows' and body's
/// loop, and one tiny capture of the backdrop every few seconds while the panel is on screen,
/// started again once the window stops moving.
///
/// As the person takes control it dives into a hole in the window, the companion's exit
/// (`HoleJump`), and stays away while they have the application: it pops out of the companion's hole
/// on their screen instead (`HumanControlOverlay`). It comes back as control ends.
final class ScreenPresenceView: NSView {

    /// Opens the worker's conversation in Braus.
    var onOpen: (() -> Void)?

    /// The side of the worker's sphere: a figure about 50 points wide, half as large again as the
    /// rows' worker.
    static let sphere: CGFloat = 50

    /// The box that holds every shape's figure at that size, in whole points.
    static let figure: CGSize = {
        let sizes = WorkerShape.allCases.map { shape in
            HumanControlLayout.figureSize(
                of    : shape,
                sphere: sphere
            )
        }
        return CGSize(
            width : (sizes.map(\.width).max() ?? sphere).rounded(.up),
            height: (sizes.map(\.height).max() ?? sphere).rounded(.up)
        )
    }()

    /// The room between the figure and the panel's top and right edges, for its squash and its
    /// shadow.
    static let margin = (top: CGFloat(8), right: CGFloat(12))

    /// How far the figure's box reaches past the window's top-right corner: half its width to the
    /// right and two fifths of its height above, so the worker sits on the corner.
    static let overhang = CGSize(
        width : (figure.width * 0.5).rounded(),
        height: (figure.height * 0.4).rounded()
    )

    /// How far the bubble's trail reaches past the figure's side, toward its brows.
    static let overlap: CGFloat = 6

    /// The view's size: the bubble at its widest, the figure, and their margins.
    static let size = CGSize(
        width : ScreenSpeechBubble.size.width - overlap + figure.width + margin.right,
        height: margin.top + figure.height + 12
    )

    /// The panel's frame on the corner of a window of `frame`, both in AppKit's screen space, moved
    /// in from the right and the top as far as needed to stay inside `visibleFrame`.
    static func panelFrame(
        around frame   : CGRect,
        in visibleFrame: CGRect
    ) -> CGRect {
        CGRect(
            x     : min(frame.maxX + overhang.width + margin.right, visibleFrame.maxX) - size.width,
            y     : min(frame.maxY + overhang.height + margin.top, visibleFrame.maxY) - size.height,
            width : size.width,
            height: size.height
        )
    }

    /// How much of the worker shows while the pointer is over it.
    static let hoveredOpacity: Float = 0.35

    /// The shadow the worker casts on the window, the companion's at this size.
    static let castShadow = (
        offset : CGSize(
            width : 4,
            height: -2
        ),
        blur   : CGFloat(4),
        opacity: HumanControlLayout.castShadow.opacity
    )

    private let pit      = NSView()
    private let hole     = CAShapeLayer()
    private let cast     = NSView()
    private let portrait = HouseWorkerPortrait.HostView()
    private let bubble   = ScreenSpeechBubble(frame: CGRect(
        origin: .zero,
        size  : ScreenSpeechBubble.size
    ))
    private let backdrop = BackdropSampler()

    private var worker      : HouseWorker
    private var light       = SIMD4<Float>.zero
    private var preparation = 0
    private var isHovered   = false

    /// Whether the worker has dived away while the person has its application, and the dive's run,
    /// so a late completion of an undone dive changes nothing.
    private(set) var isAway = false
    private var dives       = 0

    /// The hole the worker dives through: the companion's, at this worker's size.
    static let holeSize = CGSize(
        width : HumanControlLayout.hole.width * figure.width / HumanControlLayout.figure.width,
        height: HumanControlLayout.hole.height * figure.width / HumanControlLayout.figure.width
    )

    /// The pause after the panel's last move before the backdrop's sampling starts again.
    private var resample: Task<Void, Never>?

    /// The panel's moves and its showing or hiding, which start the backdrop's sampling again.
    private static let watched = [
        NSWindow.didMoveNotification,
        NSWindow.didChangeOcclusionStateNotification,
    ]

    /// The line of the last bubble the person clicked, which stays closed until the worker says
    /// something else.
    private var dismissed: String?

    /// The shape and the backing scale the cast shadow was last drawn for.
    private var castFor: (shape: WorkerShape, scale: CGFloat)?

    init(worker: HouseWorker) {
        self.worker = worker
        super.init(frame: CGRect(
            origin: .zero,
            size  : Self.size
        ))
        wantsLayer = true
        cast.wantsLayer = true
        pit.wantsLayer  = true
        hole.bounds      = CGRect(
            origin: .zero,
            size  : Self.holeSize
        )
        hole.path        = CGPath(
            ellipseIn: hole.bounds,
            transform: nil
        )
        hole.fillColor   = CGColor(
            gray : 0.02,
            alpha: 0.95
        )
        hole.strokeColor = CGColor(
            gray : 1,
            alpha: 0.08
        )
        hole.lineWidth   = 1
        hole.transform   = CATransform3DMakeScale(0, 0, 1)
        pit.layer?.addSublayer(hole)
        for view in [pit, cast, portrait, bubble] {
            addSubview(view)
        }
        addTrackingArea(NSTrackingArea(
            rect    : .zero,
            options : [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner   : self,
            userInfo: nil
        ))
        setAccessibilityElement(true)
        backdrop.onLight = { [weak self] light in
            self?.light = light
            self?.dress(animated: true)
        }
        dress(animated: false)
        describe()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Shows `worker` saying `speech`, nil for nothing: a new action nods, and a change of status or
    /// of the brows dresses the worker again.
    func show(
        worker: HouseWorker,
        speech: WorkerSpeech?
    ) {
        var speech = speech
        if case .saying(let line)? = speech {
            if line == dismissed { speech = nil }
        } else if speech != nil {
            dismissed = nil
        }
        var nods = false
        if case .acting? = speech, speech != bubble.speech { nods = true }
        let wasSaying = isSaying
        let reshapes  = worker.shape != self.worker.shape
        let redresses = nods || reshapes || worker.status != self.worker.status
        if nods { preparation += 1 }
        self.worker = worker
        bubble.show(speech)
        if redresses || isSaying != wasSaying { dress(animated: true) }
        if reshapes { needsLayout = true }
        describe()
        pointerMoved()
    }

    private var isSaying: Bool {
        if case .saying? = bubble.speech { true } else { false }
    }

    /// Dresses the worker as the companion is: its status's light and loop, the backdrop's light on
    /// its front, its brows lifted while it says something, a squash for each new action.
    private func dress(animated: Bool) {
        portrait.show(
            HouseWorkerPortrait(
                shape       : worker.shape,
                status      : worker.status,
                size        : Self.sphere,
                brows       : isSaying ? .asking : nil,
                seed        : WorkerBehaviour.seed(for: worker.id),
                capsuleLight: light,
                changeFade  : HouseMotion.reducesMotion ? nil : HeroLight.fade,
                preparation : preparation
            ),
            animated: animated
        )
    }

    override func layout() {
        super.layout()
        let size = HumanControlLayout.figureSize(
            of    : worker.shape,
            sphere: Self.sphere
        )
        // Every shape stands on the same ground, centred in the box at the top-right corner.
        let box  = CGRect(
            x     : bounds.maxX - Self.margin.right - Self.figure.width,
            y     : bounds.maxY - Self.margin.top - Self.figure.height,
            width : Self.figure.width,
            height: Self.figure.height
        )
        portrait.frame = CGRect(
            x     : (box.midX - size.width / 2).rounded(),
            y     : box.minY,
            width : size.width,
            height: size.height
        )
        pit.frame      = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hole.position  = CGPoint(
            x: portrait.frame.midX,
            y: portrait.frame.minY
        )
        CATransaction.commit()
        // The trail leads to the figure's side, level with its brows.
        let face       = Self.face(of: worker.shape)
        bubble.frame   = CGRect(
            origin: CGPoint(
                x: portrait.frame.minX + Self.overlap - ScreenSpeechBubble.size.width,
                y: (portrait.frame.minY + face.y - ScreenSpeechBubble.face.y).rounded()
            ),
            size  : ScreenSpeechBubble.size
        )
        let shadow     = Self.castShadow
        let reach      = portrait.bounds.insetBy(
            dx: -2 * shadow.blur,
            dy: -2 * shadow.blur
        ).offsetBy(
            dx: shadow.offset.width,
            dy: shadow.offset.height
        )
        cast.frame     = reach.offsetBy(
            dx: portrait.frame.minX,
            dy: portrait.frame.minY
        )
        drawCast(in: reach)
    }

    /// Where the brows of `shape` show in its portrait at this size, from its bottom-left corner,
    /// as the portrait places the room's scene (`HouseWorkerPortrait.HostView`).
    static func face(of shape: WorkerShape) -> CGPoint {
        let side   = HouseWorkerPortrait.sceneSide(for: sphere)
        let bounds = HouseWorkerPortrait.silhouette(
            of  : shape,
            side: side
        ).boundingRect
        let anchor = RoomCamera.tilted.face(
            of  : shape,
            in  : CGSize(
                width : side,
                height: side
            ),
            lean: HouseWorkerPortrait.lean
        )?.anchor ?? .zero
        // The anchor is from the scene's centre with y down; the portrait's y is up from its foot.
        return CGPoint(
            x: side / 2 + anchor.dx - bounds.minX,
            y: bounds.maxY - side / 2 - anchor.dy
        )
    }

    /// Draws the cast shadow once for the worker's shape at the window's scale, as the companion's.
    private func drawCast(in reach: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        guard let layer = cast.layer, castFor.map({ $0.shape != worker.shape || $0.scale != scale }) ?? true
        else { return }
        castFor = (worker.shape, scale)
        layer.opacity       = Self.castShadow.opacity
        layer.contentsScale = scale
        layer.contents      = HumanControlOverlay.Stage.castShadow(
            of    : HumanControlLayout.outline(
                of    : worker.shape,
                sphere: Self.sphere
            ),
            size  : portrait.bounds.size,
            in    : reach,
            scale : scale,
            shadow: (
                offset: Self.castShadow.offset,
                blur  : Self.castShadow.blur
            )
        )
    }

    // MARK: Away

    /// Dives into the hole once the curtain's words are in (`TakeControlBeats`), its bubble and cast
    /// shadow fading first, and stays away; under Reduce Motion it fades out. Nothing while already
    /// away.
    func diveAway() {
        guard !isAway, let layer else { return }
        isAway = true
        dives += 1
        let run   = dives
        let start = CACurrentMediaTime() + TakeControlBeats.diveStart
        let calm  = HouseMotion.reducesMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.landedAway(run) }
        }
        for view in calm ? [bubble, cast, portrait] : [bubble, cast] {
            Self.fadeOut(
                view,
                at      : start,
                duration: calm ? 0.25 : 0.15
            )
        }
        if !calm, let body = portrait.layer {
            layer.mask = HoleJump.groundMask(
                hole: hole.position,
                size: Self.holeSize,
                in  : bounds
            )
            for (target, animation) in [
                (hole as CALayer, HoleJump.opening(duration: TakeControlBeats.diveDuration)),
                (body, HoleJump.figure(
                    HumanControlBeats.exit,
                    of      : body,
                    duration: TakeControlBeats.diveDuration
                )),
            ] {
                animation.beginTime = start
                target.add(
                    animation,
                    forKey: Self.diveKey
                )
            }
        }
        CATransaction.commit()
    }

    /// Comes back as control ends: pops up out of the hole, the companion's entrance, its cast
    /// shadow and bubble fading in as it lands; under Reduce Motion it fades in.
    func comeBack() {
        guard isAway, let layer else { return }
        isAway = false
        dives += 1
        settleDive()
        let run  = dives
        let calm = HouseMotion.reducesMotion
        let now  = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { if self?.dives == run { self?.settleDive() } }
        }
        for view in [bubble, cast, portrait] {
            view.isHidden = false
            view.layer?.removeAnimation(forKey: Self.diveKey)
        }
        for view in calm ? [bubble, cast, portrait] : [bubble, cast] {
            let fade            = CABasicAnimation(keyPath: "opacity")
            fade.fromValue      = 0
            fade.toValue        = 1
            fade.beginTime      = now + (calm ? 0 : TakeControlBeats.diveDuration * 0.8)
            fade.duration       = 0.25
            fade.fillMode       = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer?.add(
                fade,
                forKey: "comeBack"
            )
        }
        if !calm, let body = portrait.layer {
            layer.mask = HoleJump.groundMask(
                hole: hole.position,
                size: Self.holeSize,
                in  : bounds
            )
            hole.add(
                HoleJump.opening(duration: TakeControlBeats.diveDuration),
                forKey: Self.diveKey
            )
            body.add(
                HoleJump.figure(
                    HumanControlBeats.entrance,
                    of      : body,
                    duration: TakeControlBeats.diveDuration
                ),
                forKey: Self.diveKey
            )
        }
        CATransaction.commit()
        pointerMoved()
    }

    /// The dive played: the worker stays hidden, its jump taken off the layers.
    private func landedAway(_ run: Int) {
        guard run == dives, isAway else { return }
        for view in [bubble, cast, portrait] {
            view.isHidden = true
            view.layer?.removeAnimation(forKey: Self.diveKey)
        }
        settleDive()
    }

    private func settleDive() {
        hole.removeAnimation(forKey: Self.diveKey)
        portrait.layer?.removeAnimation(forKey: Self.diveKey)
        layer?.mask = nil
    }

    /// Fades `view` out from `time`, holding until the dive lands.
    private static func fadeOut(
        _ view  : NSView,
        at time : CFTimeInterval,
        duration: CFTimeInterval
    ) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue   = 0
        fade.beginTime = time
        view.layer?.add(
            HoleJump.held(
                fade,
                duration: duration
            ),
            forKey: diveKey
        )
    }

    private static let diveKey = "presence.dive"

    // MARK: Light

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        for name in Self.watched {
            NotificationCenter.default.removeObserver(
                self,
                name  : name,
                object: window
            )
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        guard let window else {
            resample?.cancel()
            backdrop.stop()
            return
        }
        for name in Self.watched {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowChanged),
                name    : name,
                object  : window
            )
        }
        sampleSoon()
    }

    @objc private func windowChanged() {
        sampleSoon()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Samples what lies behind the worker once the panel has rested where it is, while it is on
    /// screen; a moving or hidden panel samples nothing. Only the panel itself is left out of the
    /// capture: the screen window under half of the worker counts.
    private func sampleSoon() {
        backdrop.stop()
        resample?.cancel()
        guard let window, window.occlusionState.contains(.visible) else { return }

        resample = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let window = self.window, let screen = window.screen else { return }
            backdrop.start(
                region   : window.convertToScreen(convert(
                    portrait.frame,
                    to: nil
                )),
                on       : screen,
                excluding: window.windowNumber
            )
        }
    }

    // MARK: Pointer

    /// Only a bubble that says something takes a click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isSaying, !isAway, let superview else { return nil }
        return balloon.contains(convert(point, from: superview)) ? self : nil
    }

    /// The bubble's balloon in this view, empty while it is closed.
    var balloon: CGRect {
        bubble.balloonFrame.isEmpty ? .zero : convert(bubble.balloonFrame, from: bubble)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard balloon.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isSaying else { return false }
        open()
        return true
    }

    override func mouseEntered(with event: NSEvent) { pointerMoved() }
    override func mouseMoved(with event: NSEvent) { pointerMoved() }
    override func mouseExited(with event: NSEvent) { hover(false) }

    /// The pointer over the worker or its bubble makes both see-through; over a bubble that says
    /// something, it is the hand of a link. The panel never becomes key, so no cursor rect would show.
    private func pointerMoved() {
        guard let window else { return }
        let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if isSaying, balloon.contains(pointer) { NSCursor.pointingHand.set() }
        hover(portrait.frame.contains(pointer) || balloon.contains(pointer))
    }

    private func hover(_ hovered: Bool) {
        guard hovered != isHovered, let layer else { return }
        if !hovered { NSCursor.arrow.set() }
        isHovered = hovered
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue      = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue        = hovered ? Self.hoveredOpacity : 1
        fade.duration       = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.opacity = hovered ? Self.hoveredOpacity : 1
        layer.add(
            fade,
            forKey: "hover"
        )
    }

    /// Opens the conversation, and closes the bubble that asked for it.
    private func open() {
        guard case .saying(let line)? = bubble.speech else { return }
        dismissed = line
        show(
            worker: worker,
            speech: nil
        )
        onOpen?()
    }

    /// What VoiceOver reads: the worker and what it says; a button while it says something.
    private func describe() {
        let said: String?
        switch bubble.speech {
        case .thinking?        : said = "thinking"
        case .acting(let line)?: said = line
        case .saying(let line)?: said = "says “\(line)”"
        case nil               : said = nil
        }
        setAccessibilityRole(isSaying ? .button : .staticText)
        setAccessibilityLabel([worker.name, said].compactMap { $0 }.joined(separator: ", "))
        setAccessibilityHelp(isSaying ? "Opens the conversation in Braus" : nil)
    }
}
