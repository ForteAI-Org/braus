//
//  CanvasNoise.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics

/// CanvasNoise learns which tiles of one canvas region change by themselves (a level meter, a playhead,
/// a blinking caret), so `RegionTileDiff.changes(from:to:ignoring:)` reports what an action changed.
///
/// Rule: only an idle comparison teaches, that is two successive frames with no input between them.
/// A tile becomes noise once it changed in `learnAfter` idle comparisons. A tile that changed, learned
/// or not, is forgotten after `forgetAfter` idle comparisons in which it did not change, so a meter that
/// stops is shown again. A comparison with input between its frames only moves the baseline: it neither
/// teaches nor counts toward forgetting. A different region size, downscale or tile, or a missing region,
/// discards everything learned and starts over from that frame. When noise covers more than
/// `maxCoverage` of the region's tiles the region is always changing (a video, say): `mask` is empty and
/// `isAlwaysChanging` tells that state apart from a region without noise.
///
/// A tile changes as `RegionTileDiff.changes` says, beyond its colour tolerance, so a capture's jitter of
/// a level teaches nothing. The value retains the region's last grid, its hashes and reduced pixels, and
/// counters. One update is O(tiles) once the region's size is stable. Keep one value per region and pass `noises.map(\.mask)`.
public struct CanvasNoise: Sendable, Equatable {

    /// Idle comparisons with a change that make a tile noise.
    public static let learnAfter = 2
    /// Idle comparisons without a change that forget a tile.
    public static let forgetAfter = 30
    /// Fraction of the region's tiles above which the mask is withheld.
    public static let maxCoverage = 0.5

    private struct Key: Sendable, Equatable {
        let width    : Int
        let height   : Int
        let downscale: Int
        let tile     : Int
    }

    private var key   : Key?
    /// The region's grid in the frame before, which each tile is compared with.
    private var grid  : RegionTileDiff.Grid?
    private var hashes: [UInt64] { grid?.hashes ?? [] }
    /// Idle comparisons in which each tile changed, capped at `learnAfter`.
    private var hits  : [Int]    = []
    /// Idle comparisons since each tile with hits last changed.
    private var quiet : [Int]    = []

    /// Learned tiles, row-major as in `RegionTileDiff.Grid`, whether or not the mask applies.
    public private(set) var noise: Set<Int> = []

    public init() {}

    /// True when noise covers more than `maxCoverage` of the region, so no mask is applied.
    public var isAlwaysChanging: Bool {
        Double(noise.count) > Double(hashes.count) * Self.maxCoverage
    }

    /// Tiles to ignore for this region: the learned noise, or nothing while the region is always changing.
    public var mask: Set<Int> { isAlwaysChanging ? [] : noise }

    /// Compares region `region` of `frame` with the previous frame and learns from it when idle.
    /// `hadInput` says whether any input reached the application since the previous frame.
    public mutating func observe(
        _ frame : RegionTileDiff.Frame,
        region  : Int,
        hadInput: Bool
    ) {
        guard frame.grids.indices.contains(region) else {
            self = CanvasNoise()
            return
        }
        let grid = frame.grids[region]
        let next = Key(
            width    : Int(grid.region.width),
            height   : Int(grid.region.height),
            downscale: frame.downscale,
            tile     : frame.tile
        )
        guard next == key, let previous = self.grid, grid.hashes.count == previous.hashes.count else {
            self = CanvasNoise()
            key       = next
            self.grid = grid
            hits   = Array(
                repeating: 0,
                count    : grid.hashes.count
            )
            quiet  = hits
            return
        }
        defer { self.grid = grid }
        guard !hadInput else { return }
        for index in grid.hashes.indices {
            if grid.differs(from: previous, at: index, tolerance: RegionTileDiff.tolerance) {
                quiet[index] = 0
                guard hits[index] < Self.learnAfter else { continue }
                hits[index] += 1
                if hits[index] == Self.learnAfter {
                    noise.insert(index)
                }
            } else if hits[index] > 0 {
                quiet[index] += 1
                if quiet[index] >= Self.forgetAfter {
                    hits[index]  = 0
                    quiet[index] = 0
                    noise.remove(index)
                }
            }
        }
    }
}
