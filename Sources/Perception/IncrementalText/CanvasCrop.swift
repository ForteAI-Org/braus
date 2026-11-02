//
//  CanvasCrop.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Foundation
import ImageIO

/// CanvasCrop is the before and after picture of the part of one canvas that changed: the same
/// rectangle of the window cut from two frames and encoded as PNG, the format every model provider
/// accepts.
///
/// The rectangle is the union of the changed tiles inside the canvas, grown by `margin` and clipped
/// to the canvas, so only canvas pixels leave. It is drawn at `zoom` pixels per window point, 1 by
/// default, so a Retina frame is reduced 2:1. When the changed tiles span more than
/// `wholeCanvasShare` of the canvas, the crop is the whole canvas, reduced so its long edge is at most
/// `maxWholeCanvasEdge` pixels. These defaults come from a measured comparison across three models:
/// 1x crops with a margin kept full accuracy at about a thirtieth of the tokens of whole-canvas 2x
/// pairs, while an after picture alone of the whole window failed.
///
/// Building is pure: no capture, no clock, no state. `layout` decides the rectangle, so a caller can
/// apply its privacy rule to it before `make` renders any pixel.
public struct CanvasCrop: Sendable, Equatable {

    /// Points of context kept around the changed tiles.
    public static let margin: CGFloat = 24
    /// Share of the canvas's area above which the crop is the whole canvas.
    public static let wholeCanvasShare: CGFloat = 0.6
    /// The longest edge, in pixels, of a whole-canvas crop.
    public static let maxWholeCanvasEdge: CGFloat = 1280

    /// One frame's pixels and where they sit in the window: `origin` is the window point of the
    /// image's top-left pixel and `scale` its pixels per point. A whole-window still has origin zero.
    /// Window points have a top-left origin, as the scene's normalized bounds do.
    public struct Source: Sendable {
        public let image : CGImage
        public let origin: CGPoint
        public let scale : CGFloat

        public init(
            image : CGImage,
            origin: CGPoint = .zero,
            scale : CGFloat
        ) {
            self.image  = image
            self.origin = origin
            self.scale  = scale
        }

        /// The window rectangle the image shows, in points.
        public var frame: CGRect {
            CGRect(
                x     : origin.x,
                y     : origin.y,
                width : CGFloat(image.width) / scale,
                height: CGFloat(image.height) / scale
            )
        }
    }

    /// Where a crop is and how large it is drawn, decided before any pixel is read.
    public struct Layout: Sendable, Equatable {
        /// The window rectangle shown, in whole points inside the canvas.
        public let rect          : CGRect
        public let pixelsPerPoint: CGFloat
        public let pixelWidth    : Int
        public let pixelHeight   : Int
        public let isWholeCanvas : Bool
    }

    /// Why no crop could be made.
    public enum Failure: Error, Equatable {
        /// A source scale or a zoom below 1, or an empty canvas.
        case invalidInput
        /// Drawing or PNG encoding failed.
        case render
    }

    public let layout: Layout
    /// The rectangles, in window points, filled with a flat grey in both pictures.
    public let blanked: [CGRect]
    public let before : Data
    public let after  : Data

    /// Image tokens of the pair as Claude estimates them: ceil(w/28) * ceil(h/28) per picture.
    public var claudeTokens: Int {
        2 * Self.ceilDivide(layout.pixelWidth, 28) * Self.ceilDivide(layout.pixelHeight, 28)
    }

    /// Image tokens of the pair as GPT estimates them: ceil(w/32) * ceil(h/32) * 1.2 per picture.
    public var gptTokens: Int {
        let patches = 2 * Self.ceilDivide(layout.pixelWidth, 32) * Self.ceilDivide(layout.pixelHeight, 32)
        return Int((Double(patches) * 1.2).rounded(.up))
    }

    /// The crop of `canvas` that shows `changed`, both in window points, at `zoom` pixels per point;
    /// nil when no changed rectangle falls inside the canvas, so nothing is to be shown. Zoom 2 is for
    /// an explicit request only.
    public static func layout(
        canvas : CGRect,
        changed: [CGRect],
        zoom   : Int = 1
    ) -> Layout? {
        let inner = inward(canvas)
        guard zoom >= 1, !inner.isEmpty else { return nil }
        let touched = changed.map { $0.intersection(inner) }.filter { !$0.isNull && !$0.isEmpty }
        guard let first = touched.first else { return nil }
        let span = touched.dropFirst().reduce(first) { $0.union($1) }
        var scale = CGFloat(zoom)
        let isWholeCanvas = span.width * span.height > inner.width * inner.height * wholeCanvasShare
        let rect: CGRect
        if isWholeCanvas {
            rect  = inner
            scale = min(
                scale,
                maxWholeCanvasEdge / max(inner.width, inner.height)
            )
        } else {
            rect = inward(span.insetBy(dx: -margin, dy: -margin).intersection(inner))
        }
        guard !rect.isEmpty else { return nil }
        return Layout(
            rect          : rect,
            pixelsPerPoint: scale,
            pixelWidth    : max(1, Int((rect.width * scale).rounded())),
            pixelHeight   : max(1, Int((rect.height * scale).rounded())),
            isWholeCanvas : isWholeCanvas
        )
    }

    /// Draws `layout` from both sources and encodes each as PNG. Window areas a source does not
    /// cover, and the `blanking` rectangles (window points), are flat grey in that picture. The
    /// sources are borrowed for the call only.
    public static func make(
        before  : Source,
        after   : Source,
        layout  : Layout,
        blanking: [CGRect] = []
    ) throws(Failure) -> CanvasCrop {
        guard before.scale > 0, after.scale > 0 else { throw .invalidInput }
        let blanked = blanking.map { $0.intersection(layout.rect) }.filter { !$0.isNull && !$0.isEmpty }
        guard let beforeData = render(before, layout: layout, blanked: blanked),
              let afterData = render(after, layout: layout, blanked: blanked) else { throw .render }
        return CanvasCrop(
            layout : layout,
            blanked: blanked,
            before : beforeData,
            after  : afterData
        )
    }

    /// The largest rectangle of whole points inside `rect`, so a 1x crop copies pixels without
    /// resampling and never reaches past the canvas.
    private static func inward(_ rect: CGRect) -> CGRect {
        guard !rect.isNull, !rect.isEmpty else { return .null }
        let minX = rect.minX.rounded(.up)
        let minY = rect.minY.rounded(.up)
        let maxX = rect.maxX.rounded(.down)
        let maxY = rect.maxY.rounded(.down)
        guard maxX > minX, maxY > minY else { return .null }
        return CGRect(
            x     : minX,
            y     : minY,
            width : maxX - minX,
            height: maxY - minY
        )
    }

    private static func render(
        _ source: Source,
        layout  : Layout,
        blanked : [CGRect]
    ) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data            : nil,
                  width           : layout.pixelWidth,
                  height          : layout.pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow     : 0,
                  space           : space,
                  bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let height = CGFloat(layout.pixelHeight)
        let scale  = layout.pixelsPerPoint
        // Window points (top-left origin) to the context's pixels (bottom-left origin).
        func pixels(_ rect: CGRect) -> CGRect {
            CGRect(
                x     : (rect.minX - layout.rect.minX) * scale,
                y     : height - (rect.maxY - layout.rect.minY) * scale,
                width : rect.width * scale,
                height: rect.height * scale
            )
        }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(
            x     : 0,
            y     : 0,
            width : layout.pixelWidth,
            height: layout.pixelHeight
        ))
        context.interpolationQuality = .high
        context.draw(
            source.image,
            in: pixels(source.frame)
        )
        for rect in blanked { context.fill(pixels(rect)) }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            nil
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func ceilDivide(_ value: Int, _ divisor: Int) -> Int { (value + divisor - 1) / divisor }
}
