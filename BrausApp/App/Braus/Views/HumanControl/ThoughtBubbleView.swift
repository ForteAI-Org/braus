//
//  ThoughtBubbleView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit
import QuartzCore

/// ThoughtBubbleView draws what the companion thinks while it ponders, over its head: three small
/// circles and a small cloud in the balloon's graphite, with three dots inside. `sync(loop:start:)`
/// plays `ThoughtBubble`'s keyframes on the loop's own clock, repeating with it, so nothing runs but
/// Core Animation. It covers the stage and never takes a click.
final class ThoughtBubbleView: NSView {

    private let circles = HumanControlLayout.thoughtCircles.map { _ in CAShapeLayer() }
    private let cloud   = CALayer()
    private let dots    = (0..<3).map { _ in CAShapeLayer() }

    /// The loop and its start the keyframes follow, so an unchanged loop is left playing.
    private var synced: (loop: WorkerBehaviourLoop, start: CFTimeInterval)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let fill = ControlSpeechBubble.graphite.copy(alpha: 0.96) ?? ControlSpeechBubble.graphite
        for (layer, bubble) in zip(circles, HumanControlLayout.thoughtCircles) {
            layer.bounds      = CGRect(
                x     : 0,
                y     : 0,
                width : 2 * bubble.radius,
                height: 2 * bubble.radius
            )
            layer.position    = bubble.centre
            layer.path        = CGPath(ellipseIn: layer.bounds, transform: nil)
            layer.fillColor   = fill
            layer.strokeColor = ControlSpeechBubble.rim
            layer.lineWidth   = 0.75
            self.layer?.addSublayer(layer)
        }
        cloud.frame           = HumanControlLayout.thoughtCloud
        cloud.backgroundColor = fill
        cloud.cornerRadius    = cloud.bounds.height / 2
        cloud.cornerCurve     = .continuous
        cloud.borderWidth     = 0.75
        cloud.borderColor     = ControlSpeechBubble.rim
        Self.place(
            dots,
            centredIn: cloud.bounds
        )
        for dot in dots {
            cloud.addSublayer(dot)
        }
        layer?.addSublayer(cloud)
        for part in parts.map(\.layer) {
            part.opacity = 0
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for part in parts.map(\.layer) {
            part.contentsScale = window?.backingScaleFactor ?? 2
        }
    }

    /// Every layer with the part of the bubble it is.
    private var parts: [(layer: CALayer, part: ThoughtBubble.Part)] {
        circles.enumerated().map { ($1, .circle($0)) }
            + [(cloud, .cloud)]
            + dots.enumerated().map { ($1, .dot($0)) }
    }

    /// Plays the thought bubble over `loop`, which started at `start` on the host clock, or nothing
    /// without a loop or a ponder in it. Under Reduce Motion it only fades.
    func sync(
        loop : WorkerBehaviourLoop?,
        start: CFTimeInterval
    ) {
        if let synced, synced.loop == loop, synced.start == start { return }
        synced = loop.map { ($0, start) }
        let windows = loop.map(ThoughtBubble.windows) ?? []
        let rises   = !HouseMotion.reducesMotion
        for (layer, part) in parts {
            layer.removeAnimation(forKey: Self.key)
            guard let loop, !windows.isEmpty else { continue }
            let keys   = ThoughtBubble.keys(
                of      : part,
                windows : windows,
                duration: loop.duration,
                rises   : rises
            )
            var tracks: [(String, [Double])] = [("opacity", keys.map(\.opacity))]
            if rises {
                tracks.append(("transform.translation.y", keys.map(\.rise)))
                if part == .cloud { tracks.append(("transform.scale", keys.map { 0.75 + 0.25 * $0.opacity })) }
            }
            let group = CAAnimationGroup()
            group.animations  = tracks.map { keyPath, values in
                let track = CAKeyframeAnimation(keyPath: keyPath)
                track.values   = values
                track.keyTimes = keys.map { NSNumber(value: $0.time / loop.duration) }
                return track
            }
            group.duration    = loop.duration
            group.repeatCount = .infinity
            group.beginTime   = layer.convertTime(start, from: nil)
            layer.add(group, forKey: Self.key)
        }
    }

    private static let key = "thought"

    // MARK: Shared with the screen window's bubble

    /// Lays the three `dots` side by side in the middle of `bounds`, in white enamel.
    static func place(
        _ dots          : [CAShapeLayer],
        centredIn bounds: CGRect
    ) {
        for (index, dot) in dots.enumerated() {
            let side: CGFloat = 3.5
            dot.frame     = CGRect(
                x     : bounds.midX - side / 2 + CGFloat(index - 1) * 7,
                y     : bounds.midY - side / 2,
                width : side,
                height: side
            )
            dot.path      = CGPath(ellipseIn: dot.bounds, transform: nil)
            dot.fillColor = ControlSpeechBubble.enamel
        }
    }

    /// Pulses `dots` in turn for as long as they keep the animation, on the thought bubble's own
    /// rhythm (`ThoughtBubble.pulse`), from `now` on their clock.
    static func pulse(
        _ dots  : [CAShapeLayer],
        from now: CFTimeInterval
    ) {
        let pulse = ThoughtBubble.pulse
        for (index, dot) in dots.enumerated() {
            let beat = CAKeyframeAnimation(keyPath: "opacity")
            beat.values      = [pulse.dim, 1, pulse.dim, pulse.dim]
            beat.keyTimes    = [0, pulse.rise, 2 * pulse.rise, pulse.period].map { NSNumber(value: $0 / pulse.period) }
            beat.duration    = pulse.period
            beat.beginTime   = now + pulse.lead * Double(index)
            beat.fillMode    = .backwards
            beat.repeatCount = .infinity
            dot.add(
                beat,
                forKey: key
            )
        }
    }
}
