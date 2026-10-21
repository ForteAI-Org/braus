//
//  HeroLight.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HeroLight is the soft presentation light under the worker at the top of its conversation: a
/// wide, faint radial glow of warm white that takes a share of the status light's colour (amber
/// busy, green free, blue waiting) and a dim moonlight when the worker is off.
///
/// It is a single Core Animation gradient with no hard edge: a colour change cross-fades, and the
/// light breathes by a layer animation, so nothing renders at rest. Under Reduce Motion a change
/// is a cut and the light holds still.
struct HeroLight: NSViewRepresentable {
    let status: WorkerStatus

    /// The light's colour and opacity at its centre for a status.
    static func tone(for status: WorkerStatus) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        guard let light = status.light else {
            return (red: 0.62, green: 0.70, blue: 0.84, alpha: 0.10)
        }
        let share = 0.5
        return (
            red  : 1.00 + (light.red - 1.00) * share,
            green: 0.95 + (light.green - 0.95) * share,
            blue : 0.86 + (light.blue - 0.86) * share,
            alpha: 0.12 + 0.06 * status.lightStrength
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
            CATransaction.setAnimationDuration(1.2)
            glow.colors = [
                color,
                color.copy(alpha: tone.alpha * 0.4) as Any,
                color.copy(alpha: 0) as Any,
            ]
            CATransaction.commit()
            breathe()
        }

        private func breathe() {
            glow.removeAnimation(forKey: "breathe")
            guard !RestylingMotion.reducesMotion else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue      = 1
            pulse.toValue        = 0.78
            pulse.duration       = 3.4
            pulse.autoreverses   = true
            pulse.repeatCount    = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(
                pulse,
                forKey: "breathe"
            )
        }
    }
}
