//
//  MascotFace.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// MascotFace shows a worker's mascot in the sphere's square of `size` points: a `MascotLayer` in
/// the worker's shape, breathing, whose brows morph whenever `brows` changes. In a room,
/// `catchesRoomLight` lets the brows take a faint tint of the room's light, pulsing with it.
struct MascotFace: NSViewRepresentable {
    let shape           : WorkerShape
    let status          : WorkerStatus
    let brows           : BrowState
    let size            : CGFloat
    var drawsBody       : Bool = true
    var catchesRoomLight: Bool = false

    func makeNSView(context: Context) -> HostView {
        let view = HostView(frame: CGRect(
            x     : 0,
            y     : 0,
            width : size,
            height: size
        ))
        configure(
            view.mascot,
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
            view.mascot,
            animated: true
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView    : HostView,
        context   : Context
    ) -> CGSize? {
        CGSize(
            width : size,
            height: size
        )
    }

    private func configure(
        _ mascot: MascotLayer,
        animated: Bool
    ) {
        mascot.shape     = shape
        mascot.status    = status
        mascot.drawsBody = drawsBody
        mascot.show(
            brows,
            animated: animated
        )
        mascot.catchRoomLight(catchesRoomLight)
    }

    /// HostView holds the mascot layer and keeps it the size of the view.
    final class HostView: NSView {
        let mascot = MascotLayer()

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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mascot.frame = bounds
            CATransaction.commit()
        }
    }
}
