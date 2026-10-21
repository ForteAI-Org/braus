//
//  MascotFace.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// MascotFace shows a worker's mascot around the sphere's square of `size` points: a `MascotLayer`
/// in the worker's shape, breathing, whose brows morph whenever `brows` changes. In a room,
/// `catchesRoomLight` lets the brows take a faint tint of the room's light, pulsing with it.
///
/// A body the face draws itself can reach past that square (`ShapeOutline.halfSize`), so the view
/// takes room for it in layout, centred on the square; brows alone take only the square. In a tilted
/// room `projectedFace` places the brows where the room's camera shows the body's face.
struct MascotFace: NSViewRepresentable {
    let shape           : WorkerShape
    let status          : WorkerStatus
    let brows           : BrowState
    let size            : CGFloat
    var drawsBody       : Bool = true
    var catchesRoomLight: Bool = false
    var projectedFace   : RoomCamera.Face?

    /// Changing it makes the head prepare once (`MascotLayer.prepare()`); its first value does not.
    var preparation     : Int = 0

    /// The worker's seed (`WorkerBehaviour.seed(for:)`): with one, the brows play the status's
    /// behaviour (`MascotLayer.behave(seed:)`) and `brows` should be the status's own expression.
    var behaviourSeed   : UInt64?

    /// In a room, joins the brows to the room's renderer, so the body moves in step with them and
    /// they follow it.
    var bodyLink        : RoomBodyLink?

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: CGRect(
            origin: .zero,
            size  : footprint
        ))
        configure(
            view,
            animated: false
        )
        view.mascot.startBreathing()
        return view
    }

    func updateNSView(
        _ view : HostView,
        context: Context
    ) {
        configure(
            view,
            animated: true
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView    : HostView,
        context   : Context
    ) -> CGSize? {
        footprint
    }

    /// The room the face takes: the sphere's square, grown to hold the body it draws.
    private var footprint: CGSize {
        let reach = drawsBody ? shape.outline.halfSize : (width: 1, height: 1)
        return CGSize(
            width : size * max(1, reach.width),
            height: size * max(1, reach.height)
        )
    }

    private func configure(
        _ view  : HostView,
        animated: Bool
    ) {
        view.sphereSize = size
        let mascot = view.mascot
        mascot.shape         = shape
        mascot.status        = status
        mascot.drawsBody     = drawsBody
        mascot.projectedFace = projectedFace
        mascot.show(
            brows,
            animated: animated
        )
        mascot.catchRoomLight(catchesRoomLight)
        mascot.behave(seed: behaviourSeed)
        bodyLink?.browsDidBehave(mascot)
        if view.preparation != preparation {
            view.preparation = preparation
            if animated { mascot.prepare() }
        }
    }

    /// HostView holds the mascot layer, the sphere's square centred in the view.
    final class HostView: NSView {
        let mascot = MascotLayer()

        /// The last preparation the head played.
        var preparation = 0

        /// The side of the sphere's square, in points.
        var sphereSize: CGFloat = 0 {
            didSet { placeMascot() }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            mascot.frame = bounds
            layer?.addSublayer(mascot)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            matchBackingScale()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            matchBackingScale()
        }

        private func matchBackingScale() {
            mascot.contentsScale = window?.backingScaleFactor ?? 2
        }

        override func layout() {
            super.layout()
            placeMascot()
        }

        private func placeMascot() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mascot.frame = CGRect(
                x     : bounds.midX - sphereSize / 2,
                y     : bounds.midY - sphereSize / 2,
                width : sphereSize,
                height: sphereSize
            )
            CATransaction.commit()
        }
    }
}
