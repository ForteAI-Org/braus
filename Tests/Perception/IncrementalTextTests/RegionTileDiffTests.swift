//
//  RegionTileDiffTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Darwin
import Testing
@testable import IncrementalText

@Suite
struct RegionTileDiffTests {

    @Test
    func mapsOddOriginsAndPartialEdgesExactly() throws {
        let region = CGRect(
            x     : 3,
            y     : 5,
            width : 67,
            height: 65
        )
        let before = try image()
        let after = try image(paint: [CGRect(
            x     : 68,
            y     : 69,
            width : 2,
            height: 1
        )])
        let changes = try #require(RegionTileDiff.changes(
            from   : before,
            to     : after,
            regions: [region]
        ))
        #expect(changes.count == 1)
        #expect(changes[0].indices == [8])
        #expect(changes[0].rects == [CGRect(
            x     : 67,
            y     : 69,
            width : 3,
            height: 1
        )])
        #expect(changes[0].cropRects == changes[0].rects)
    }

    @Test
    func findsInteriorTileAndIgnoresOutsideChanges() throws {
        let region = CGRect(
            x     : 3,
            y     : 5,
            width : 67,
            height: 65
        )
        let before = try image()
        let after = try image(paint: [
            CGRect(
                x     : 40,
                y     : 40,
                width : 4,
                height: 4
            ),
            CGRect(
                x     : 2,
                y     : 5,
                width : 1,
                height: 65
            ),
            CGRect(
                x     : 70,
                y     : 5,
                width : 1,
                height: 65
            ),
            CGRect(
                x     : 3,
                y     : 4,
                width : 67,
                height: 1
            ),
            CGRect(
                x     : 3,
                y     : 70,
                width : 67,
                height: 1
            ),
        ])
        let changes = try #require(RegionTileDiff.changes(
            from   : before,
            to     : after,
            regions: [region]
        ))
        #expect(changes[0].indices == [4])
        #expect(changes[0].rects == [CGRect(
            x     : 35,
            y     : 37,
            width : 32,
            height: 32
        )])
    }

    @Test
    func outsideAndIdenticalFramesAreClean() throws {
        let before = try image()
        let after = try image(paint: [CGRect(
            x     : 90,
            y     : 90,
            width : 5,
            height: 5
        )])
        for candidate in [before, after] {
            let changes = try #require(RegionTileDiff.changes(
                from   : before,
                to     : candidate,
                regions: [CGRect(
                    x     : 3,
                    y     : 5,
                    width : 67,
                    height: 65
                )]
            ))
            #expect(changes[0].indices.isEmpty)
            #expect(changes[0].cropRects.isEmpty)
        }
    }

    @Test
    func masksAreIndependentPerRegion() throws {
        let regions = [
            CGRect(
                x     : 3,
                y     : 5,
                width : 67,
                height: 65
            ),
            CGRect(
                x     : 80,
                y     : 8,
                width : 35,
                height: 40
            ),
        ]
        let before = try image()
        let after = try image(paint: [
            CGRect(
                x     : 40,
                y     : 40,
                width : 4,
                height: 4
            ),
            CGRect(
                x     : 113,
                y     : 41,
                width : 2,
                height: 4
            ),
        ])
        let unmasked = try #require(RegionTileDiff.changes(
            from   : before,
            to     : after,
            regions: regions
        ))
        #expect(unmasked[0].indices == [4])
        #expect(unmasked[1].indices == [3])
        #expect(unmasked[1].rects == [CGRect(
            x     : 112,
            y     : 40,
            width : 3,
            height: 8
        )])
        let masked = try #require(RegionTileDiff.changes(
            from    : before,
            to      : after,
            regions : regions,
            ignoring: [[4], []]
        ))
        #expect(masked[0].rects.isEmpty)
        #expect(masked[1] == unmasked[1])
    }

    @Test
    func exposesStableAddressesAndMergesTouchingTiles() throws {
        let region = CGRect(
            x     : 3,
            y     : 5,
            width : 67,
            height: 65
        )
        let before = try image()
        let after = try image(paint: [CGRect(
            x     : 3,
            y     : 5,
            width : 64,
            height: 4
        )])
        let frame = try #require(RegionTileDiff.frame(
            before,
            regions: [region]
        ))
        #expect(frame.grids[0].cols == 3)
        #expect(frame.grids[0].rows == 3)
        #expect(frame.grids[0].rect(at: 8) == CGRect(
            x     : 67,
            y     : 69,
            width : 3,
            height: 1
        ))
        #expect(frame.grids[0].rect(at: -1) == nil)
        #expect(frame.grids[0].rect(at: 9) == nil)
        let next = try #require(RegionTileDiff.frame(
            after,
            regions: [region]
        ))
        let changes = try #require(RegionTileDiff.changes(
            from: frame,
            to  : next
        ))
        #expect(changes[0].indices == [0, 1])
        #expect(changes[0].cropRects == [CGRect(
            x     : 3,
            y     : 5,
            width : 64,
            height: 32
        )])
    }

    @Test
    func rejectsMismatchedSizesAndConfiguration() throws {
        let original = try image()
        let larger = try image(width: 129)
        let region = CGRect(
            x     : 3,
            y     : 5,
            width : 67,
            height: 65
        )
        #expect(RegionTileDiff.changes(
            from   : original,
            to     : larger,
            regions: [region]
        ) == nil)
        let frame = try #require(RegionTileDiff.frame(
            original,
            regions: [region]
        ))
        for candidate in [
            RegionTileDiff.frame(original, regions: [CGRect(
                x     : 3,
                y     : 5,
                width : 66,
                height: 65
            )]),
            RegionTileDiff.frame(
                original,
                regions  : [region],
                downscale: 2
            ),
            RegionTileDiff.frame(
                original,
                regions: [region],
                tile   : 4
            ),
            RegionTileDiff.frame(
                original,
                regions: []
            ),
        ] {
            let other = try #require(candidate)
            #expect(RegionTileDiff.changes(
                from: frame,
                to  : other
            ) == nil)
        }
        #expect(RegionTileDiff.changes(
            from    : frame,
            to      : frame,
            ignoring: [[], []]
        ) == nil)
    }

    @Test
    func supportsCustomScaleAndMovedRegion() throws {
        let before = try image()
        let after = try image(paint: [CGRect(
            x     : 16,
            y     : 18,
            width : 2,
            height: 2
        )])
        let first = try #require(RegionTileDiff.frame(
            before,
            regions  : [CGRect(
                x     : 3,
                y     : 5,
                width : 19,
                height: 17
            )],
            downscale: 2,
            tile     : 3
        ))
        let second = try #require(RegionTileDiff.frame(
            after,
            regions  : [CGRect(
                x     : 9,
                y     : 11,
                width : 19,
                height: 17
            )],
            downscale: 2,
            tile     : 3
        ))
        let changes = try #require(RegionTileDiff.changes(
            from: first,
            to  : second
        ))
        #expect(changes[0].rects == [CGRect(
            x     : 15,
            y     : 17,
            width : 6,
            height: 6
        )])
    }

    @Test
    func rejectsInvalidRegionsAndParameters() throws {
        let source = try image()
        for region in [
            CGRect.zero,
            CGRect(
                x     : -1,
                y     : 0,
                width : 10,
                height: 10
            ),
            CGRect(
                x     : 0.5,
                y     : 0,
                width : 10,
                height: 10
            ),
            CGRect(
                x     : 120,
                y     : 120,
                width : 10,
                height: 10
            ),
            CGRect.infinite,
            CGRect.null,
        ] {
            #expect(RegionTileDiff.frame(
                source,
                regions: [region]
            ) == nil)
        }
        for value in [0, -1, Int.max] {
            #expect(RegionTileDiff.frame(
                source,
                regions  : [],
                downscale: value
            ) == nil)
            #expect(RegionTileDiff.frame(
                source,
                regions: [],
                tile   : value
            ) == nil)
        }
        #expect(RegionTileDiff.frame(
            source,
            regions: []
        )?.grids.isEmpty == true)
    }

    @Test(.enabled(if: getenv("BRAUS_REGION_TILE_BENCH") != nil))
    func benchmarkTwoRetinaRegions() throws {
        let before = try image(
            width : 2522,
            height: 1654
        )
        let after = try image(
            width : 2522,
            height: 1654,
            paint : [CGRect(
                x     : 300,
                y     : 400,
                width : 12,
                height: 12
            )]
        )
        let regions = [
            CGRect(
                x     : 3,
                y     : 5,
                width : 1257,
                height: 1645
            ),
            CGRect(
                x     : 1263,
                y     : 5,
                width : 1255,
                height: 1645
            ),
        ]
        var samples: [Double] = []
        var dirtyCount = 0
        for iteration in 0..<220 {
            let start = ContinuousClock.now
            let result = try #require(RegionTileDiff.changes(
                from   : before,
                to     : after,
                regions: regions
            ))
            let elapsed = start.duration(to: .now).components
            if iteration >= 20 {
                samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
            }
            dirtyCount += result.reduce(0) { $0 + $1.indices.count }
        }
        #expect(dirtyCount > 0)
        samples.sort()
        let median = (samples[99] + samples[100]) / 2
        print("REGION_TILE_BENCH median_ms=\(median) samples=200 warmup=20 dirty_count=\(dirtyCount)")
    }

    @Test
    func keepsUnchangedSecondRegionClean() throws {
        let before = try image()
        let after = try image(paint: [CGRect(
            x     : 10,
            y     : 10,
            width : 4,
            height: 4
        )])
        let changes = try #require(RegionTileDiff.changes(
            from   : before,
            to     : after,
            regions: [
                CGRect(
                    x     : 3,
                    y     : 5,
                    width : 67,
                    height: 65
                ),
                CGRect(
                    x     : 80,
                    y     : 8,
                    width : 35,
                    height: 40
                ),
            ]
        ))
        #expect(changes[0].indices == [0])
        #expect(changes[1].indices.isEmpty)
    }

    @Test
    func normalizesOtherPixelFormats() throws {
        let paint = [
            CGRect(
                x     : 40,
                y     : 40,
                width : 4,
                height: 4
            ),
            CGRect(
                x     : 68,
                y     : 69,
                width : 2,
                height: 1
            ),
        ]
        let rgba = try image(paint: paint)
        for order in [CGBitmapInfo.byteOrder32Little, .byteOrder32Big] {
            let other = try image(
                paint     : paint,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | order.rawValue
            )
            let changes = try #require(RegionTileDiff.changes(
                from   : rgba,
                to     : other,
                regions: [CGRect(
                    x     : 3,
                    y     : 5,
                    width : 67,
                    height: 65
                )]
            ))
            #expect(changes[0].indices.isEmpty)
        }
    }

    @Test
    func croppedImagesUseLogicalPixelOrigin() throws {
        let sourceBefore = try image()
        let sourceAfter = try image(paint: [CGRect(
            x     : 40,
            y     : 40,
            width : 4,
            height: 4
        )])
        let crop = CGRect(
            x     : 3,
            y     : 5,
            width : 67,
            height: 65
        )
        let before = try #require(sourceBefore.cropping(to: crop))
        let after = try #require(sourceAfter.cropping(to: crop))
        let changes = try #require(RegionTileDiff.changes(
            from   : before,
            to     : after,
            regions: [CGRect(
                x     : 1,
                y     : 1,
                width : 65,
                height: 63
            )]
        ))
        #expect(changes[0].indices == [4])
        #expect(changes[0].rects == [CGRect(
            x     : 33,
            y     : 33,
            width : 32,
            height: 31
        )])
    }

    @Test
    func fullResolutionFindsSinglePixelChange() throws {
        let before = try image()
        let after = try image(paint: [CGRect(
            x     : 40,
            y     : 40,
            width : 1,
            height: 1
        )])
        let changes = try #require(RegionTileDiff.changes(
            from     : before,
            to       : after,
            regions  : [CGRect(
                x     : 3,
                y     : 5,
                width : 67,
                height: 65
            )],
            downscale: 1
        ))
        #expect(changes[0].indices == [40])
        #expect(changes[0].rects == [CGRect(
            x     : 35,
            y     : 37,
            width : 8,
            height: 8
        )])
    }

    private func image(
        width : Int      = 128,
        height: Int      = 128,
        paint     : [CGRect] = [],
        bitmapInfo: UInt32   = CGImageAlphaInfo.premultipliedLast.rawValue
    ) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data            : nil,
            width           : width,
            height          : height,
            bitsPerComponent: 8,
            bytesPerRow     : 0,
            space           : space,
            bitmapInfo      : bitmapInfo
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
            srgbRed: 1,
            green  : 0,
            blue   : 0.25,
            alpha  : 1
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
