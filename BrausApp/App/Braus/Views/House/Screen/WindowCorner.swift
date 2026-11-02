//
//  WindowCorner.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import CoreImage
import IOSurface

/// WindowCorner reads how round a captured window's corners are from its picture: the window is
/// clear outside its shape, so along the diagonal from the picture's top-left corner the first
/// opaque pixel lies where the corner's arc crosses it, at a radius times (1 - 1/√2) from the
/// corner. A square window is opaque at the corner itself. It reads one small square of pixels, once
/// per window and size, never per frame, and assumes the four corners alike.
enum WindowCorner {

    /// The side of the square read at the corner, in pixels: room for a radius of 100 pixels.
    private static let reach = 48

    /// The least opacity of a pixel of the window's body; a shadow or an edge's smoothing is fainter.
    private static let opaque: UInt8 = 160

    /// Below this a corner is taken as square, in points.
    private static let square: CGFloat = 2

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The corner radius, in points of the window, of the picture `layer` shows, a window `points` wide;
    /// nil while it shows none, or nothing opaque near its corner.
    @MainActor
    static func radius(
        of layer: CALayer,
        windowWidth points: CGFloat
    ) -> CGFloat? {
        guard points > 0, let contents = layer.contents else { return nil }
        let image: CIImage
        if let surface = (contents as AnyObject) as? IOSurface {
            image = CIImage(ioSurface: surface)
        } else if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
            image = CIImage(cgImage: contents as! CGImage)
        } else { return nil }
        let unit   = layer.contentsRect
        let extent = image.extent
        // The window's part of the picture, its top-left corner in Core Image's space, y up.
        let window = CGRect(
            x     : extent.minX + unit.minX * extent.width,
            y     : extent.minY + (1 - unit.maxY) * extent.height,
            width : unit.width * extent.width,
            height: unit.height * extent.height
        )
        guard window.width > 0 else { return nil }
        let side   = min(reach, Int(window.width), Int(window.height))
        guard side > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        context.render(
            image,
            toBitmap: &pixels,
            rowBytes: side * 4,
            bounds  : CGRect(
                x     : window.minX,
                y     : window.maxY - CGFloat(side),
                width : CGFloat(side),
                height: CGFloat(side)
            ),
            format  : .RGBA8,
            colorSpace: nil
        )
        return radius(
            alphaOf: pixels,
            side   : side,
            scale  : window.width / points
        )
    }

    /// The radius in points of a corner `pixels` deep along the diagonal, at `scale` pixels to a point.
    private static func radius(
        clearFor pixels: Int,
        scale          : CGFloat
    ) -> CGFloat {
        let radius = CGFloat(pixels) / (1 - 1 / 2.squareRoot()) / max(scale, 0.01)
        return radius < square ? 0 : radius.rounded()
    }

    /// The radius of the corner in a square of RGBA `pixels` `side` wide at the window's top-left
    /// corner, in points at `scale` pixels to a point. Whichever way the rows run, the corner is at
    /// one end of the first column: the diagonal from the other end lies in the window's body.
    static func radius(
        alphaOf pixels: [UInt8],
        side          : Int,
        scale         : CGFloat
    ) -> CGFloat? {
        func clear(from row: Int, down: Bool) -> Int? {
            for step in 0..<side {
                let y = down ? row + step : row - step
                if pixels[(y * side + step) * 4 + 3] >= opaque { return step }
            }
            return nil
        }
        // The diagonal through the body meets it at once; the one through the corner, past the arc.
        let ways = [clear(from: 0, down: true), clear(from: side - 1, down: false)]
        guard ways.allSatisfy({ $0 != nil }), let deepest = ways.compactMap({ $0 }).max() else { return nil }
        return radius(
            clearFor: deepest,
            scale   : scale
        )
    }
}
