//
//  ThinkingBlobView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import AppKit

/// ThinkingBlobView is the "is responding" indicator of a thinking bubble: a
/// small accent ball whose edge carries six soft lobes that breathe and turn
/// slowly, while the whole ball swells and fades gently.
///
/// One `CAShapeLayer` carries everything. Its path is animated through a few
/// precomputed blob shapes that share one control-point count, and its scale,
/// opacity and rotation are animated with Core Animation, so the render server
/// plays them and the main thread draws nothing per frame.
///
/// The animations run only while the view is in a window that is on screen and
/// shown, and are removed otherwise. Reduce Motion leaves a slow opacity pulse;
/// with Reduce Transparency too the ball is still, and Reduce Transparency alone
/// keeps the motion but never fades. It takes no clicks and is no accessibility
/// element: the row that holds it speaks for it. Main actor only.
@MainActor
final class ThinkingBlobView: NSView {

    /// The accessibility settings the animation honours.
    struct Accessibility: Equatable {
        var reducesMotion      : Bool
        var reducesTransparency: Bool

        static var system: Accessibility {
            Accessibility(
                reducesMotion      : NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                reducesTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            )
        }
    }

    private static let anchors      = 24
    private static let keyframes    = 12
    private static let lobes        = 6
    private static let morphSeconds = 4.0
    private static let spinSeconds  = 14.0
    private static let scaleLow     = 0.9
    private static let opacityLow   = 0.6
    private static let fadeSeconds  = 0.9
    private static let pathKey      = "blob.path"
    private static let scaleKey     = "blob.scale"
    private static let fadeKey      = "blob.fade"
    private static let spinKey      = "blob.spin"

    /// The settings the view follows; the system's unless a caller overrides them.
    var accessibility = Accessibility.system {
        didSet { if accessibility != oldValue { refresh(restarting: true) } }
    }

    /// Where a change of the display options reads the new settings; tests replace it.
    var systemAccessibility: () -> Accessibility = { .system }

    /// The ball's colour, resolved in the view's own appearance.
    private let tint = NSColor.controlAccentColor

    private let blob = CAShapeLayer()
    private var isRunning   = false
    private var laidOutSize = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(blob)
        updateFill()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blob.frame = bounds
        CATransaction.commit()
        refresh(restarting: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center    = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        center.removeObserver(self)
        workspace.removeObserver(self)
        if let window {
            center.addObserver(
                self,
                selector: #selector(visibilityChanged),
                name    : NSWindow.didChangeOcclusionStateNotification,
                object  : window
            )
            center.addObserver(
                self,
                selector: #selector(systemColorsChanged),
                name    : NSColor.systemColorsDidChangeNotification,
                object  : nil
            )
            // NSWorkspace posts the display options on its own centre, not the default one.
            workspace.addObserver(
                self,
                selector: #selector(displayOptionsChanged),
                name    : NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object  : nil
            )
        }
        refresh(restarting: false)
    }

    override func viewDidHide() {
        super.viewDidHide()
        refresh(restarting: false)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh(restarting: false)
    }

    @objc private func visibilityChanged(_ note: Notification) {
        refresh(restarting: false)
    }

    @objc private func displayOptionsChanged(_ note: Notification) {
        accessibility = systemAccessibility()
    }

    @objc private func systemColorsChanged(_ note: Notification) {
        updateFill()
    }

    private func updateFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            blob.fillColor = tint.cgColor
        }
        CATransaction.commit()
    }

    // MARK: Shape

    /// The radius change at `angle` for a loop position `phase` in [0, 1): lobes
    /// whose size breathes once per loop, so the last keyframe equals the first.
    private static func offset(angle: CGFloat, phase: CGFloat) -> CGFloat {
        (0.06 + 0.02 * cos(2 * .pi * phase)) * cos(CGFloat(lobes) * angle)
    }

    /// The largest relative radius over the loop, so the ball can be sized to fit.
    private static let reach: CGFloat = {
        var largest: CGFloat = 1
        for step in 0..<keyframes {
            for index in 0..<(anchors * 2) {
                let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(anchors * 2)
                largest = max(largest, 1 + offset(angle: angle, phase: CGFloat(step) / CGFloat(keyframes)))
            }
        }
        return largest * 1.02
    }()

    /// The path of the ball at loop position `phase`, fitted so no lobe leaves the bounds.
    private func shape(at phase: CGFloat) -> CGPath {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 / Self.reach
        let points = (0..<Self.anchors).map { index -> CGPoint in
            let angle  = 2 * CGFloat.pi * CGFloat(index) / CGFloat(Self.anchors)
            let length = radius * (1 + Self.offset(angle: angle, phase: phase))
            return CGPoint(x: center.x + length * cos(angle), y: center.y + length * sin(angle))
        }
        // A closed Catmull-Rom spline as cubic curves: every shape has the same elements.
        let path = CGMutablePath()
        path.move(to: points[0])
        for index in points.indices {
            let before = points[(index + points.count - 1) % points.count]
            let from   = points[index]
            let to     = points[(index + 1) % points.count]
            let after  = points[(index + 2) % points.count]
            path.addCurve(
                to      : to,
                control1: CGPoint(x: from.x + (to.x - before.x) / 6, y: from.y + (to.y - before.y) / 6),
                control2: CGPoint(x: to.x - (after.x - from.x) / 6, y: to.y - (after.y - from.y) / 6)
            )
        }
        path.closeSubpath()
        return path
    }

    // MARK: Animation

    /// Whether the animations should be playing now.
    private var isVisible: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor, !bounds.isEmpty else { return false }
        return window.occlusionState.contains(.visible)
    }

    private func refresh(restarting: Bool) {
        let shouldRun = isVisible
        guard restarting || shouldRun != isRunning else { return }
        stop()
        guard !bounds.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blob.path = shape(at: 0)
        CATransaction.commit()
        if shouldRun {
            start()
        }
    }

    private func start() {
        isRunning = true
        let motion = !accessibility.reducesMotion

        if motion {
            let morph = CAKeyframeAnimation(keyPath: "path")
            morph.values = (0...Self.keyframes).map {
                shape(at: CGFloat($0 % Self.keyframes) / CGFloat(Self.keyframes))
            }
            morph.calculationMode = .cubic
            morph.duration        = Self.morphSeconds
            morph.repeatCount     = .infinity
            blob.add(morph, forKey: Self.pathKey)

            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue    = 1
            spring.toValue      = Self.scaleLow
            spring.mass         = 1
            spring.stiffness    = 36
            spring.damping      = 6.5
            spring.duration     = spring.settlingDuration
            spring.autoreverses = true
            spring.repeatCount  = .infinity
            blob.add(spring, forKey: Self.scaleKey)

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue   = 0
            spin.toValue     = -2 * Double.pi
            spin.duration    = Self.spinSeconds
            spin.repeatCount = .infinity
            blob.add(spin, forKey: Self.spinKey)
        }

        // Reduce Motion keeps only a slow fade; Reduce Transparency never fades.
        guard !accessibility.reducesTransparency else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue      = 1
        fade.toValue        = Self.opacityLow
        fade.duration       = motion ? Self.fadeSeconds : 1.6
        fade.autoreverses   = true
        fade.repeatCount    = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        blob.add(fade, forKey: Self.fadeKey)
    }

    private func stop() {
        isRunning = false
        blob.removeAllAnimations()
    }
}
