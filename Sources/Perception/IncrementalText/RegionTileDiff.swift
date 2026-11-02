//
//  RegionTileDiff.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import Accelerate
import CoreFoundation
import CoreGraphics

/// RegionTileDiff compares fine tiles on independently downscaled image regions.
/// Coordinates use image pixels with a top-left origin. Region order supplies identity.
/// Fixed nearest-neighbor samples can discard detail smaller than `downscale` pixels;
/// use a downscale of 1 when every source pixel must contribute.
public enum RegionTileDiff {

    /// Frame retains region hashes, not images, and can be reused for the next comparison.
    public struct Frame: Sendable, Equatable {
        public let width    : Int
        public let height   : Int
        public let downscale: Int
        public let tile     : Int
        public let grids    : [Grid]
    }

    /// Grid addresses tiles by `row * cols + column`, relative to its region's origin.
    /// Indices remain stable for the same region size, downscale and tile, even after a move.
    public struct Grid: Sendable, Equatable {
        public let region: CGRect
        public let cols  : Int
        public let rows  : Int
        public let hashes: [UInt64]
        private let span : Int

        fileprivate init(
            region: CGRect,
            grid  : TileGrid,
            span  : Int
        ) {
            self.region = region
            self.cols   = grid.cols
            self.rows   = grid.rows
            self.hashes = grid.hashes
            self.span   = span
        }

        /// Maps a row-major index to image pixels, clipping the final row and column.
        public func rect(at index: Int) -> CGRect? {
            guard hashes.indices.contains(index) else { return nil }
            let x = (index % cols) * span
            let y = (index / cols) * span
            return CGRect(
                x     : region.minX + CGFloat(x),
                y     : region.minY + CGFloat(y),
                width : min(
                    CGFloat(span),
                    region.width - CGFloat(x)
                ),
                height: min(
                    CGFloat(span),
                    region.height - CGFloat(y)
                )
            )
        }
    }

    /// Change contains unmasked dirty tiles for one region, including empty results.
    public struct Change: Sendable, Equatable {
        public let region : CGRect
        public let indices: [Int]
        public let rects  : [CGRect]

        /// Unions touching tiles into crop bounds using the existing OCR coalescing policy.
        /// A bounding union can include clean pixels between connected changed tiles.
        public var cropRects: [CGRect] { TileDiff.coalesce(rects) }
    }

    /// Hashes only the specified regions on copies reduced by `downscale` in each dimension.
    /// Regions must be nonempty integral pixel rectangles fully inside the image. Returns nil
    /// for invalid geometry/configuration or a render failure. Defaults yield 32-pixel tiles.
    public static func frame(
        _ image  : CGImage,
        regions  : [CGRect],
        downscale: Int = 4,
        tile     : Int = 8
    ) -> Frame? {
        let (span, overflow) = downscale.multipliedReportingOverflow(by: tile)
        guard downscale > 0, tile > 0, !overflow, span <= Int.max / 4 else { return nil }
        let bounds = CGRect(
            x     : 0,
            y     : 0,
            width : image.width,
            height: image.height
        )
        guard regions.allSatisfy({ region in
            !region.isEmpty && !region.isNull && !region.isInfinite &&
            region == region.integral && bounds.contains(region)
        }) else { return nil }
        var grids: [Grid] = []
        grids.reserveCapacity(regions.count)
        for region in regions {
            let width  = (Int(region.width) - 1) / downscale + 1
            let height = (Int(region.height) - 1) / downscale + 1
            guard let rgba = render(
                image,
                region   : region,
                width    : width,
                height   : height,
                downscale: downscale
            ) else { return nil }
            let grid = TileDiff.grid(
                rgba  : rgba,
                width : width,
                height: height,
                tile  : tile
            )
            grids.append(Grid(
                region: region,
                grid  : grid,
                span  : span
            ))
        }
        return Frame(
            width    : image.width,
            height   : image.height,
            downscale: downscale,
            tile     : tile,
            grids    : grids
        )
    }

    /// Compares corresponding regions and applies row-major masks independently per region.
    /// An empty mask array means no masks; otherwise its count must match the region count.
    /// Out-of-range mask indices do nothing. Masks must be reset after size/configuration changes.
    /// Returns nil for image, region-size, region-count or configuration mismatch. A moved region
    /// is compared relative to its origin; rectangles refer to the new frame.
    public static func changes(
        from old: Frame,
        to new  : Frame,
        ignoring: [Set<Int>] = []
    ) -> [Change]? {
        guard old.width == new.width, old.height == new.height,
              old.downscale == new.downscale, old.tile == new.tile,
              old.grids.count == new.grids.count,
              ignoring.isEmpty || ignoring.count == new.grids.count,
              zip(
                  old.grids,
                  new.grids
              ).allSatisfy({ $0.region.size == $1.region.size }) else { return nil }
        var changes: [Change] = []
        changes.reserveCapacity(new.grids.count)
        for regionIndex in new.grids.indices {
            let previous = old.grids[regionIndex]
            let current  = new.grids[regionIndex]
            let mask     = ignoring.isEmpty ? [] : ignoring[regionIndex]
            var indices: [Int] = []
            var rects  : [CGRect] = []
            for index in current.hashes.indices where
                current.hashes[index] != previous.hashes[index] && !mask.contains(index) {
                guard let rect = current.rect(at: index) else { return nil }
                indices.append(index)
                rects.append(rect)
            }
            changes.append(Change(
                region : current.region,
                indices: indices,
                rects  : rects
            ))
        }
        return changes
    }

    /// Compares two images using the same ordered regions, including both downscales and hashes.
    /// Use separate frames to detect resized/moved regions or retain hashes between actions.
    public static func changes(
        from old : CGImage,
        to new   : CGImage,
        regions  : [CGRect],
        ignoring : [Set<Int>] = [],
        downscale: Int        = 4,
        tile     : Int        = 8
    ) -> [Change]? {
        guard old.width == new.width, old.height == new.height,
              let previous = frame(
                  old,
                  regions  : regions,
                  downscale: downscale,
                  tile     : tile
              ),
              let current = frame(
                  new,
                  regions  : regions,
                  downscale: downscale,
                  tile     : tile
              ) else { return nil }
        return changes(
            from    : previous,
            to      : current,
            ignoring: ignoring
        )
    }

    /// Samples the center of each fixed pixel block, including partial edges.
    /// Native sRGB RGBA8/BGRA8 providers avoid rendering; other formats normalize just the requested region.
    private static func render(
        _ image  : CGImage,
        region   : CGRect,
        width    : Int,
        height   : Int,
        downscale: Int
    ) -> [UInt8]? {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow)   = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow else { return nil }
        let sourceWidth  = Int(region.width)
        let sourceHeight = Int(region.height)
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let isRGBA = image.alphaInfo == .premultipliedLast &&
                     (order == .byteOrderDefault || order == .byteOrder32Big)
        let isBGRA = image.alphaInfo == .premultipliedFirst && order == .byteOrder32Little
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           isRGBA || isBGRA, image.decode == nil,
           image.colorSpace?.name == CGColorSpace.sRGB,
           let data = image.dataProvider?.data,
           CFDataGetLength(data) / image.bytesPerRow >= image.height,
           let base = CFDataGetBytePtr(data) {
            let offset = Int(region.minY) * image.bytesPerRow + Int(region.minX) * 4
            var rgba = sample(
                base        : base + offset,
                rowStride   : image.bytesPerRow,
                width       : sourceWidth,
                height      : sourceHeight,
                downscale   : downscale,
                byteCount   : bytes
            )
            if isBGRA {
                let permuted = rgba.withUnsafeMutableBytes { bytes in
                    var buffer = vImage_Buffer(
                        data    : bytes.baseAddress,
                        height  : vImagePixelCount(height),
                        width   : vImagePixelCount(width),
                        rowBytes: width * 4
                    )
                    var destination = buffer
                    let map: [UInt8] = [2, 1, 0, 3]
                    return vImagePermuteChannels_ARGB8888(
                        &buffer,
                        &destination,
                        map,
                        vImage_Flags(kvImageDoNotTile)
                    ) == kvImageNoError
                }
                guard permuted else { return nil }
            }
            return rgba
        }
        let (sourcePixels, sourceOverflow) = sourceWidth.multipliedReportingOverflow(by: sourceHeight)
        let (sourceBytes, bytesOverflow)   = sourcePixels.multipliedReportingOverflow(by: 4)
        guard !sourceOverflow, !bytesOverflow,
              let crop = image.cropping(to: region),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: sourceBytes)
        return rgba.withUnsafeMutableBytes { buffer in
            guard let raw = buffer.baseAddress,
                  let context = CGContext(
                      data            : raw,
                      width           : sourceWidth,
                      height          : sourceHeight,
                      bitsPerComponent: 8,
                      bytesPerRow     : sourceWidth * 4,
                      space           : space,
                      bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            context.setBlendMode(.copy)
            context.draw(
                crop,
                in: CGRect(
                    x     : 0,
                    y     : 0,
                    width : sourceWidth,
                    height: sourceHeight
                )
            )
            return sample(
                base     : raw.assumingMemoryBound(to: UInt8.self),
                rowStride: sourceWidth * 4,
                width    : sourceWidth,
                height   : sourceHeight,
                downscale: downscale,
                byteCount: bytes
            )
        }
    }

    /// Uses nearest-neighbor reduction, avoiding interpolation bleed and averaging cost.
    private static func sample(
        base        : UnsafePointer<UInt8>,
        rowStride   : Int,
        width       : Int,
        height      : Int,
        downscale   : Int,
        byteCount   : Int
    ) -> [UInt8] {
        let columns = (width - 1) / downscale + 1
        let rows    = (height - 1) / downscale + 1
        let fullColumns = width / downscale
        let sourceStep  = downscale * 4
        let centerX     = min(
            downscale,
            width
        ) / 2 * 4
        var output = [UInt8](repeating: 0, count: byteCount)
        output.withUnsafeMutableBytes { buffer in
            guard var destination = buffer.baseAddress else { return }
            for y in 0..<rows {
                let y0 = y * downscale
                let sourceY = y0 + min(
                    downscale,
                    height - y0
                ) / 2
                let row = UnsafeRawPointer(base + sourceY * rowStride)
                var source = row + centerX
                for _ in 0..<fullColumns {
                    let pixel = source.loadUnaligned(as: UInt32.self)
                    destination.storeBytes(
                        of: pixel,
                        as: UInt32.self
                    )
                    source += sourceStep
                    destination += 4
                }
                if fullColumns < columns {
                    let x0 = fullColumns * downscale
                    let sourceX = x0 + (width - x0) / 2
                    let pixel = row.loadUnaligned(
                        fromByteOffset: sourceX * 4,
                        as            : UInt32.self
                    )
                    destination.storeBytes(
                        of: pixel,
                        as: UInt32.self
                    )
                    destination += 4
                }
            }
        }
        return output
    }
}
