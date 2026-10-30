//
//  NeonTube.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import os
import QuartzCore

/// NeonTube is the neon that marks a window and who has it: a tube just outside the window, a thin
/// near-white core in a coloured glow with a wide soft bloom fading outward, in the working worker's
/// amber while the worker uses the application and in the waiting blue while the person does. A
/// change of hands recolours it from the bottom of the window's edge outward and around
/// (`recolour(to:)`). A dark lift shadow under it only dimmed the bloom on dark screens. Nothing is
/// drawn over the window itself.
///
/// It is drawn once, as a nine-part image whose middle stretches with the window, on one layer
/// (`layer`): a move or a resize only moves or stretches it, with no shadow or mask to render.
/// The lent window's border carries it in a panel over the screen (`ControlWindowBorder`); the
/// screen window draws it in its own margin, so it moves with the window (`ScreenWindowFrame`). A
/// twin of one of the application's other windows wears it thin (`Style.thin`).
final class NeonTube {

    /// Style is the neon's reach: its gap from the window, its tube, the halo it may fill, and the
    /// wide bloom and the glow close around the tube, each the blur of a stroke as wide as given, in
    /// points. A stroke as thin as the tube would fade out within a few points of it.
    struct Style {
        let gap  : CGFloat
        let line : CGFloat
        let halo : CGFloat
        let bloom: (blur: CGFloat, width: CGFloat)
        let glow : (blur: CGFloat, width: CGFloat)

        /// The main window's neon, and the thin one of the application's other windows.
        static let wide = Style(
            gap  : HumanControlLayout.borderGap,
            line : HumanControlLayout.borderLine,
            halo : HumanControlLayout.borderHalo,
            bloom: (blur: 34, width: 14),
            glow : (blur: 8, width: 4)
        )
        static let thin = Style(
            gap  : 1,
            line : 2,
            halo : 14,
            bloom: (blur: 9, width: 5),
            glow : (blur: 3, width: 2)
        )

        /// How far the neon reaches out of the window it marks.
        var reach: CGFloat { gap + line + halo }

        /// The inset of the rect the tube is stroked on, centred on it.
        var lineInset: CGFloat { halo + line / 2 }

        /// The tube's corner around a window's `corner`, concentric with it; square around a square one.
        func tubeCorner(around corner: CGFloat) -> CGFloat {
            corner > 0 ? corner + gap + line / 2 : 0
        }

        /// How far each corner of the image reaches in around a window's `corner`: past it by as much
        /// again as the bloom, so the one point stretched along each edge is a straight edge's.
        func slice(around corner: CGFloat) -> CGFloat { reach + corner + bloom.blur }
    }

    /// How far it reaches and how it glows.
    let style: Style

    /// Holder is who has the window, which the neon's colour says.
    enum Holder {
        case worker, person

        var light: (red: Double, green: Double, blue: Double) {
            switch self {
            case .worker: WorkerStatus.busy.light ?? (red: 1, green: 0.69, blue: 0.28)
            case .person: WorkerStatus.waiting.light ?? (red: 0.47, green: 0.67, blue: 1)
            }
        }
    }

    /// The neon, to put in a layer tree and place with `place(around:)`.
    let layer = CALayer()

    /// The new colour while a recolour sweeps it over the neon, and the sweep, its mask.
    private let wash  = CALayer()
    private let sweep = CAGradientLayer()

    /// Who has the window, as the neon shows it.
    private(set) var holder: Holder

    /// The sharpest screen's scale, so the core stays crisp on whichever screen the window is.
    private let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2

    /// The window's corner radius the neon follows, in points: square at zero.
    private(set) var corner: CGFloat

    init(
        holder: Holder,
        style : Style = .wide,
        corner: CGFloat = NeonTube.windowCorner
    ) {
        self.holder = holder
        self.style  = style
        self.corner = corner
        layer.contents  = image(for: holder)
        stretch()
        sweep.type      = .radial
        sweep.colors    = [CGColor.black, CGColor.black, CGColor.clear]
        sweep.locations = [0, 0, 0]
        wash.mask       = sweep
        layer.addSublayer(wash)
    }

    /// Follows a window whose corner is `corner` points round, square at zero: the image is drawn
    /// again, once.
    func setCorner(_ corner: CGFloat) {
        guard corner != self.corner else { return }
        self.corner = corner
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image(for: holder)
        // A sweep under way goes on in its own colour.
        if wash.contents != nil { wash.contents = image(for: holder) }
        stretch()
        CATransaction.commit()
    }

    /// The neon in `holder`'s colour around the window's corner.
    private func image(for holder: Holder) -> CGImage? {
        Self.neonImage(
            style : style,
            corner: corner,
            scale : scale,
            light : holder.light
        )
    }

    /// Where the image stretches with the window: the one point in its middle.
    private func stretch() {
        let slice = style.slice(around: corner)
        let side  = 2 * slice + 1
        for layer in [layer, wash] {
            layer.contentsScale  = scale
            layer.contentsCenter = CGRect(
                x     : slice / side,
                y     : slice / side,
                width : 1 / side,
                height: 1 / side
            )
        }
    }

    /// Places the neon around a window of `frame`, in its superlayer's coordinates, at once.
    func place(around frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = frame.insetBy(
            dx: -style.reach,
            dy: -style.reach
        )
        wash.frame  = layer.bounds
        sweep.frame = wash.bounds
        // The sweep starts at the middle of the window's bottom edge, y up from the neon's bottom,
        // and reaches past its far corners.
        let bottom  = style.reach / max(1, layer.bounds.height)
        sweep.startPoint = CGPoint(
            x: 0.5,
            y: bottom
        )
        sweep.endPoint   = CGPoint(
            x: 1.7,
            y: bottom + 1.2
        )
        CATransaction.commit()
    }

    /// How long a recolour takes to cover the neon.
    static let recolouring: CFTimeInterval = 0.9

    /// The number of the last recolour: a sweep that ends after a later one leaves its colour alone.
    private var recolours = 0

    /// Gives the neon `holder`'s colour, swept from the middle of the window's bottom edge outward
    /// and around, or under Reduce Motion faded in.
    func recolour(to holder: Holder) {
        guard holder != self.holder else { return }
        self.holder = holder
        recolours  += 1
        let run   = recolours
        let image = image(for: holder)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A sweep under way ends where it was going: its colour is the neon's from now on.
        if wash.contents != nil { layer.contents = wash.contents }
        wash.contents   = image
        sweep.locations = HouseMotion.reducesMotion ? [0, 1.2, 1.2] : [0, 1, 1.15]
        wash.opacity    = 1
        CATransaction.commit()

        Self.log.notice("neon: the recolour to \(String(describing: holder), privacy: .public) starts")
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.recoloured(run) }
        }
        if HouseMotion.reducesMotion {
            let fade       = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue   = 1
            fade.duration  = 0.25
            wash.add(
                fade,
                forKey: Self.recolourKey
            )
        } else {
            let spread            = CABasicAnimation(keyPath: "locations")
            spread.fromValue      = [0, 0, 0]
            spread.toValue        = [0, 1, 1.15]
            spread.duration       = Self.recolouring
            spread.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sweep.add(
                spread,
                forKey: Self.recolourKey
            )
        }
        CATransaction.commit()
    }

    /// The recolour `run` covered the neon: its colour is the neon's own, unless a later one began.
    private func recoloured(_ run: Int) {
        guard run == recolours else { return }
        Self.log.notice("neon: the recolour to \(String(describing: self.holder), privacy: .public) ends")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents  = wash.contents
        wash.contents   = nil
        sweep.locations = [0, 0, 0]
        CATransaction.commit()
    }

    private static let recolourKey = "recolour"

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "HumanControl"
    )

    /// A window's corner on macOS 26, until a window's own is measured (`WindowCorner`).
    static let windowCorner: CGFloat = 14

    /// The neon in `style` around the smallest window the image holds, whose corner is `corner`
    /// points round, in `light`, drawn at `scale`.
    private static func neonImage(
        style : Style,
        corner: CGFloat,
        scale : CGFloat,
        light : (red: Double, green: Double, blue: Double)
    ) -> CGImage? {
        let side = 2 * style.slice(around: corner) + 1
        guard let context = CGContext(
            data            : nil,
            width           : Int((side * scale).rounded(.up)),
            height          : Int((side * scale).rounded(.up)),
            bitsPerComponent: 8,
            bytesPerRow     : 0,
            space           : CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(
            x: scale,
            y: scale
        )
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let window = rounded(
            bounds.insetBy(
                dx: style.reach,
                dy: style.reach
            ),
            corner: corner
        )
        let tube   = rounded(
            bounds.insetBy(
                dx: style.lineInset,
                dy: style.lineInset
            ),
            corner: style.tubeCorner(around: corner)
        )
        func tint(white: CGFloat = 0) -> CGColor {
            CGColor(
                srgbRed: light.red + (1 - light.red) * white,
                green  : light.green + (1 - light.green) * white,
                blue   : light.blue + (1 - light.blue) * white,
                alpha  : 1
            )
        }

        // The window is cut out of everything that follows.
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(window)
        context.addPath(outside)
        context.clip(using: .evenOdd)

        // Each glow is a wide stroke's blur alone: the stroke lies off the image and its shadow, given
        // in pixels since a shadow ignores the scale, falls back on the tube.
        for (blur, width) in [style.bloom, style.glow] {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 2 * side * scale, height: 0),
                blur  : blur * scale,
                color : tint()
            )
            context.translateBy(
                x: -2 * side,
                y: 0
            )
            context.setLineWidth(width)
            context.setStrokeColor(tint())
            context.addPath(tube)
            context.strokePath()
            context.restoreGState()
        }

        // The tube in its colour, then the core: near white with the colour in it.
        context.setLineWidth(style.line)
        context.setStrokeColor(tint())
        context.addPath(tube)
        context.strokePath()
        context.setLineWidth(style.line / 2)
        context.setStrokeColor(tint(white: 0.75))
        context.addPath(tube)
        context.strokePath()
        return context.makeImage()
    }

    /// `rect` with round corners, the radius kept within what the rect can hold.
    static func rounded(
        _ rect: CGRect,
        corner: CGFloat
    ) -> CGPath {
        let radius = max(0, min(corner, rect.width / 2, rect.height / 2))
        return CGPath(
            roundedRect : rect.standardized,
            cornerWidth : radius,
            cornerHeight: radius,
            transform   : nil
        )
    }
}
