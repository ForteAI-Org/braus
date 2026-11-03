//
//  CanvasTiles.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import PerceptionCore

/// CanvasTiles holds the tile hashes of one observation's canvases, by element id, so the next
/// observation of the same window can say which canvas changed without keeping any image.
///
/// A canvas is compared with the canvas of the same id in the previous observation. It changed when
/// an unmasked tile hash differs, when its region changed size, or when the two captures differ in
/// size, since equal pixels cannot be proved then. A canvas the previous observation did not hold
/// stays unmarked. The caller keeps one value per window: another window's hashes describe unrelated
/// pixels.
public struct CanvasTiles: Sendable {

    /// Canvas element ids, in the order of `frame.grids`.
    let ids  : [String]
    let frame: RegionTileDiff.Frame
    /// The changed tiles of each canvas compared with `previous`, in image pixels: the unmasked
    /// tiles, or the whole region when the comparison was refused. Empty for an unchanged canvas.
    let changedTiles: [String: [CGRect]]

    /// Hashes the canvases of `scene` in `image`, the picture the scene was read from, and marks each
    /// canvas's `hasChangedPixels` against `previous`, ignoring the tiles `masks` names for its id
    /// (row-major, as `CanvasNoise.mask`). Answers the hashes to pass as `previous` next time; nil
    /// when the scene has no canvas or its regions cannot be hashed, and then nothing is marked.
    public static func mark(
        _ scene : inout SceneSnapshot,
        in image: CGImage,
        since previous: CanvasTiles?,
        ignoring masks: [String: Set<Int>] = [:]
    ) -> CanvasTiles? {
        let size   = CGSize(width: image.width, height: image.height)
        let bounds = CGRect(origin: .zero, size: size)
        var indices: [Int]    = []
        var regions: [CGRect] = []
        for (index, element) in scene.elements.enumerated() where element.kind == .canvas {
            let region = element.bounds.pixelBox(in: size).integral.intersection(bounds)
            guard !region.isNull, !region.isEmpty else { continue }
            indices.append(index)
            regions.append(region)
        }
        // Default sampling (every 4th pixel, 32-pixel tiles) can miss a change thinner than
        // 4 pixels; a downscale of 2 catches it at about four times the cost (measured on the fixture).
        guard !regions.isEmpty, let frame = RegionTileDiff.frame(image, regions: regions) else { return nil }
        let ids = indices.map { scene.elements[$0].id }
        var changedTiles: [String: [CGRect]] = [:]
        if let previous {
            for (position, index) in indices.enumerated() {
                guard let old = previous.ids.firstIndex(of: ids[position]) else { continue }
                let tiles = changed(
                    from: previous.frame,
                    at  : old,
                    to  : frame,
                    at  : position,
                    mask: masks[ids[position]] ?? []
                )
                changedTiles[ids[position]] = tiles
                scene.elements[index].hasChangedPixels = !tiles.isEmpty
            }
        }
        return CanvasTiles(
            ids         : ids,
            frame       : frame,
            changedTiles: changedTiles
        )
    }

    /// Compares one region of each frame alone, so a canvas that changed size elsewhere in the window
    /// does not hide the answer for this one. A comparison the frames refuse is a change of the whole
    /// region.
    private static func changed(
        from old     : RegionTileDiff.Frame,
        at oldIndex  : Int,
        to new       : RegionTileDiff.Frame,
        at newIndex  : Int,
        mask         : Set<Int>
    ) -> [CGRect] {
        func single(_ frame: RegionTileDiff.Frame, _ index: Int) -> RegionTileDiff.Frame {
            RegionTileDiff.Frame(
                width    : frame.width,
                height   : frame.height,
                downscale: frame.downscale,
                tile     : frame.tile,
                grids    : [frame.grids[index]]
            )
        }
        guard let changes = RegionTileDiff.changes(
            from    : single(old, oldIndex),
            to      : single(new, newIndex),
            ignoring: [mask]
        ) else { return [new.grids[newIndex].region] }
        return changes.flatMap(\.rects)
    }
}
