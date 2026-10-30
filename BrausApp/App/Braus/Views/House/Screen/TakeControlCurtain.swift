//
//  TakeControlCurtain.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import QuartzCore

/// TakeControlCurtain covers a worker's screen window from the click that takes control until the
/// application reaches the person's screen. The picture blurs and goes dark while a burst of mist,
/// small soft particles, drifts and swirls over it and dissipates. Then its title arrives word by
/// word, as a reply's words arrive in the transcript (`WordReveal`): "Waiting for the worker to
/// finish its step" while it does, and "You're in control" once the application starts on its way
/// (`retitle(_:)`), the old words fading first. It holds there until the application is lent
/// (`HumanPreviewControl.begin(lendingOn:)`). Released, it holds at least until its newest words are
/// in, then fades out and reports it is gone.
///
/// The blur is the system's material blending within the window, so it takes the live picture
/// behind it. The mist is one emitter layer and every movement is Core Animation. With Reduce Motion
/// there is no mist and the rest only fades. The curtain never takes a click, so the control bar
/// over it stays usable.
final class TakeControlCurtain: NSView {

    /// Called once, after `release()`, when the curtain has faded out, and as it starts to.
    var onGone  : (() -> Void)?
    var onFading: (() -> Void)?

    /// Whether it rises already dark, over a window that must not show, as when the application is
    /// handed back: no blur coming in, the mist and the words a little sooner.
    var startsDark = false

    /// The least it shows before a release fades it, in seconds.
    var minimumHold = timing.minimum

    /// When each part starts after `play()`, and how long it lasts, in seconds.
    static let timing = (
        blur     : (start: 0.0, duration: 0.35),
        shade    : (start: 0.25, duration: 0.65),
        mist     : (start: 0.15, emits: 0.95, fades: 1.2),
        words    : 0.55,
        darkWords: 0.3,
        minimum  : 0.9,
        exit     : TakeControlBeats.revealDuration
    )

    /// How dark the picture goes behind the words.
    static let shadeOpacity: CGFloat = 0.92

    /// The words' font and grey. The worker's corner already says what it is waiting for, so the
    /// words say nothing more.
    static let font = NSFont.systemFont(
        ofSize: 24,
        weight: .semibold
    )
    static let grey: CGFloat = 0.95

    /// The room kept on each side of the title.
    static let sideRoom: CGFloat = 24

    /// What it says while the worker finishes its step, and once the application is on its way.
    static let waitingTitle = "Waiting for the worker to finish its step"
    static let controlTitle = "You’re in control"

    /// How long the old words take to fade as the title changes.
    static let wordsOut: CFTimeInterval = 0.2

    /// How long `words` take to come in, the last one's arrival included.
    static func revealLength(of words: String) -> CFTimeInterval {
        let count = words.split(separator: " ").count
        return WordReveal.stagger(of: count) * Double(max(0, count - 1)) + WordReveal.wordDuration
    }

    /// From a change to `controlTitle` until the curtain released then is gone: the old words fade,
    /// the new ones come in, and the curtain fades out.
    static let lateReveal = wordsOut + revealLength(of: controlTitle) + timing.exit

    private let frost = NSVisualEffectView()
    /// Holds the frost and fades in its place: a material view given an alpha of its own stops
    /// blurring.
    private let veil  = NSView()
    private let shade = NSView()
    private let mist  = NSView()
    private let words = WordReveal()

    /// The held window's shape, the curtain's mask.
    private let shape = CALayer()

    /// The mist's emitter, turned slowly about its centre so the particles swirl.
    private let emitter = CAEmitterLayer()

    private var title: String

    private var playedAt : CFTimeInterval?

    /// When the newest words started to come in.
    private var wordsAt: CFTimeInterval?
    private var releasing = false

    /// Set by a `play()` that came before the curtain had a size.
    private var playsOnLayout = false

    /// Set by a `release()` that came before `play()`, which then releases at once.
    private var releaseAsked = false

    /// Covers the window with `title`, in the shape of `picture`, the held window, whose corners
    /// are its own: the curtain takes the picture's alpha as its mask, so it goes no further.
    init(
        title  : String,
        picture: NSView? = nil
    ) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        if let view = picture, let picture = view.layer, let contents = picture.contents {
            // The part of the surface the picture shows, counted from the top in a flipped view such
            // as the live one and from the bottom here: a capped stream fills only the top left of
            // its buffer, and the rectangle read the other way masked the curtain off its lower part.
            let shown             = picture.contentsRect
            shape.contents        = contents
            shape.contentsRect    = view.isFlipped == isFlipped ? shown : CGRect(
                x     : shown.minX,
                y     : 1 - shown.maxY,
                width : shown.width,
                height: shown.height
            )
            shape.contentsGravity = .resize
            layer?.mask           = shape
        }

        frost.material     = .fullScreenUI
        frost.blendingMode = .withinWindow
        // The screen window is rarely key: an inactive material would not blur.
        frost.state        = .active
        veil.wantsLayer    = true
        veil.alphaValue    = 0
        veil.addSubview(frost)
        shade.wantsLayer             = true
        shade.layer?.backgroundColor = .black
        shade.alphaValue             = 0

        let host             = CALayer()
        host.masksToBounds   = true
        host.addSublayer(emitter)
        mist.layer           = host
        mist.wantsLayer      = true
        emitter.birthRate    = 0
        emitter.emitterShape = .rectangle
        emitter.emitterMode  = .surface
        emitter.renderMode   = .additive
        emitter.emitterCells = Self.cells()

        for view in [veil, shade, mist, words] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        for view in [veil, shade, mist, words] {
            view.frame = bounds
        }
        frost.frame = veil.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        CATransaction.commit()
        // A square past the corners, so the field still covers the window as it turns.
        let side = hypot(
            bounds.width,
            bounds.height
        ).rounded(.up)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame           = CGRect(
            x     : bounds.midX - side / 2,
            y     : bounds.midY - side / 2,
            width : side,
            height: side
        )
        emitter.emitterPosition = CGPoint(
            x: side / 2,
            y: side / 2
        )
        emitter.emitterSize     = CGSize(
            width : side,
            height: side
        )
        CATransaction.commit()
        if playsOnLayout, window != nil, !bounds.isEmpty {
            playsOnLayout = false
            play()
        }
    }

    // MARK: Playing

    /// Blurs and darkens the picture, plays the mist and brings the words in; on its first layout
    /// with a size when it has none yet, as SwiftUI sizes it after making it.
    func play() {
        guard playedAt == nil else { return }
        layoutSubtreeIfNeeded()
        guard window != nil, !bounds.isEmpty else {
            playsOnLayout = true
            return
        }
        let now  = CACurrentMediaTime()
        let calm = HouseMotion.reducesMotion
        playedAt = now
        let timing = Self.timing

        if startsDark {
            veil.alphaValue  = 1
            shade.alphaValue = Self.shadeOpacity
        } else {
            fade(
                veil,
                to      : 1,
                at      : now + (calm ? 0 : timing.blur.start),
                duration: calm ? 0.2 : timing.blur.duration
            )
            fade(
                shade,
                to      : Self.shadeOpacity,
                at      : now + (calm ? 0 : timing.shade.start),
                duration: calm ? 0.2 : timing.shade.duration
            )
        }
        if !calm { playMist() }
        let words = calm ? 0 : startsDark ? timing.darkWords : timing.words
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(words))
            self?.revealWords()
        }

        if releaseAsked { release() }
    }

    /// Fades the curtain out once its words have been in for a moment, then calls `onGone`.
    func release() {
        guard let playedAt else {
            releaseAsked = true
            return
        }
        guard !releasing else { return }
        releasing = true
        let wordsIn = wordsAt.map { $0 + Self.revealLength(of: title) } ?? 0
        let wait    = max(0, max(playedAt + minimumHold, wordsIn) - CACurrentMediaTime())
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        onFading?()
        onFading = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.onGone?()
            self?.onGone = nil
        }
        fade(
            self,
            to      : 0,
            at      : CACurrentMediaTime(),
            duration: HouseMotion.reducesMotion ? 0.2 : Self.timing.exit
        )
        CATransaction.commit()
    }

    // MARK: Mist

    /// One burst of mist: the emitter gives particles for `emits` seconds, each fading out over its
    /// own short life, while the field turns a little about its centre; the layer fades out after,
    /// so none stays.
    private func playMist() {
        let timing = Self.timing.mist
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timing.start))
            guard let self else { return }

            let now = CACurrentMediaTime()
            emitter.beginTime = emitter.convertTime(
                now,
                from: nil
            )
            emitter.birthRate = 1
            let turn            = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue      = 0
            turn.toValue        = 0.45
            turn.duration       = timing.emits + timing.fades + 1
            turn.timingFunction = CAMediaTimingFunction(name: .easeOut)
            emitter.add(
                turn,
                forKey: "swirl"
            )
            fade(
                mist,
                to      : 0,
                at      : now + timing.emits + 0.6,
                duration: timing.fades
            )
            try? await Task.sleep(for: .seconds(timing.emits))
            emitter.birthRate = 0
        }
    }

    /// The mist's particles: many small motes and a few large soft glows, white and translucent,
    /// each born small, growing and fading out as it drifts up and away.
    private static func cells() -> [CAEmitterCell] {
        let dot = softDot()
        func cell(
            rate    : Float,
            life    : Float,
            scale   : CGFloat,
            velocity: CGFloat,
            alpha   : CGFloat
        ) -> CAEmitterCell {
            let cell           = CAEmitterCell()
            cell.contents      = dot
            cell.birthRate     = rate
            cell.lifetime      = life
            cell.lifetimeRange = life * 0.4
            cell.scale         = scale * 0.3
            cell.scaleRange    = scale * 0.2
            cell.scaleSpeed    = scale * 0.5
            cell.velocity      = velocity
            cell.velocityRange = velocity * 0.6
            cell.emissionRange = .pi * 2
            cell.yAcceleration = 6
            cell.color         = CGColor(
                gray : 1,
                alpha: alpha
            )
            cell.alphaRange    = Float(alpha) * 0.5
            cell.alphaSpeed    = -Float(alpha) / life
            return cell
        }
        return [
            cell(
                rate    : 200,
                life    : 1.8,
                scale   : 0.5,
                velocity: 24,
                alpha   : 0.55
            ),
            cell(
                rate    : 16,
                life    : 2.2,
                scale   : 3,
                velocity: 12,
                alpha   : 0.14
            ),
        ]
    }

    /// A soft white dot, 32 pixels across, fully lit at its centre and fading to nothing at its edge.
    private static func softDot() -> CGImage? {
        let side = 32
        guard let context = CGContext(
                  data            : nil,
                  width           : side,
                  height          : side,
                  bitsPerComponent: 8,
                  bytesPerRow     : 0,
                  space           : CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let gradient = CGGradient(
                  colorsSpace: nil,
                  colors     : [
                      CGColor(gray: 1, alpha: 1),
                      CGColor(gray: 1, alpha: 0.35),
                      CGColor(gray: 1, alpha: 0),
                  ] as CFArray,
                  locations  : [0, 0.35, 1]
              )
        else { return nil }

        let centre = CGPoint(
            x: CGFloat(side) / 2,
            y: CGFloat(side) / 2
        )
        context.drawRadialGradient(
            gradient,
            startCenter: centre,
            startRadius: 0,
            endCenter  : centre,
            endRadius  : CGFloat(side) / 2,
            options    : []
        )
        return context.makeImage()
    }

    // MARK: Words

    /// Says `title` instead: before the words come in, they will be these; once they are in, they
    /// fade and these come in, with a new burst of mist when `mist`, as it begins. Nothing once the
    /// curtain is fading.
    func retitle(
        _ title: String,
        mist   : Bool = false
    ) {
        guard title != self.title, !releasing || wordsAt == nil else { return }
        self.title = title
        if mist, playedAt != nil, !HouseMotion.reducesMotion {
            self.mist.layer?.removeAnimation(forKey: "fade")
            self.mist.alphaValue = 1
            playMist()
        }
        guard wordsAt != nil, let root = words.layer else { return }
        let old = root.sublayers ?? []
        wordsAt = CACurrentMediaTime() + Self.wordsOut
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            old.forEach { $0.removeFromSuperlayer() }
        }
        for layer in old {
            let fade       = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? 1
            fade.toValue   = 0
            fade.duration  = Self.wordsOut
            layer.opacity  = 0
            layer.add(
                fade,
                forKey: "leaving"
            )
        }
        CATransaction.commit()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.wordsOut))
            self?.revealWords()
        }
    }

    /// Brings the title in word by word, centred, as a reply's words arrive.
    private func revealWords() {
        guard !bounds.isEmpty, let picture = wordsPicture() else { return }
        wordsAt = CACurrentMediaTime()

        words.play(
            wordFrames(),
            in        : picture,
            completion: {}
        )
    }

    /// The title's attributes and where it starts, counting y down: smaller where the window is too
    /// narrow for it on one line.
    private var line: (attributes: [NSAttributedString.Key: Any], origin: CGPoint) {
        let colour = NSColor(
            white: Self.grey,
            alpha: 1
        )
        let full   = (title as NSString).size(withAttributes: [.font: Self.font]).width
        let room   = max(1, bounds.width - 2 * Self.sideRoom)
        let font   = full <= room ? Self.font : NSFont.systemFont(
            ofSize: (Self.font.pointSize * room / full).rounded(.down),
            weight: .semibold
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font           : font,
            .foregroundColor: colour,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        return (attributes, CGPoint(
            x: (bounds.midX - size.width / 2).rounded(),
            y: (bounds.midY - size.height / 2).rounded()
        ))
    }

    /// Each word's frame in the curtain, counting y down as `WordReveal` does.
    private func wordFrames() -> [CGRect] {
        let line = line
        func width(_ part: Substring) -> CGFloat {
            (String(part) as NSString).size(withAttributes: line.attributes).width
        }
        let height = (title as NSString).size(withAttributes: line.attributes).height
        return title.split(separator: " ").map { word in
            CGRect(
                x     : line.origin.x + width(title[..<word.startIndex]),
                y     : line.origin.y,
                width : width(word),
                height: height
            )
        }
    }

    /// The title drawn at the curtain's size and backing scale, the picture the words are cut from.
    private func wordsPicture() -> CGImage? {
        let scale = window?.backingScaleFactor ?? 2
        guard let context = CGContext(
            data            : nil,
            width           : Int((bounds.width * scale).rounded(.up)),
            height          : Int((bounds.height * scale).rounded(.up)),
            bitsPerComponent: 8,
            bytesPerRow     : 0,
            space           : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Drawn counting y down, as the picture's rows run.
        context.translateBy(
            x: 0,
            y: CGFloat(context.height)
        )
        context.scaleBy(
            x: scale,
            y: -scale
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: context,
            flipped  : true
        )
        let line = line
        (title as NSString).draw(
            at            : line.origin,
            withAttributes: line.attributes
        )
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: Fading

    /// Fades `view` to `opacity` over `duration` from `time`, showing its old opacity until then.
    private func fade(
        _ view    : NSView,
        to opacity: CGFloat,
        at time   : CFTimeInterval,
        duration  : CFTimeInterval
    ) {
        guard let layer = view.layer else { return }
        let animation            = CABasicAnimation(keyPath: "opacity")
        animation.fromValue      = layer.presentation()?.opacity ?? Float(view.alphaValue)
        animation.toValue        = Float(opacity)
        animation.beginTime      = time
        animation.duration       = duration
        animation.fillMode       = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.alphaValue          = opacity
        layer.add(
            animation,
            forKey: "fade"
        )
    }
}
