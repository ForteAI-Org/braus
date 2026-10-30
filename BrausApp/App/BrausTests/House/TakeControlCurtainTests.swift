//
//  TakeControlCurtainTests.swift
//  BrausTests
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import AppKit
import Testing
@testable import Braus

@Suite("TakeControlCurtain")
@MainActor
struct TakeControlCurtainTests {

    /// A flipped stand-in for the live view, as `LivePreviewView` is.
    private final class Picture: NSView {
        override var isFlipped: Bool { true }
    }

    /// A picture showing `shown` of a small image, counted from the top as the live view counts it.
    private func picture(showing shown: CGRect) throws -> Picture {
        let context = try #require(CGContext(
            data            : nil,
            width           : 4,
            height          : 4,
            bitsPerComponent: 8,
            bytesPerRow     : 16,
            space           : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let picture = Picture(frame: CGRect(
            x     : 0,
            y     : 0,
            width : 100,
            height: 60
        ))
        picture.wantsLayer          = true
        picture.layer?.contents     = context.makeImage()
        picture.layer?.contentsRect = shown
        return picture
    }

    @Test("The mask takes the part of the buffer a capped stream filled, its top left, not its bottom left")
    func maskTakesTheShownPart() throws {
        let shown   = CGRect(x: 0, y: 0, width: 0.7, height: 0.7)
        let curtain = TakeControlCurtain(
            title  : "",
            picture: try picture(showing: shown)
        )
        let mask    = try #require(curtain.layer?.mask?.contentsRect)
        #expect(abs(mask.minY - 0.3) < 0.0001 && mask.minX == 0)
        #expect(abs(mask.width - 0.7) < 0.0001 && abs(mask.height - 0.7) < 0.0001)
    }

    @Test("A picture that fills its buffer masks the whole curtain")
    func wholeBufferStaysWhole() throws {
        let whole   = CGRect(x: 0, y: 0, width: 1, height: 1)
        let curtain = TakeControlCurtain(
            title  : "",
            picture: try picture(showing: whole)
        )
        #expect(curtain.layer?.mask?.contentsRect == whole)
    }
}
