//
//  HouseChevronView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit

/// HouseChevronView is the chevron of a folding inspector section: a layer that points right while
/// the section is folded and turns a quarter turn clockwise to point down as it opens, in Core Animation.
///
/// Under Reduce Motion the chevron is set at once, with no animation.
final class HouseChevronView: NSView {

    /// The animation key of the turn, which a test looks for on `glyph`.
    static let turnKey = "turn"

    /// How long the turn takes; the section's rows fold over the same time.
    static let duration: CFTimeInterval = 0.25

    /// The chevron's layer: two strokes that meet in a point.
    let glyph = CAShapeLayer()

    private(set) var isOpen = false

    /// Whether the chevron is lit, as under the pointer.
    var isEmphasized = false {
        didSet { applyTone() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(glyph)
        let path = CGMutablePath()
        path.move(to: CGPoint(
            x: 4.5,
            y: 2
        ))
        path.addLine(to: CGPoint(
            x: 8,
            y: 6
        ))
        path.addLine(to: CGPoint(
            x: 4.5,
            y: 10
        ))
        glyph.path        = path
        glyph.fillColor   = nil
        glyph.lineWidth   = 1.8
        glyph.lineCap     = .round
        glyph.lineJoin    = .round
        applyTone()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 12) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.bounds   = CGRect(
            x     : 0,
            y     : 0,
            width : 12,
            height: 12
        )
        glyph.position = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTone()
    }

    /// Points the chevron right when folded and down when open, turning it unless `animated` is false.
    func setOpen(
        _ isOpen: Bool,
        animated: Bool
    ) {
        guard isOpen != self.isOpen else { return }

        let from = glyph.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat
            ?? Self.angle(isOpen: self.isOpen)
        self.isOpen = isOpen
        let to = Self.angle(isOpen: isOpen)
        glyph.removeAnimation(forKey: Self.turnKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.setValue(
            to,
            forKeyPath: "transform.rotation.z"
        )
        CATransaction.commit()
        guard animated else { return }

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue      = from
        turn.toValue        = to
        turn.duration       = Self.duration
        turn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glyph.add(
            turn,
            forKey: Self.turnKey
        )
    }

    private static func angle(isOpen: Bool) -> CGFloat { isOpen ? -.pi / 2 : 0 }

    private func applyTone() {
        let color = isEmphasized ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glyph.strokeColor = color.cgColor
        }
    }
}
