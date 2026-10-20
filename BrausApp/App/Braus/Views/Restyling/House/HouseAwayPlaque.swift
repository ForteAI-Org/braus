//
//  HouseAwayPlaque.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI

/// HouseAwayPlaque is the sign hanging in an empty room while its worker is in the chat: a small
/// satin-metal plate on a cord from a nail, carrying the worker's brows and "In chat with you".
///
/// It comes down with a gentle swing about the nail when it appears, a Core Animation spring on the
/// plate's rotation that settles in about 0.8 seconds; under Reduce Motion it fades in instead. It is
/// part of the room's accessibility label, so it is hidden from VoiceOver itself.
struct HouseAwayPlaque: NSViewRepresentable {
    let brows: BrowState

    /// What the plate says, and what the room's accessibility label adds.
    static let text = "In chat with you"

    func makeNSView(context: Context) -> PlaqueView {
        PlaqueView(brows: brows)
    }

    func updateNSView(
        _ view : PlaqueView,
        context: Context
    ) {
        view.brows = brows
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView    : PlaqueView,
        context   : Context
    ) -> CGSize? {
        PlaqueView.size
    }

    /// PlaqueView draws the plaque in layers and swings it once, the first time it joins a window.
    final class PlaqueView: NSView {

        /// The worker's expression, drawn small on the plate.
        var brows: BrowState {
            didSet {
                guard brows != oldValue else { return }
                drawBrows()
            }
        }

        /// The rotation about the nail, and with it the cord and the plate.
        let swingLayer = CALayer()

        static let swingKey = "swing"
        static let fadeKey  = "fade"

        /// The plate's size, and the cord's drop from the nail to the plate's top edge.
        private static let plate = CGSize(
            width : 88,
            height: 30
        )
        private static let drop: CGFloat = 9

        /// The view's size: the plate under its cord.
        static let size = CGSize(
            width : plate.width,
            height: plate.height + drop
        )

        /// How far the plate starts turned from rest, in radians.
        private static let swingAngle = 0.32

        private static let fadeSeconds = 0.2

        private static let font = NSFont.systemFont(
            ofSize: 9,
            weight: .medium
        )

        /// The brows' and the text's colour, the design's off-white.
        private static let ink = CGColor(
            srgbRed: 245.0 / 255,
            green  : 245.0 / 255,
            blue   : 247.0 / 255,
            alpha  : 1
        )

        private let cord      = CAShapeLayer()
        private let nail      = CALayer()
        private let plateBody = CAGradientLayer()
        private let leftBrow  = CAShapeLayer()
        private let rightBrow = CAShapeLayer()
        private let label     = CATextLayer()

        private var hasHung = false

        init(brows: BrowState) {
            self.brows = brows
            super.init(frame: CGRect(
                origin: .zero,
                size  : Self.size
            ))
            wantsLayer = true
            build()
            drawBrows()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            for layer in [label, cord, leftBrow, rightBrow] as [CALayer] {
                layer.contentsScale = window.backingScaleFactor
            }
            guard !hasHung else { return }
            hasHung = true
            hang()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Turning about the nail at the top centre; the view's layer has its y axis up.
            swingLayer.bounds      = bounds
            swingLayer.anchorPoint = CGPoint(
                x: 0.5,
                y: 1
            )
            swingLayer.position = CGPoint(
                x: bounds.midX,
                y: bounds.maxY
            )
            CATransaction.commit()
        }

        /// Brings the plaque down: a swing that settles at rest, or a fade under Reduce Motion.
        func hang() {
            swingLayer.removeAnimation(forKey: Self.swingKey)
            swingLayer.removeAnimation(forKey: Self.fadeKey)
            guard !RestylingMotion.reducesMotion else {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue   = 1
                fade.duration  = Self.fadeSeconds
                swingLayer.add(
                    fade,
                    forKey: Self.fadeKey
                )
                return
            }
            let swing = CASpringAnimation(keyPath: "transform.rotation.z")
            swing.fromValue = Self.swingAngle
            swing.toValue   = 0
            swing.mass      = 1
            swing.stiffness = 320
            swing.damping   = 18
            swing.duration  = swing.settlingDuration
            swingLayer.add(
                swing,
                forKey: Self.swingKey
            )
        }

        private func build() {
            let plateTop = Self.size.height - Self.drop
            let inset: CGFloat = 16

            nail.frame = CGRect(
                x     : Self.size.width / 2 - 1.5,
                y     : Self.size.height - 3,
                width : 3,
                height: 3
            )
            nail.cornerRadius    = 1.5
            nail.backgroundColor = CGColor(
                gray : 0.62,
                alpha: 1
            )

            let path = CGMutablePath()
            path.move(to: CGPoint(
                x: inset,
                y: plateTop
            ))
            path.addLine(to: CGPoint(
                x: Self.size.width / 2,
                y: Self.size.height - 1.5
            ))
            path.addLine(to: CGPoint(
                x: Self.size.width - inset,
                y: plateTop
            ))
            cord.path        = path
            cord.fillColor   = nil
            cord.strokeColor = CGColor(
                gray : 0.5,
                alpha: 0.9
            )
            cord.lineWidth = 0.75

            // Satin metal: a soft vertical sheen, a light top edge and a hair of rim.
            plateBody.frame = CGRect(
                x     : 0,
                y     : 0,
                width : Self.plate.width,
                height: Self.plate.height
            )
            plateBody.colors = [
                CGColor(gray: 0.36, alpha: 1),
                CGColor(gray: 0.27, alpha: 1),
                CGColor(gray: 0.21, alpha: 1),
            ]
            plateBody.locations     = [0, 0.45, 1]
            plateBody.startPoint    = CGPoint(x: 0.5, y: 1)
            plateBody.endPoint      = CGPoint(x: 0.5, y: 0)
            plateBody.cornerRadius  = 7
            plateBody.cornerCurve   = .continuous
            plateBody.borderWidth   = 0.5
            plateBody.borderColor   = CGColor(gray: 1, alpha: 0.16)
            plateBody.shadowColor   = CGColor(gray: 0, alpha: 1)
            plateBody.shadowOpacity = 0.45
            plateBody.shadowRadius  = 3
            plateBody.shadowOffset  = CGSize(width: 0, height: -2)

            for brow in [leftBrow, rightBrow] {
                brow.fillColor = Self.ink
                brow.bounds    = CGRect(
                    x     : 0,
                    y     : 0,
                    width : 240,
                    height: 170
                )
            }

            label.string = NSAttributedString(
                string    : HouseAwayPlaque.text,
                attributes: [
                    .font           : Self.font,
                    .foregroundColor: NSColor(cgColor: Self.ink)?.withAlphaComponent(0.72) ?? .secondaryLabelColor,
                ]
            )
            label.alignmentMode = .center
            label.frame         = CGRect(
                x     : 0,
                y     : 5,
                width : Self.plate.width,
                height: 12
            )

            plateBody.addSublayer(leftBrow)
            plateBody.addSublayer(rightBrow)
            plateBody.addSublayer(label)
            swingLayer.addSublayer(cord)
            swingLayer.addSublayer(plateBody)
            swingLayer.addSublayer(nail)
            layer?.addSublayer(swingLayer)
        }

        /// Draws `brows` 22 points across in the plate's upper half, as `MascotLayer` places them.
        private func drawBrows() {
            let span      = 22.0
            let sideWidth = span * 0.455
            let scale     = sideWidth / 240
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (brow, points, side) in [
                (leftBrow, BrowOutlines.bundled.left[brows], -1.0),
                (rightBrow, BrowOutlines.bundled.right[brows], 1.0),
            ] {
                brow.path      = points.map(MascotLayer.path)
                brow.position  = CGPoint(
                    x: Self.plate.width / 2 + side * (span - sideWidth) / 2,
                    y: 22
                )
                brow.transform = CATransform3DMakeScale(
                    scale,
                    scale,
                    1
                )
            }
            CATransaction.commit()
        }
    }
}
