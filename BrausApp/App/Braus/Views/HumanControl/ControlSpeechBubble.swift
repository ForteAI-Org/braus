//
//  ControlSpeechBubble.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit
import QuartzCore

/// ControlSpeechBubble is the worker's speech balloon asking whether the person is done with the app
/// Braus holds: a rounded rectangle with continuous corners in the mascot's graphite, a fine lighter
/// rim and a soft shadow, three small round bubbles trailing to the worker, "Are you done?" in rounded
/// semibold type, and the Yes and No capsules under it. With a countdown it also says when Braus takes
/// the app back, over a thin bar that empties.
///
/// It covers the whole stage and takes clicks only on its buttons. It opens on a gentle spring from
/// the point the trail leaves it (`HumanControlLayout.balloonAnchor`, `BalloonSpring`), the trail
/// following and the buttons sliding in just after, and closes the same way, quicker. Under Reduce
/// Motion it fades; under Reduce Transparency the balloon is opaque.
final class ControlSpeechBubble: NSView {

    /// The person's answer: true for Yes.
    var onAnswer: ((Bool) -> Void)?

    /// The pointer over an answer: true over Yes, false over No, nil over neither.
    var onHover: ((Bool?) -> Void)?

    /// The balloon in the stage, which the buttons sit under.
    let balloonFrame: CGRect

    private let balloon  = CALayer()
    private let card     = CALayer()
    private let question = CATextLayer()
    private let line     = CATextLayer()
    private let track    = CAShapeLayer()
    private let bar      = CAShapeLayer()
    private let trail    : [CAShapeLayer]
    private let yes      : CapsuleButton
    private let no       : CapsuleButton

    /// The countdown's seconds in all, for the bar.
    private let seconds: Int?

    /// A bubble over a stage of `stage` size, with a countdown of `seconds` and its first `line`, or
    /// the plain question; `opaque` under Reduce Transparency.
    init(
        stage    : CGSize,
        countdown: (line: String, seconds: Int)?,
        opaque   : Bool
    ) {
        seconds = countdown?.seconds
        let shape   = HumanControlLayout.balloonFrame(height: countdown == nil
            ? HumanControlLayout.questionHeight
            : HumanControlLayout.countdownHeight)
        balloonFrame = shape
        let buttons = HumanControlLayout.buttonFrames(under: shape)
        let bubbles = HumanControlLayout.trail(from: shape)
        trail = bubbles.map { _ in CAShapeLayer() }
        yes   = CapsuleButton(
            frame     : buttons.yes,
            title     : "I'm done",
            emphasised: true
        )
        no    = CapsuleButton(
            frame     : buttons.no,
            title     : "No",
            emphasised: false
        )
        super.init(frame: CGRect(origin: .zero, size: stage))
        wantsLayer = true

        let fill = Self.fill(opaque: opaque)
        for (layer, bubble) in zip(trail, bubbles) {
            Self.dress(
                trail: layer,
                at   : bubble,
                fill : fill
            )
            self.layer?.addSublayer(layer)
        }

        balloon.anchorPoint = HumanControlLayout.balloonAnchor
        balloon.frame       = shape
        card.frame          = balloon.bounds
        Self.dress(
            card  : card,
            corner: HumanControlLayout.balloonCorner,
            fill  : fill
        )
        balloon.addSublayer(card)

        // Whole-point frames keep the type on the pixel grid at every backing scale.
        let inset: CGFloat = 14
        Self.style(
            question,
            text  : "Are you done?",
            size  : 14,
            color : Self.enamel
        )
        question.frame = CGRect(
            x     : inset,
            y     : countdown == nil ? ((shape.height - 18) / 2).rounded() : shape.height - 10 - 18,
            width : shape.width - 2 * inset,
            height: 18
        )
        balloon.addSublayer(question)

        if let countdown {
            Self.style(
                line,
                text  : countdown.line,
                size  : 11,
                color : Self.enamel.copy(alpha: 0.62) ?? Self.enamel
            )
            line.frame = CGRect(
                x     : inset,
                y     : 15,
                width : shape.width - 2 * inset,
                height: 14
            )
            balloon.addSublayer(line)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: inset, y: 9))
            path.addLine(to: CGPoint(x: shape.width - inset, y: 9))
            for (layer, color) in [(track, Self.enamel.copy(alpha: 0.12)), (bar, Self.enamel.copy(alpha: 0.85))] {
                layer.frame       = balloon.bounds
                layer.path        = path
                layer.strokeColor = color
                layer.lineWidth   = 2
                layer.lineCap     = .round
                balloon.addSublayer(layer)
            }
        }
        layer?.addSublayer(balloon)

        for button in [no, yes] {
            button.onPress = { [weak self] in self?.onAnswer?(button === self?.yes) }
            button.onHover = { [weak self] entered in self?.hover(button, entered: entered) }
            addSubview(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(["Are you done?", countdown?.line].compactMap { $0 }.joined(separator: " "))
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The button the pointer is over: entering one and leaving the other may come in either order.
    private weak var hovered: CapsuleButton?

    private func hover(
        _ button: CapsuleButton,
        entered : Bool
    ) {
        if entered {
            hovered = button
            onHover?(button === yes)
        } else if hovered === button {
            hovered = nil
            onHover?(nil)
        }
    }

    /// Only the buttons take clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchScale()
    }

    private func matchScale() {
        let scale = window?.backingScaleFactor ?? 2
        for layer in [balloon, card, question, line, track, bar] + trail {
            layer.contentsScale = scale
        }
    }

    /// Shows the countdown's line and empties the bar to `remaining` seconds left: in one smooth
    /// sweep to nothing on the first call, or a step a second under Reduce Motion.
    func count(
        line text    : String,
        remaining    : Int,
        reducesMotion: Bool
    ) {
        guard let seconds, seconds > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.string = text
        setAccessibilityLabel("Are you done? \(text)")
        let share = CGFloat(remaining) / CGFloat(seconds)
        if reducesMotion {
            bar.strokeEnd = share
        } else if bar.animation(forKey: Self.sweepKey) == nil {
            bar.strokeEnd = 0
            let sweep = CABasicAnimation(keyPath: "strokeEnd")
            sweep.fromValue      = share
            sweep.toValue        = 0
            sweep.duration       = Double(remaining)
            sweep.timingFunction = CAMediaTimingFunction(name: .linear)
            bar.add(sweep, forKey: Self.sweepKey)
        }
        CATransaction.commit()
    }

    /// Opens the bubble: the balloon on a gentle spring from its anchor as it fades in, the trail
    /// following toward the worker, then the buttons sliding up; or under Reduce Motion a fade.
    func appear(reducesMotion: Bool) {
        guard let layer else { return }
        guard !reducesMotion else {
            layer.add(Self.fade(from: 0, to: 1, duration: 0.2, begin: 0), forKey: "appear")
            return
        }
        Self.playOpening(
            balloon: balloon,
            trail  : trail,
            now    : layer.convertTime(CACurrentMediaTime(), from: nil)
        )
        for (index, button) in [no, yes].enumerated() {
            button.slideIn(after: 0.14 + Double(index) * 0.03)
        }
    }

    /// Closes the bubble, the opening played backwards and quicker, and takes it off its superview.
    func disappear() {
        onAnswer = nil
        onHover  = nil
        let reduces = HouseMotion.reducesMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.removeFromSuperview() }
        }
        CATransaction.setDisableActions(true)
        if reduces {
            layer?.opacity = 0
            layer?.add(Self.fade(from: 1, to: 0, duration: 0.12, begin: 0), forKey: "disappear")
        } else {
            Self.playClosing(
                balloon: balloon,
                parts  : [balloon] + trail + [no.layer, yes.layer].compactMap { $0 }
            )
        }
        CATransaction.commit()
    }

    private static let sweepKey = "countdown.sweep"

    // MARK: Shared with the screen window's bubble

    /// The balloon's graphite, a touch translucent, or opaque under Reduce Transparency.
    static func fill(opaque: Bool) -> CGColor {
        graphite.copy(alpha: opaque ? 1 : 0.96) ?? graphite
    }

    /// Dresses `card` as the balloon over its bounds as they are: `fill`, continuous corners of
    /// `corner`, the fine rim, and the soft `shadow` along its outline.
    static func dress(
        card  : CALayer,
        corner: CGFloat,
        fill  : CGColor,
        shadow: (radius: CGFloat, offset: CGFloat) = HumanControlLayout.balloonShadow
    ) {
        card.backgroundColor = fill
        card.cornerRadius    = corner
        card.cornerCurve     = .continuous
        card.borderWidth     = 0.75
        card.borderColor     = rim
        card.shadowColor     = CGColor(gray: 0, alpha: 1)
        card.shadowOpacity   = 0.35
        card.shadowRadius    = shadow.radius
        card.shadowOffset    = CGSize(width: 0, height: shadow.offset)
        card.shadowPath      = outline(
            of    : card.bounds,
            corner: corner
        )
    }

    /// The balloon's outline over `bounds`, which its shadow follows.
    static func outline(
        of bounds: CGRect,
        corner   : CGFloat
    ) -> CGPath {
        CGPath(
            roundedRect : bounds,
            cornerWidth : corner,
            cornerHeight: corner,
            transform   : nil
        )
    }

    /// Dresses `layer` as one bubble of the trail, at `bubble`, in the balloon's `fill` and rim.
    static func dress(
        trail layer: CAShapeLayer,
        at bubble  : HumanControlLayout.TrailBubble,
        fill       : CGColor
    ) {
        layer.bounds      = CGRect(
            x     : 0,
            y     : 0,
            width : 2 * bubble.radius,
            height: 2 * bubble.radius
        )
        layer.position    = bubble.centre
        layer.path        = CGPath(ellipseIn: layer.bounds.insetBy(dx: 0.375, dy: 0.375), transform: nil)
        layer.fillColor   = fill
        layer.strokeColor = rim
        layer.lineWidth   = 0.75
    }

    /// Opens `balloon` on a gentle spring from its anchor as it fades in, `now` on its clock, the
    /// `trail` growing in after it one bubble at a time toward the worker.
    static func playOpening(
        balloon: CALayer,
        trail  : [CALayer],
        now    : CFTimeInterval
    ) {
        let spring = BalloonSpring.opening
        let open   = CASpringAnimation(keyPath: "transform.scale")
        open.fromValue = spring.from
        open.toValue   = 1
        open.stiffness = spring.stiffness
        open.damping   = spring.damping
        open.duration  = open.settlingDuration
        balloon.add(open, forKey: "appear.scale")
        balloon.add(fade(from: 0, to: 1, duration: 0.16, begin: now), forKey: "appear.fade")

        for (index, bubble) in trail.enumerated() {
            let begin = now + 0.06 + Double(index) * 0.05
            let grow  = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue      = 0.3
            grow.toValue        = 1
            grow.duration       = 0.2
            grow.beginTime      = begin
            grow.fillMode       = .backwards
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            bubble.add(grow, forKey: "appear.scale")
            bubble.add(fade(from: 0, to: 1, duration: 0.16, begin: begin), forKey: "appear.fade")
        }
    }

    /// Fades `parts` out, leaving them hidden, and shrinks `balloon` a little as they go, in the
    /// caller's transaction.
    static func playClosing(
        balloon: CALayer,
        parts  : [CALayer]
    ) {
        for part in parts {
            part.opacity = 0
            part.add(fade(from: 1, to: 0, duration: 0.12, begin: 0), forKey: "disappear.fade")
        }
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue      = 1
        shrink.toValue        = 0.85
        shrink.duration       = 0.14
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        balloon.add(shrink, forKey: "disappear.scale")
    }

    /// An opacity change over `duration` from `begin` on the layer's clock, or now when it is 0,
    /// showing `from` before it starts.
    static func fade(
        from    : Float,
        to      : Float,
        duration: Double,
        begin   : CFTimeInterval
    ) -> CAAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue      = from
        fade.toValue        = to
        fade.duration       = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if begin > 0 {
            fade.beginTime = begin
            fade.fillMode  = .backwards
        }
        return fade
    }

    private static func style(
        _ layer: CATextLayer,
        text   : String,
        size   : CGFloat,
        color  : CGColor
    ) {
        layer.string          = text
        layer.font            = rounded(size: size)
        layer.fontSize        = size
        layer.foregroundColor = color
        layer.alignmentMode   = .left
        layer.truncationMode  = .end
    }

    /// SF Pro Rounded, semibold.
    static func rounded(size: CGFloat) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
    }

    /// The mascot's graphite (`MascotLayer`'s base), the balloon's fine rim, and the brows' white enamel.
    static let graphite = CGColor(srgbRed: 0x2D / 255.0, green: 0x2D / 255.0, blue: 0x32 / 255.0, alpha: 1)
    static let rim      = CGColor(gray: 1, alpha: 0.16)
    static let enamel   = CGColor(srgbRed: 0.96, green: 0.96, blue: 0.95, alpha: 1)
}

/// CapsuleButton is a capsule the person answers the balloon with: filled with white enamel and
/// graphite type for the emphasised one, a quiet translucent fill with a fine rim for the other. It
/// brightens smoothly under the pointer and dims and shrinks a little while pressed, answers the first
/// click without activating Braus, and VoiceOver presses it as a button.
final class CapsuleButton: NSView {

    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let body       = CALayer()
    private let label      = CATextLayer()
    private let emphasised : Bool
    private var isHovered  = false
    private var isPressed  = false

    init(
        frame     : CGRect,
        title     : String,
        emphasised: Bool
    ) {
        self.emphasised = emphasised
        super.init(frame: frame)
        wantsLayer = true
        body.bounds       = bounds
        body.position     = CGPoint(x: bounds.midX, y: bounds.midY)
        body.cornerRadius = bounds.height / 2
        body.cornerCurve  = .continuous
        body.borderWidth  = emphasised ? 0 : 0.75
        body.borderColor  = ControlSpeechBubble.rim
        label.string          = title
        label.font            = ControlSpeechBubble.rounded(size: 12)
        label.fontSize        = 12
        label.foregroundColor = emphasised ? ControlSpeechBubble.graphite : ControlSpeechBubble.enamel
        label.alignmentMode   = .center
        label.frame           = CGRect(
            x     : 0,
            y     : ((bounds.height - 15) / 2).rounded(),
            width : bounds.width,
            height: 15
        )
        body.addSublayer(label)
        layer?.addSublayer(body)
        paint()

        addTrackingArea(NSTrackingArea(
            rect    : .zero,
            options : [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner   : self,
            userInfo: nil
        ))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        matchScale()
    }

    private func matchScale() {
        for layer in [body, label] {
            layer.contentsScale = window?.backingScaleFactor ?? 2
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        paint()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        paint()
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        paint()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        paint()
        if inside { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    /// Fades in and slides up into place after `delay`, hidden before.
    func slideIn(after delay: Double) {
        guard let layer else { return }
        let begin = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue      = -HumanControlLayout.buttonSlide
        slide.toValue        = 0
        slide.duration       = 0.22
        slide.beginTime      = begin
        slide.fillMode       = .backwards
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        body.add(slide, forKey: "appear.slide")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue   = 1
        fade.duration  = 0.18
        fade.beginTime = begin
        fade.fillMode  = .backwards
        body.add(fade, forKey: "appear.fade")
    }

    /// The fill the pointer and the press ask, eased over a moment: brighter hovered, dimmer and a
    /// little smaller pressed. Under Reduce Motion the size holds.
    private func paint() {
        let fill: CGColor = emphasised
            ? CGColor(gray: isHovered ? 1 : 0.93, alpha: 1)
            : CGColor(gray: 1, alpha: isHovered ? 0.16 : 0.08)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        body.backgroundColor = fill
        body.opacity         = isPressed ? 0.8 : 1
        if !HouseMotion.reducesMotion {
            body.setValue(isPressed ? 0.96 : 1, forKeyPath: "transform.scale")
        }
        CATransaction.commit()
    }
}
