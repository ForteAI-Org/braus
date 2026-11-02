//
//  CompanionHalo.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit
import QuartzCore

/// CompanionHalo is the soft halo behind the worker of `HumanControlOverlay` while the pointer is over
/// it: what lies behind is blurred by the system's material (`NSVisualEffectView` blending behind the
/// window) within a wide ellipse, whole around the worker and beside it, whose edge then fades away,
/// under a tone of the backdrop's light (`BackdropSampler`), so the worker stands clear of a busy
/// screen while the halo blends with it instead of standing out as a card or a glow.
///
/// It lives in a panel of its own, a child of the overlay's ordered below it, that ignores the mouse:
/// the clicks it covers reach the worker or the app below as before. The panel is on screen only while
/// the halo shows or fades, so at rest nothing of it runs. It springs open as it fades in and shrinks a
/// little as it fades out; under Reduce Motion it only fades.
final class CompanionHalo {

    private let panel = HumanControlPanel.make(ignoresMouse: true)
    private let glass = NSView()
    private let blur  = NSVisualEffectView()
    private let tone  = NSView()
    private let edge  = CAGradientLayer()

    /// Whether the halo is asked to show, and the number of the last change: a hidden halo's late
    /// fade must not take a shown one off the screen.
    private var isShown = false
    private var changes = 0

    init() {
        blur.material     = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state        = .active
        blur.appearance   = NSAppearance(named: .darkAqua)
        tone.wantsLayer   = true
        tone.layer?.backgroundColor = CGColor(
            gray : 1,
            alpha: 0.1
        )

        // Whole over the worker and its sides, then fading to nothing at the ellipse's edge: no card
        // ever shows.
        edge.type       = .radial
        edge.startPoint = CGPoint(x: 0.5, y: 0.5)
        edge.endPoint   = CGPoint(x: 1, y: 1)
        edge.colors     = [1, 1, 0.85, 0.45, 0.14, 0].map {
            CGColor(
                gray : 1,
                alpha: $0
            )
        }
        edge.locations  = [0, 0.52, 0.68, 0.81, 0.92, 1]

        glass.wantsLayer  = true
        glass.layer?.mask = edge
        glass.addSubview(blur)
        glass.addSubview(tone)
        // A mask on the content view's own layer hides the whole window; inside it, it fades the edge.
        let content = NSView()
        content.addSubview(glass)
        panel.contentView = content
    }

    /// Shows the halo over `frame`, in AppKit's screen space, behind `parent`: it fades and springs in.
    /// The part past the edge of `parent`'s screen is cut, so none shows on a screen beside it.
    func show(
        in frame: CGRect,
        behind parent: NSWindow
    ) {
        guard !isShown else { return }
        isShown  = true
        changes += 1
        let appearing = panel.parent == nil
        if appearing {
            let shown = parent.screen.map { frame.intersection($0.frame) } ?? frame
            panel.setFrame(
                shown.isEmpty ? frame : shown,
                display: false
            )
            let bounds = CGRect(origin: .zero, size: frame.size)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // The ellipse keeps its whole size and place; the panel only cuts it.
            glass.frame        = bounds.offsetBy(
                dx: frame.minX - panel.frame.minX,
                dy: frame.minY - panel.frame.minY
            )
            blur.frame         = bounds
            tone.frame         = bounds
            edge.frame         = bounds
            edge.contentsScale = parent.backingScaleFactor
            CATransaction.commit()
            parent.addChildWindow(
                panel,
                ordered: .below
            )
        }
        animate(
            shown    : true,
            appearing: appearing
        )
    }

    /// Fades the halo out and takes its panel off the screen once it has.
    func hide() {
        guard isShown else { return }
        isShown  = false
        changes += 1
        let number = changes
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, number == self.changes else { return }
                self.detach()
            }
        }
        animate(
            shown    : false,
            appearing: false
        )
        CATransaction.commit()
    }

    /// Takes the halo off the screen at once.
    func remove() {
        isShown  = false
        changes += 1
        glass.layer?.removeAllAnimations()
        detach()
    }

    /// Tones the blur with the backdrop's `light`, lifting it from the dark worker, fainter on a dark
    /// backdrop.
    func tint(_ light: SIMD4<Float>) {
        tone.layer?.backgroundColor = CGColor(
            srgbRed: CGFloat(light.x),
            green  : CGFloat(light.y),
            blue   : CGFloat(light.z),
            alpha  : 0.07 + 0.25 * CGFloat(light.w)
        )
    }

    private func detach() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Moves the glass from where it is now, or from its rest when `appearing`, to shown or hidden.
    private func animate(
        shown    : Bool,
        appearing: Bool
    ) {
        guard let layer = glass.layer else { return }
        let reduces = HouseMotion.reducesMotion
        let rest    = reduces ? CATransform3DIdentity : shrunk(layer)
        let current = layer.presentation() ?? layer
        let from    = (
            opacity  : appearing ? 0 : current.opacity,
            transform: appearing ? rest : current.transform
        )
        let to      = shown ? CATransform3DIdentity : rest
        layer.removeAnimation(forKey: Self.fadeKey)
        layer.removeAnimation(forKey: Self.scaleKey)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity   = shown ? 1 : 0
        layer.transform = to
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue      = from.opacity
        fade.toValue        = layer.opacity
        fade.duration       = shown ? 0.22 : 0.18
        fade.timingFunction = CAMediaTimingFunction(name: shown ? .easeOut : .easeIn)
        layer.add(fade, forKey: Self.fadeKey)
        guard !reduces else { return }

        let scale: CABasicAnimation
        if shown {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.damping   = 18
            spring.stiffness = 280
            spring.duration  = spring.settlingDuration
            scale = spring
        } else {
            scale = CABasicAnimation(keyPath: "transform")
            scale.duration       = 0.18
            scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        scale.fromValue = from.transform
        scale.toValue   = to
        layer.add(scale, forKey: Self.scaleKey)
    }

    /// The glass scaled down to `restScale` about its centre.
    private func shrunk(_ layer: CALayer) -> CATransform3D {
        let scale = Self.restScale
        let size  = layer.bounds.size
        // The layer scales about its anchor; the shift keeps the ellipse's centre where it is.
        let shift = CGPoint(
            x: (1 - scale) * size.width * (0.5 - layer.anchorPoint.x),
            y: (1 - scale) * size.height * (0.5 - layer.anchorPoint.y)
        )
        return CATransform3DScale(
            CATransform3DMakeTranslation(
                shift.x,
                shift.y,
                0
            ),
            scale,
            scale,
            1
        )
    }

    private static let restScale: CGFloat = 0.86
    private static let fadeKey            = "halo.fade"
    private static let scaleKey           = "halo.scale"
}
