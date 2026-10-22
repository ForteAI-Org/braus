//
//  WordReveal.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import CoreImage

/// WordReveal plays a reply's words arriving over its row: each word fades in
/// from transparent, blurred and a little low to itself, over `wordDuration`, each one
/// `HouseTiming.wordStagger` after the one before, as the hero's `WordFade`
/// does. Core Animation plays it, one layer per word cut from a picture of the row's text, so the
/// main thread draws nothing per frame. It takes no clicks and is no accessibility element: the
/// row under it speaks for its text. Main actor only.
@MainActor
final class WordReveal: NSView {

    /// How long one word takes to arrive.
    static let wordDuration = 0.35

    /// The longest a whole reveal takes past its first word: a long reply's words come closer together.
    static let spread = 1.2

    /// The most words one reveal plays; a longer arrival shows at once.
    // ponytail: a fixed cap, as a layer per word costs; stream the words in batches if long replies should fade too.
    static let wordLimit = 300

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.isGeometryFlipped = true
        layer                     = root
        wantsLayer                = true
        layerUsesCoreImageFilters = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The gap between two words' starts for `count` words.
    static func stagger(of count: Int) -> Double {
        min(HouseTiming.wordStagger, spread / Double(max(1, count)))
    }

    /// Plays `words`, frames in the row, cut from `picture`, the row's text drawn at the row's size,
    /// and calls `completion` once the last is in.
    func play(
        _ words   : [CGRect],
        in picture: CGImage,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let root = layer, bounds.width > 0 else { return completion() }

        let scale   = CGFloat(picture.width) / bounds.width
        let stagger = Self.stagger(of: words.count)
        let now     = root.convertTime(CACurrentMediaTime(), from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { completion() }
        }
        for (index, word) in words.enumerated() {
            // Room around the word for its blur.
            let frame = word.insetBy(dx: -3, dy: -3).integral
            let pixels = CGRect(
                x     : frame.minX * scale,
                y     : frame.minY * scale,
                width : frame.width * scale,
                height: frame.height * scale
            ).integral
            guard let cut = picture.cropping(to: pixels) else { continue }

            let layer = CALayer()
            layer.frame           = frame
            layer.contents        = cut
            layer.contentsGravity = .resize
            layer.contentsScale   = scale
            if let blur = CIFilter(name: "CIGaussianBlur") {
                blur.name = "blur"
                blur.setValue(0, forKey: kCIInputRadiusKey)
                layer.filters = [blur]
            }
            root.addSublayer(layer)
            let group = CAAnimationGroup()
            group.animations = [
                Self.animation("opacity", from: 0, to: 1),
                Self.animation("transform.translation.y", from: 3, to: 0),
                Self.animation("filters.blur.inputRadius", from: 4, to: 0),
            ]
            group.beginTime      = now + Double(index) * stagger
            group.duration       = Self.wordDuration
            group.fillMode       = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(
                group,
                forKey: "arrival"
            )
        }
        CATransaction.commit()
    }

    private static func animation(
        _ keyPath: String,
        from     : Double,
        to       : Double
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue   = to
        return animation
    }
}
