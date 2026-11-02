//
//  WindowCornerTests.swift
//  BrausTests
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import Testing
@testable import Braus

@Suite("WindowCorner")
@MainActor
struct WindowCornerTests {

    /// The RGBA pixels of a `side` square at a window's top-left corner, the window `corner` points
    /// round at `scale`, or nothing of it when `corner` is nil.
    private func corner(
        _ corner: CGFloat?,
        side    : Int,
        scale   : CGFloat
    ) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let corner else { return pixels }
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data            : buffer.baseAddress,
                width           : side,
                height          : side,
                bitsPerComponent: 8,
                bytesPerRow     : side * 4,
                space           : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
            )
            // The window reaches past the square to the right and below: its top-left corner is the
            // square's.
            let window = CGRect(
                x     : 0,
                y     : -CGFloat(side),
                width : CGFloat(side) * 2,
                height: CGFloat(side) * 2
            )
            context?.addPath(NeonTube.rounded(
                window,
                corner: corner * scale
            ))
            context?.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context?.fillPath()
        }
        return pixels
    }

    @Test("A window's corner is read from where its clear corner meets its body along the diagonal")
    func readsTheCorner() throws {
        let round  = try #require(WindowCorner.radius(
            alphaOf: corner(10, side: 48, scale: 2),
            side   : 48,
            scale  : 2
        ))
        #expect(abs(round - 10) <= 2, "a macOS window's corner, within a point or two: \(round)")

        let square = WindowCorner.radius(
            alphaOf: corner(0, side: 48, scale: 2),
            side   : 48,
            scale  : 2
        )
        #expect(square == 0, "a Qt panel's square corner")

        let clear  = WindowCorner.radius(
            alphaOf: corner(nil, side: 48, scale: 2),
            side   : 48,
            scale  : 2
        )
        #expect(clear == nil, "nothing to read, so the corner stays as it was")
    }
}
