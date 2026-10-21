//
//  HeroLight.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HeroLight is the soft presentation light the worker at the top of its conversation gets from the
/// capsule that holds its name: warm white that takes a share of the status light's colour (amber
/// busy, green free, blue waiting), and a dim moonlight when the worker is off.
///
/// The light itself belongs to the worker's render: `capsuleLight(for:)` gives the room shader a soft
/// area light low in front of the worker, so it rises from the capsule onto the worker's front face.
/// This view draws only the faint glow it leaves along the capsule's top edge, a single Core Animation
/// gradient with no hard edge: a change of status cross-fades over `fade`, or cuts under Reduce
/// Motion, and nothing moves at rest.
struct HeroLight: NSViewRepresentable {
    let status: WorkerStatus

    /// How long a change of status takes to cross-fade, on the capsule and on the worker.
    static let fade = 1.2

    /// The light's colour for a status, and the glow's opacity at its centre.
    static func tone(for status: WorkerStatus) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        guard let light = status.light else {
            return (red: 0.62, green: 0.70, blue: 0.84, alpha: 0.18)
        }
        let share = 0.5
        return (
            red  : 1.00 + (light.red - 1.00) * share,
            green: 0.95 + (light.green - 0.95) * share,
            blue : 0.86 + (light.blue - 0.86) * share,
            alpha: 0.22 + 0.12 * status.lightStrength
        )
    }

    /// The light as the worker's render takes it (`RoomLightUniforms.capsuleLight`): the tone's colour
    /// at a soft strength, lower for the moonlight of a worker that is off.
    static func capsuleLight(for status: WorkerStatus) -> SIMD4<Float> {
        let tone = tone(for: status)
        return SIMD4(
            Float(tone.red),
            Float(tone.green),
            Float(tone.blue),
            status == .off ? 0.45 : 0.9
        )
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.show(
            status,
            animated: false
        )
        return view
    }

    func updateNSView(
        _ view : HostView,
        context: Context
    ) {
        view.show(
            status,
            animated: true
        )
    }

    /// HostView holds the gradient layer over its whole bounds.
    final class HostView: NSView {
        let glow = CAGradientLayer()

        private var shown: WorkerStatus?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            glow.type       = .radial
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint   = CGPoint(x: 1, y: 1)
            glow.locations  = [0, 0.4, 1]
            layer?.addSublayer(glow)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.frame = bounds
            CATransaction.commit()
        }

        /// Fades to `status`'s tone, or cuts to it under Reduce Motion or on the first show.
        func show(
            _ status: WorkerStatus,
            animated: Bool
        ) {
            guard status != shown else { return }
            shown = status
            let tone  = HeroLight.tone(for: status)
            let color = CGColor(
                srgbRed: tone.red,
                green  : tone.green,
                blue   : tone.blue,
                alpha  : tone.alpha
            )
            let fades = animated && !RestylingMotion.reducesMotion
            CATransaction.begin()
            CATransaction.setDisableActions(!fades)
            CATransaction.setAnimationDuration(HeroLight.fade)
            glow.colors = [
                color,
                color.copy(alpha: tone.alpha * 0.4) as Any,
                color.copy(alpha: 0) as Any,
            ]
            CATransaction.commit()
        }
    }
}
