//
//  WordFadeTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

@Suite("WordFade")
@MainActor
struct WordFadeTests {

    @Test(
        "Whole, the words are the plain line, pixel for pixel",
        arguments: [
            ("Worker 3", 13.0, NSFont.Weight.semibold, nil),
            ("", 13.0, .semibold, nil),
            ("Reading the sources of the app", 10.5, .regular, nil),
            ("Reading the sources of the app", 10.5, .regular, 80),
        ] as [(String, Double, NSFont.Weight, CGFloat?)]
    )
    func wholeIsPlain(
        text  : String,
        size  : Double,
        weight: NSFont.Weight,
        width : CGFloat?
    ) throws {
        let font  = NSFont.systemFont(
            ofSize: size,
            weight: weight
        )
        let plain = try pixels(
            of   : Text(verbatim: text),
            font : font,
            width: width
        )
        for elapsed in [WordFade.duration(of: text), .infinity] {
            let faded = try pixels(
                of   : WordFade(
                    text   : text,
                    font   : font,
                    elapsed: elapsed
                ),
                font : font,
                width: width
            )
            #expect(faded == plain)
        }
    }

    @Test("Part way, the first word is fading in and the last has not started")
    func halfWay() throws {
        let text  = "One two three four five six"
        let font  = NSFont.systemFont(ofSize: 13)
        let empty = try pixels(
            of   : WordFade(
                text   : text,
                font   : font,
                elapsed: 0
            ),
            font : font,
            width: nil
        )
        // Three words in: the fourth, fifth and sixth have not started.
        let half  = try pixels(
            of   : WordFade(
                text   : text,
                font   : font,
                elapsed: 2.5 * HouseTiming.wordStagger
            ),
            font : font,
            width: nil
        )
        let spans = WordFade.spans(
            of: text,
            in: font
        )
        #expect(spans.count == 6)
        #expect(half.left != empty.left)
        #expect(half.right == empty.right)
    }

    /// The view on black, white, at two pixels per point, its left and right thirds apart.
    private func pixels(
        of view: some View,
        font   : NSFont,
        width  : CGFloat?
    ) throws -> (left: [UInt8], right: [UInt8]) {
        let renderer = ImageRenderer(content: view
            .font(Font(font))
            .lineLimit(1)
            .foregroundStyle(.white)
            .frame(width: width)
            .padding(8)
            .background(Color.black))
        renderer.scale = 2
        let image   = try #require(renderer.cgImage)
        var bytes   = [UInt8](
            repeating: 0,
            count    : image.width * image.height * 4
        )
        let context = try #require(CGContext(
            data            : &bytes,
            width           : image.width,
            height          : image.height,
            bitsPerComponent: 8,
            bytesPerRow     : image.width * 4,
            space           : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(
            image,
            in: CGRect(
                x     : 0,
                y     : 0,
                width : image.width,
                height: image.height
            )
        )
        let third = image.width / 3
        var left : [UInt8] = []
        var right: [UInt8] = []
        for row in 0..<image.height {
            let start = row * image.width * 4
            left  += bytes[start..<(start + third * 4)]
            right += bytes[(start + (image.width - third) * 4)..<(start + image.width * 4)]
        }
        return (left, right)
    }
}
