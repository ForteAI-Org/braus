//
//  EnlargedScreenHostView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import AppKit
import QuartzCore

/// EnlargedScreenHostView is the overlay that shows a worker's screen large: a
/// dimmed backdrop and the live view, grown from the small one it was opened
/// from and shrunk back into the one it closes into.
///
/// It covers the whole window's content, so the screen can travel to and from
/// the inspector, which a view of the conversation alone would clip.
///
/// Every motion is a Core Animation animation on a layer's model values
/// (`CASpringAnimation` on position, size and corner radius, `CABasicAnimation`
/// on the backdrop), so the render server runs it and the main thread does no
/// work per frame. With `reducesMotion` the screen does not travel: the whole
/// overlay fades. The live view carries no shadow, which the compositor would
/// work out again on every frame of the live picture.
///
/// The screen it holds is a second layer on the capture the small one already
/// shows, never a second capture. It is seeded with the small one's last frame
/// so a still window does not open black, and hands its own last frame to the
/// small one it lands in, which the stream does not draw into while hidden.
///
/// While it is in a window it owns the keyboard: Escape and a click on the
/// backdrop close it, and Tab goes nowhere else. It shows no close button; the
/// accessibility action "Close Screen" lets VoiceOver close it. It gives the
/// keyboard back to what had it when it goes.
final class EnlargedScreenHostView: NSView {

    private static let margin      : CGFloat       = 28
    private static let smallRadius : CGFloat       = 8
    private static let largeRadius : CGFloat       = 12
    private static let fadeDuration: CFTimeInterval = 0.2

    /// The backdrop's black: light enough to keep the window behind readable.
    private static let backdropAlpha: CGFloat = 0.45

    /// A spring that settles with a little overshoot, its duration the time it takes to rest.
    private static func spring(
        _ keyPath: String,
        from     : Any,
        to       : Any
    ) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = from
        spring.toValue   = to
        spring.mass      = 1
        spring.stiffness = 320
        spring.damping   = 30
        spring.duration  = spring.settlingDuration
        return spring
    }

    private let screen        : NSView
    private let backdrop      = CALayer()
    private let onRequestClose: () -> Void

    /// The small view the grow starts from, held until the first layout has a size to grow to.
    private weak var opener: NSView?

    /// What the window's first responder was, given back when the overlay goes.
    private weak var previousResponder: NSResponder?

    /// Whether the person asked for less motion; read when an animation starts.
    var reducesMotion: Bool

    private var hasOpened = false
    private var isClosing = false

    /// The seat window's size in points, zero while it is not measured: the screen keeps
    /// its proportions and never grows past it.
    var nativeSize: CGSize {
        didSet { if nativeSize != oldValue { needsLayout = true } }
    }

    /// The width of the small view it grows from, which the enlarged screen never goes below.
    private let minimumWidth: CGFloat

    /// The top edge the screen keeps clear: how far the title bar and toolbar reach into this view.
    private(set) var topInset: CGFloat = 0

    init(
        screen        : NSView,
        nativeSize    : CGSize,
        opener        : NSView?,
        reducesMotion : Bool,
        label         : String,
        onRequestClose: @escaping () -> Void
    ) {
        self.screen         = screen
        self.nativeSize     = nativeSize
        self.opener         = opener
        self.minimumWidth   = opener?.bounds.width ?? 0
        self.reducesMotion  = reducesMotion
        self.onRequestClose = onRequestClose
        super.init(frame: .zero)

        wantsLayer = true
        backdrop.backgroundColor = CGColor(gray: 0, alpha: Self.backdropAlpha)
        layer?.addSublayer(backdrop)

        screen.wantsLayer = true
        addSubview(screen)
        screen.layer?.cornerRadius  = Self.largeRadius
        screen.layer?.cornerCurve   = .continuous
        screen.layer?.masksToBounds = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
        setAccessibilityHelp("Press Escape to close.")
        setAccessibilityModal(true)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close Screen") { [weak self] in
                self?.requestClose()
                return true
            }
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("EnlargedScreenHostView is code-only") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Layout

    override func layout() {
        super.layout()

        topInset = window.map {
            max(0, bounds.maxY - convert(
                $0.contentLayoutRect,
                from: nil
            ).maxY)
        } ?? 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        if !isClosing { screen.frame = restFrame }
        CATransaction.commit()

        if !hasOpened, window != nil, bounds.width > 0 { open() }
    }

    /// The screen's place while enlarged: the seat's proportions, centered, inside the margins,
    /// at most the window's own size so a small window is not upscaled, never below the card.
    private var restFrame: CGRect {
        let room = CGRect(
            x     : Self.margin,
            y     : Self.margin,
            width : bounds.width - 2 * Self.margin,
            height: bounds.height - topInset - 2 * Self.margin
        )
        guard room.width > 0, room.height > 0 else { return room }

        let isMeasured = nativeSize.width > 0 && nativeSize.height > 0
        let ratio      = isMeasured ? nativeSize.width / nativeSize.height : 16.0 / 10.0
        // The card's size is a floor, the room a ceiling: a tall seat in a low window still fits.
        let fit        = min(
            room.width,
            room.height * ratio
        )
        let width      = min(
            fit,
            max(
                minimumWidth,
                isMeasured ? nativeSize.width : fit
            )
        )
        let height     = width / ratio
        return CGRect(
            x     : room.midX - width / 2,
            y     : room.midY - height / 2,
            width : width,
            height: height
        )
    }

    // MARK: Opening

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // A removal without a close, a worker chosen or a seat released, still gives the keyboard back.
        if newWindow == nil, !isClosing, let window, window.firstResponder === self {
            window.makeFirstResponder(previousResponder)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else { return }

        previousResponder = window.firstResponder
        window.makeFirstResponder(self)
        NSAccessibility.post(
            element     : window,
            notification: .announcementRequested,
            userInfo    : [
                .announcement: "\(accessibilityLabel() ?? "Screen") enlarged. Press Escape to close.",
                .priority    : NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
        needsLayout = true
    }

    /// Grows the screen from the small view it was opened from.
    private func open() {
        hasOpened = true
        let target = restFrame
        screen.frame = target
        let origin = convertedFrame(of: opener) ?? target
        Self.copyFrame(
            from: opener,
            to  : screen
        )

        guard !reducesMotion else {
            fade(
                from: 0,
                to  : 1
            )
            return
        }
        travel(
            from      : origin,
            to        : target,
            radiusFrom: Self.smallRadius,
            radiusTo  : Self.largeRadius
        )
        animateBackdrop(
            from: 0,
            to  : 1
        )
    }

    // MARK: Closing

    /// Shrinks the screen into the small view it closes into, then calls `finished`; a repeat is ignored.
    func close(
        into small: NSView?,
        finished  : @escaping () -> Void
    ) {
        guard !isClosing else { return }

        isClosing = true
        window?.makeFirstResponder(previousResponder)
        // The small view was paused while hidden, so it takes the newest frame before it shows again.
        let landed = { [screen, weak small] in
            Self.copyFrame(
                from: screen,
                to  : small
            )
            finished()
        }

        guard !reducesMotion, let landing = convertedFrame(of: small) else {
            fade(
                from    : 1,
                to      : 0,
                finished: landed
            )
            return
        }
        let from = presentationFrame
        CATransaction.begin()
        CATransaction.setCompletionBlock(landed)
        screen.layer?.removeAllAnimations()
        CATransaction.setDisableActions(true)
        screen.frame               = landing
        screen.layer?.cornerRadius = Self.smallRadius
        CATransaction.setDisableActions(false)
        travel(
            from      : from,
            to        : landing,
            radiusFrom: Self.largeRadius,
            radiusTo  : Self.smallRadius
        )
        animateBackdrop(
            from: backdrop.presentation()?.opacity ?? 1,
            to  : 0
        )
        CATransaction.commit()
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(
            event.locationInWindow,
            from: nil
        )
        if !screen.frame.contains(point) { requestClose() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
            case 53: requestClose()
            // Any other key, Tab included, is dropped: the overlay is the only stop.
            default: break
        }
    }

    override func cancelOperation(_ sender: Any?) { requestClose() }

    private func requestClose() {
        guard !isClosing else { return }
        onRequestClose()
    }

    // MARK: Animation

    /// Moves the screen's layer between two frames; the model values are already the end.
    private func travel(
        from      : CGRect,
        to        : CGRect,
        radiusFrom: CGFloat,
        radiusTo  : CGFloat
    ) {
        guard let layer = screen.layer else { return }

        // A frame's position is its anchor point, which AppKit puts at the origin of a view's layer.
        func position(of rect: CGRect) -> CGPoint {
            CGPoint(
                x: rect.minX + layer.anchorPoint.x * rect.width,
                y: rect.minY + layer.anchorPoint.y * rect.height
            )
        }
        layer.add(
            Self.spring(
                "position",
                from: position(of: from),
                to  : position(of: to)
            ),
            forKey: "position"
        )
        layer.add(
            Self.spring(
                "bounds.size",
                from: from.size,
                to  : to.size
            ),
            forKey: "size"
        )
        layer.add(
            Self.spring(
                "cornerRadius",
                from: radiusFrom,
                to  : radiusTo
            ),
            forKey: "radius"
        )
    }

    private func animateBackdrop(
        from: Float,
        to  : Float
    ) {
        backdrop.opacity = to
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue      = from
        fade.toValue        = to
        fade.duration       = Self.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        backdrop.add(
            fade,
            forKey: "opacity"
        )
    }

    /// Fades the whole overlay, the Reduce Motion form of both the grow and the shrink.
    private func fade(
        from    : Float,
        to      : Float,
        finished: (() -> Void)? = nil
    ) {
        guard let layer else {
            finished?()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(finished)
        layer.opacity = to
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue      = from
        fade.toValue        = to
        fade.duration       = 0.15
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(
            fade,
            forKey: "fade"
        )
        CATransaction.commit()
    }

    // MARK: Geometry

    /// Where a view in another part of the window is, in this view's coordinates; nil while it is not in this window.
    private func convertedFrame(of view: NSView?) -> CGRect? {
        guard let view, view.window != nil, view.window === window, view.bounds.width > 0 else { return nil }

        return convert(
            view.convert(
                view.bounds,
                to: nil
            ),
            from: nil
        )
    }

    /// The screen's frame as it is drawn now, which a shrink that interrupts a grow starts from.
    private var presentationFrame: CGRect {
        guard let shown = screen.layer?.presentation() else { return screen.frame }

        return CGRect(
            x     : shown.position.x - shown.anchorPoint.x * shown.bounds.width,
            y     : shown.position.y - shown.anchorPoint.y * shown.bounds.height,
            width : shown.bounds.width,
            height: shown.bounds.height
        )
    }

    /// Copies one live view's last frame into another, so a still window never shows black or old.
    private static func copyFrame(
        from source: NSView?,
        to target  : NSView?
    ) {
        guard let source = source?.layer, let layer = target?.layer else { return }

        layer.contents     = source.contents
        layer.contentsRect = source.contentsRect
    }
}
