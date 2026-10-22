//
//  BubbleFlightTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI
import Testing
@testable import Braus

@Suite("BubbleFlight")
@MainActor
struct BubbleFlightTests {

    @Test("A flight and the transcript making room settle in the send flight's time")
    func settlesInTheSendFlight() {
        #expect(abs(BubbleFlight.flightDuration - HouseTiming.sendFlight) < 0.01)
    }

    @Test(
        "A strip's line is drawn as the strip's SwiftUI text draws it, cut short in the same place",
        arguments: [
            ("Short", 300, 8),
            ("A message quoted in the next one, long enough to be cut short", 200, 8),
            ("Ünïcødé and emoji 👋 in a line", 300, 40),
        ] as [(String, CGFloat, Int)]
    )
    func lineMatchesTheStrip(
        text     : String,
        width    : CGFloat,
        tolerance: Int
    ) throws {
        let drawn    = try #require(BubbleFlight.image(
            of   : text,
            width: width,
            scale: 2
        ))
        let renderer = ImageRenderer(content: Text(text)
            .font(QueueStrip.font)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .environment(
                \.colorScheme,
                .dark
            ))
        renderer.proposedSize = ProposedViewSize(
            width : width,
            height: nil
        )
        renderer.scale = 2
        let strip = try #require(renderer.cgImage)
        #expect(drawn.image.width == strip.width)
        #expect(drawn.image.height == strip.height)
        #expect(drawn.size.width * 2 == CGFloat(strip.width))
        // Antialiasing of a glyph edge, or an emoji's bitmap scaled another way, never a moved glyph.
        #expect(try largestDifference(
            drawn.image,
            strip
        ) <= tolerance)
    }

    /// The largest difference of any channel between two images of one size, both over black.
    private func largestDifference(
        _ first : CGImage,
        _ second: CGImage
    ) throws -> Int {
        let pairs = zip(
            try pixels(of: first),
            try pixels(of: second)
        )
        return pairs.map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    private func pixels(of image: CGImage) throws -> [UInt8] {
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
            space           : CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bounds  = CGRect(
            x     : 0,
            y     : 0,
            width : image.width,
            height: image.height
        )
        context.setFillColor(.black)
        context.fill(bounds)
        context.draw(
            image,
            in: bounds
        )
        return bytes
    }
}
