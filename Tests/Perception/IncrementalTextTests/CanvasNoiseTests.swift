//
//  CanvasNoiseTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
@testable import IncrementalText

@Suite
struct CanvasNoiseTests {

    /// The canvas fixture's timeline and level meter in window image pixels (1x recordings).
    private static let timeline = CGRect(
        x     : 160,
        y     : 172,
        width : 900,
        height: 320
    )
    private static let meter = CGRect(
        x     : 982,
        y     : 180,
        width : 68,
        height: 48
    )
    private static let laneTwo = CGRect(
        x     : 160,
        y     : 252,
        width : 900,
        height: 80
    )

    @Test
    func idleMeterPhasesMaskOnlyTheMeter() throws {
        var noise = CanvasNoise()
        var last: RegionTileDiff.Frame?
        for index in 0..<6 {
            let frame = try fixtureFrame("meter-phases/\(index)")
            noise.observe(
                frame,
                region  : 0,
                hadInput: false
            )
            last = frame
        }
        let grid = try #require(last?.grids.first)
        #expect(!noise.mask.isEmpty)
        #expect(!noise.isAlwaysChanging)
        for index in noise.mask {
            let rect = try #require(grid.rect(at: index))
            #expect(rect.intersects(Self.meter))
        }

        let still = try fixtureFrame("still")
        let moved = try fixtureFrame("clip-moved")
        let phase = try #require(last)
        for before in [still, phase] {
            let unmasked = try #require(RegionTileDiff.changes(
                from: before,
                to  : moved
            ))
            let masked = try #require(RegionTileDiff.changes(
                from    : before,
                to      : moved,
                ignoring: [noise.mask]
            ))
            #expect(!masked[0].rects.isEmpty)
            for rect in masked[0].rects {
                #expect(Self.laneTwo.contains(rect))
            }
            #expect(unmasked[0].rects.contains { $0.intersects(Self.meter) } == (before == phase))
        }
    }

    @Test("A capture's colour jitter of a level teaches no noise")
    func colourJitterTeachesNothing() throws {
        var noise = CanvasNoise()
        let level = 1.0 / 255
        try observe(
            &noise,
            shades: [0.5, 0.5 + level, 0.5, 0.5 + level, 0.5]
        )
        #expect(noise.mask.isEmpty && !noise.isAlwaysChanging)
    }

    @Test
    func oneIdleComparisonIsNotEnough() throws {
        var noise = CanvasNoise()
        try observe(
            &noise,
            shades: [0.2, 0.4]
        )
        #expect(noise.mask.isEmpty)
        try observe(
            &noise,
            shades: [0.6]
        )
        #expect(noise.mask == [5])
    }

    @Test
    func inputBetweenFramesTeachesNothing() throws {
        var noise = CanvasNoise()
        try observe(
            &noise,
            shades  : [0.2, 0.4, 0.6, 0.8],
            hadInput: true
        )
        #expect(noise.mask.isEmpty)
        try observe(
            &noise,
            shades: [0.2]
        )
        #expect(noise.mask.isEmpty)
    }

    @Test
    func forgetsAfterQuietIdleComparisons() throws {
        var noise = CanvasNoise()
        try observe(
            &noise,
            shades: [0.2, 0.4, 0.6]
        )
        #expect(noise.mask == [5])
        try observe(
            &noise,
            shades: Array(
                repeating: 0.6,
                count    : CanvasNoise.forgetAfter - 1
            )
        )
        // A comparison with input in between does not count toward forgetting.
        try observe(
            &noise,
            shades  : [0.6],
            hadInput: true
        )
        #expect(noise.mask == [5])
        try observe(
            &noise,
            shades: [0.6]
        )
        #expect(noise.mask.isEmpty)
        try observe(
            &noise,
            shades: [0.8]
        )
        #expect(noise.mask.isEmpty)
    }

    @Test
    func regionSizeOrConfigurationChangeResets() throws {
        var noise = CanvasNoise()
        try observe(
            &noise,
            shades: [0.2, 0.4, 0.6]
        )
        #expect(noise.mask == [5])
        noise.observe(
            try frame(
                shade : 0.8,
                height: 40
            ),
            region  : 0,
            hadInput: false
        )
        #expect(noise.mask.isEmpty)
        try observe(
            &noise,
            shades: [0.2, 0.4, 0.6]
        )
        #expect(noise.mask == [5])
        noise.observe(
            try frame(
                shade: 0.8,
                tile : 4
            ),
            region  : 0,
            hadInput: false
        )
        #expect(noise.mask.isEmpty)
        // The new frame is only a baseline, so one more idle change does not mask.
        noise.observe(
            try frame(
                shade: 0.2,
                tile : 4
            ),
            region  : 0,
            hadInput: false
        )
        #expect(noise.mask.isEmpty)
    }

    @Test
    func overHalfTheRegionIsReportedNotApplied() throws {
        // 64 x 32 pixels at 8-pixel tiles are 32 tiles: 16 is half, 17 is more than half.
        var half = CanvasNoise()
        try observe(
            &half,
            shades: [0.2, 0.4, 0.6],
            tiles : Array(0..<16)
        )
        #expect(!half.isAlwaysChanging)
        #expect(half.mask == Set(0..<16))

        var most = CanvasNoise()
        try observe(
            &most,
            shades: [0.2, 0.4, 0.6],
            tiles : Array(0..<17)
        )
        #expect(most.isAlwaysChanging)
        #expect(most.noise == Set(0..<17))
        #expect(most.mask.isEmpty)
    }

    @Test(.enabled(if: getenv("BRAUS_CANVAS_NOISE_BENCH") != nil))
    func benchmarkRetinaRegionUpdate() throws {
        let region = CGRect(
            x     : 0,
            y     : 0,
            width : 2522,
            height: 1654
        )
        let frames = try [0.2, 0.4].map { shade in
            try #require(RegionTileDiff.frame(
                try image(
                    width : 2522,
                    height: 1654,
                    shade : shade,
                    paint : [CGRect(
                        x     : 300,
                        y     : 400,
                        width : 64,
                        height: 64
                    )]
                ),
                regions: [region]
            ))
        }
        let tiles = frames[0].grids[0].hashes.count
        var noise = CanvasNoise()
        var samples: [Double] = []
        for iteration in 0..<1_020 {
            let start = ContinuousClock.now
            noise.observe(
                frames[iteration % 2],
                region  : 0,
                hadInput: false
            )
            let elapsed = start.duration(to: .now).components
            if iteration >= 20 {
                samples.append(Double(elapsed.seconds) * 1e6 + Double(elapsed.attoseconds) / 1e12)
            }
        }
        #expect(!noise.mask.isEmpty)
        samples.sort()
        let median = (samples[499] + samples[500]) / 2
        print("CANVAS_NOISE_BENCH median_us=\(median) tiles=\(tiles) samples=1000 warmup=20")
    }

    // MARK: - Helpers

    /// Observes one 64 x 32 frame per shade, painting `tiles` (8-pixel tiles, 8 per row) in that shade.
    private func observe(
        _ noise : inout CanvasNoise,
        shades  : [CGFloat],
        tiles   : [Int] = [5],
        hadInput: Bool  = false
    ) throws {
        for shade in shades {
            noise.observe(
                try frame(
                    shade: shade,
                    tiles: tiles
                ),
                region  : 0,
                hadInput: hadInput
            )
        }
    }

    private func frame(
        shade : CGFloat,
        tiles : [Int] = [5],
        height: Int   = 32,
        tile  : Int   = 8
    ) throws -> RegionTileDiff.Frame {
        let rects = tiles.map { index in
            CGRect(
                x     : (index % 8) * 8,
                y     : (index / 8) * 8,
                width : 8,
                height: 8
            )
        }
        return try #require(RegionTileDiff.frame(
            try image(
                width : 64,
                height: height,
                shade : shade,
                paint : rects
            ),
            regions  : [CGRect(
                x     : 0,
                y     : 0,
                width : 64,
                height: height
            )],
            downscale: 1,
            tile     : tile
        ))
    }

    private func fixtureFrame(_ variant: String) throws -> RegionTileDiff.Frame {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Canvas/\(variant).png")
        let source = try #require(CGImageSourceCreateWithURL(
            url as CFURL,
            nil
        ))
        let image = try #require(CGImageSourceCreateImageAtIndex(
            source,
            0,
            nil
        ))
        return try #require(RegionTileDiff.frame(
            image,
            regions: [Self.timeline]
        ))
    }

    private func image(
        width : Int,
        height: Int,
        shade : CGFloat,
        paint : [CGRect]
    ) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data            : nil,
            width           : width,
            height          : height,
            bitsPerComponent: 8,
            bytesPerRow     : 0,
            space           : space,
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(
            gray : 1,
            alpha: 1
        ))
        context.fill(CGRect(
            x     : 0,
            y     : 0,
            width : width,
            height: height
        ))
        context.setFillColor(CGColor(
            gray : shade,
            alpha: 1
        ))
        for rect in paint {
            context.fill(CGRect(
                x     : rect.minX,
                y     : CGFloat(height) - rect.maxY,
                width : rect.width,
                height: rect.height
            ))
        }
        return try #require(context.makeImage())
    }
}
