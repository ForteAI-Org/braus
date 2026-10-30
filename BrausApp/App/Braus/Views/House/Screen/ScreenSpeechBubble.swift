//
//  ScreenSpeechBubble.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit
import QuartzCore

/// ScreenSpeechBubble is what the worker says beside its mascot in its screen window (`WorkerSpeech`):
/// the companion's speech balloon (`ControlSpeechBubble`) at a window corner's size, one line tall,
/// with its trail of bubbles leading right to the worker's face. Thinking, it is a small pill with the
/// thought bubble's three dots pulsing in turn (`ThoughtBubbleView`); acting or saying, one line in
/// the balloon's rounded type, cut short with an ellipsis.
///
/// Its right side stays where the trail leaves it and it grows leftwards. It opens on the balloon's
/// spring and closes the same way, quicker; a change of what it says springs its width and
/// cross-fades its words, and the dots pulse only while it thinks. Under Reduce Motion every change
/// fades and the dots hold still; under Reduce Transparency the balloon is opaque. It takes no click:
/// `ScreenPresenceView` answers the one on a balloon that says something.
final class ScreenSpeechBubble: NSView {

    /// What it says now; nil while it is closed.
    private(set) var speech: WorkerSpeech?

    /// The balloon in the view as it stands once its spring has settled; empty while closed.
    private(set) var balloonFrame = CGRect.zero

    private let balloon = CALayer()
    private let content = CALayer()
    private let words   = CATextLayer()
    private let thought = CALayer()
    private let dots    = (0..<3).map { _ in CAShapeLayer() }
    private let trail   = ScreenSpeechBubble.trail.map { _ in CAShapeLayer() }

    /// The view's size: the widest balloon with its trail, and room for its shadow and its spring.
    static let size = CGSize(
        width : 270,
        height: 46
    )

    /// The balloon's height, corner, the room beside its words, and its narrowest and widest: the
    /// thinking pill, and as long a line as the window's corner spares.
    static let height  : CGFloat = 26
    static let corner  : CGFloat = 13
    static let inset   : CGFloat = 11
    static let thinking: CGFloat = 44
    static let widest  : CGFloat = 220

    /// The room between the balloon and the face that the trail crosses.
    static let trailRoom: CGFloat = 18

    /// The balloon's softer shadow, at its smaller size.
    static let shadow = (radius: CGFloat(5), offset: CGFloat(-2))

    /// The balloon's foot, a little above the view's middle, so its anchor is level with the face.
    static let balloonY = ((size.height - height) / 2 + 3).rounded()

    /// Where the worker's face is, at the view's right edge.
    static let face = CGPoint(
        x: size.width,
        y: size.height / 2 - 3
    )

    /// The trail from the balloon's anchor to just short of the face, the companion's bubbles at
    /// this balloon's size.
    static let trail: [HumanControlLayout.TrailBubble] = {
        let start = CGPoint(
            x: size.width - trailRoom,
            y: balloonY + HumanControlLayout.balloonAnchor.y * height
        )
        let end   = CGPoint(
            x: face.x - 2,
            y: face.y
        )
        return zip([0.26, 0.58, 0.86] as [CGFloat], [3.2, 2.3, 1.6] as [CGFloat]).map { step, radius in
            HumanControlLayout.TrailBubble(
                centre: CGPoint(
                    x: start.x + (end.x - start.x) * step,
                    y: start.y + (end.y - start.y) * step
                ),
                radius: radius
            )
        }
    }()

    /// The balloon's width for `speech`: the pill while thinking, otherwise its line's.
    static func width(of speech: WorkerSpeech) -> CGFloat {
        guard let line = line(of: speech) else { return thinking }

        let measured = NSAttributedString(
            string    : line,
            attributes: [.font: ControlSpeechBubble.rounded(size: 12)]
        ).size().width
        return min(widest, max(thinking, (measured + 2 * inset).rounded(.up)))
    }

    /// The line `speech` says, nil while it thinks.
    static func line(of speech: WorkerSpeech) -> String? {
        switch speech {
        case .thinking                         : nil
        case .acting(let line), .saying(let line): line
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let fill = ControlSpeechBubble.fill(opaque: HouseMotion.reducesTransparency)
        for (layer, bubble) in zip(trail, Self.trail) {
            ControlSpeechBubble.dress(
                trail: layer,
                at   : bubble,
                fill : fill
            )
            self.layer?.addSublayer(layer)
        }
        balloon.anchorPoint = HumanControlLayout.balloonAnchor
        balloon.bounds      = CGRect(
            x     : 0,
            y     : 0,
            width : Self.thinking,
            height: Self.height
        )
        ControlSpeechBubble.dress(
            card  : balloon,
            corner: Self.corner,
            fill  : fill,
            shadow: Self.shadow
        )
        words.font            = ControlSpeechBubble.rounded(size: 12)
        words.fontSize        = 12
        words.foregroundColor = ControlSpeechBubble.enamel
        words.alignmentMode   = .left
        words.truncationMode  = .end
        // The words and the dots sit in a layer that keeps the balloon's shape, so neither shows
        // past it while it springs.
        content.anchorPoint   = .zero
        content.frame         = balloon.bounds
        content.cornerRadius  = Self.corner
        content.cornerCurve   = .continuous
        content.masksToBounds = true
        thought.frame         = balloon.bounds
        ThoughtBubbleView.place(
            dots,
            centredIn: thought.bounds
        )
        for dot in dots {
            thought.addSublayer(dot)
        }
        content.addSublayer(thought)
        content.addSublayer(words)
        balloon.addSublayer(content)
        layer?.addSublayer(balloon)
        for part in [balloon] + trail {
            part.opacity = 0
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [balloon, content, words, thought] + dots + trail {
            layer.contentsScale = scale
        }
    }

    /// Says `speech`: opens the balloon with it, changes what the open one says, or closes it on nil.
    func show(_ speech: WorkerSpeech?) {
        guard speech != self.speech else { return }
        let said    = self.speech
        let reduces = HouseMotion.reducesMotion
        self.speech = speech
        guard let speech else {
            close(reducesMotion: reduces)
            return
        }

        let width = Self.width(of: speech)
        let shown = balloon.presentation()?.bounds ?? balloon.bounds
        let size  = CGSize(
            width : width,
            height: Self.height
        )
        balloonFrame = CGRect(
            origin: CGPoint(
                x: Self.size.width - Self.trailRoom - width,
                y: Self.balloonY
            ),
            size  : size
        )
        let line = Self.line(of: speech)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        balloon.bounds     = CGRect(
            origin: .zero,
            size  : size
        )
        content.bounds     = balloon.bounds
        balloon.position   = CGPoint(
            x: balloonFrame.maxX,
            y: balloonFrame.minY + HumanControlLayout.balloonAnchor.y * Self.height
        )
        balloon.shadowPath = ControlSpeechBubble.outline(
            of    : balloon.bounds,
            corner: Self.corner
        )
        // Whole-point frames keep the type on the pixel grid at every backing scale.
        words.frame        = CGRect(
            x     : Self.inset,
            y     : ((Self.height - 15) / 2).rounded(),
            width : width - 2 * Self.inset,
            height: 15
        )
        if let said {
            change(
                from         : shown,
                said         : Self.line(of: said),
                to           : line,
                reducesMotion: reduces
            )
        }
        words.string    = line
        words.opacity   = line == nil ? 0 : 1
        thought.opacity = line == nil ? 1 : 0
        if said == nil { open(reducesMotion: reduces) }
        pulse(line == nil && !reduces)
        CATransaction.commit()
    }

    /// Opens the balloon on its spring, the trail following, or fades it in under Reduce Motion.
    private func open(reducesMotion: Bool) {
        let parts = [balloon] + trail
        for part in parts {
            part.removeAnimation(forKey: "disappear.fade")
            part.opacity = 1
        }
        balloon.removeAnimation(forKey: "disappear.scale")
        guard !reducesMotion else {
            for part in parts {
                part.add(
                    ControlSpeechBubble.fade(
                        from    : 0,
                        to      : 1,
                        duration: 0.2,
                        begin   : 0
                    ),
                    forKey: "appear.fade"
                )
            }
            return
        }
        ControlSpeechBubble.playOpening(
            balloon: balloon,
            trail  : trail,
            now    : balloon.convertTime(
                CACurrentMediaTime(),
                from: nil
            )
        )
    }

    /// Springs the open balloon from the width it shows to its new one, and cross-fades what it
    /// `said` to what it says `to` now, nil for the dots; under Reduce Motion the width cuts and the
    /// words only fade. In the caller's transaction.
    private func change(
        from shown   : CGRect,
        said         : String?,
        to line      : String?,
        reducesMotion: Bool
    ) {
        if !reducesMotion, shown.width != balloon.bounds.width {
            let spring = BalloonSpring.opening
            let tracks: [(CALayer, String, Any, Any)] = [
                (balloon, "bounds", NSValue(rect: shown), NSValue(rect: balloon.bounds)),
                (content, "bounds", NSValue(rect: shown), NSValue(rect: content.bounds)),
                (
                    balloon,
                    "shadowPath",
                    ControlSpeechBubble.outline(
                        of    : shown,
                        corner: Self.corner
                    ),
                    balloon.shadowPath as Any
                ),
            ]
            for (layer, keyPath, from, to) in tracks {
                let grow = CASpringAnimation(keyPath: keyPath)
                grow.fromValue = from
                grow.toValue   = to
                grow.stiffness = spring.stiffness
                grow.damping   = spring.damping
                grow.duration  = grow.settlingDuration
                layer.add(
                    grow,
                    forKey: "change." + keyPath
                )
            }
        }
        if said != nil, line != nil {
            let fade = CATransition()
            fade.type     = .fade
            fade.duration = 0.18
            words.add(
                fade,
                forKey: "change.words"
            )
        } else if (said == nil) != (line == nil) {
            // From the dots to words or back: one fades out as the other fades in.
            let shows: Float = line == nil ? 0 : 1
            words.add(
                ControlSpeechBubble.fade(
                    from    : 1 - shows,
                    to      : shows,
                    duration: 0.18,
                    begin   : 0
                ),
                forKey: "change.fade"
            )
            thought.add(
                ControlSpeechBubble.fade(
                    from    : shows,
                    to      : 1 - shows,
                    duration: 0.18,
                    begin   : 0
                ),
                forKey: "change.fade"
            )
        }
    }

    /// Closes the balloon the way the companion's closes, or fades it out under Reduce Motion.
    private func close(reducesMotion: Bool) {
        balloonFrame = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulse(false)
        if reducesMotion {
            for part in [balloon] + trail {
                part.opacity = 0
                part.add(
                    ControlSpeechBubble.fade(
                        from    : 1,
                        to      : 0,
                        duration: 0.12,
                        begin   : 0
                    ),
                    forKey: "disappear.fade"
                )
            }
        } else {
            ControlSpeechBubble.playClosing(
                balloon: balloon,
                parts  : [balloon] + trail
            )
        }
        CATransaction.commit()
    }

    /// Pulses the dots while `on`; off, takes the pulse away, so nothing runs while the bubble rests.
    private func pulse(_ on: Bool) {
        let pulsing = dots.first?.animationKeys()?.isEmpty == false
        guard on != pulsing else { return }
        if on {
            ThoughtBubbleView.pulse(
                dots,
                from: thought.convertTime(
                    CACurrentMediaTime(),
                    from: nil
                )
            )
        } else {
            for dot in dots {
                dot.removeAllAnimations()
            }
        }
    }
}
