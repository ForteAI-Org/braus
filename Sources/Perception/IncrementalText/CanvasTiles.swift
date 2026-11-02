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
/// a tile hash differs, when its region changed size, or when the two captures differ in size, since
/// equal pixels cannot be proved then. A canvas the previous observation did not hold stays unmarked.
/// The caller keeps one value per window: another window's hashes describe unrelated pixels.
public struct CanvasTiles: Sendable {

    private let ids  : [String]
    private let frame: RegionTileDiff.Frame

    /// Hashes the canvases of `scene` in `image`, the picture the scene was read from, and marks each
    /// canvas's `hasChangedPixels` against `previous`. Answers the hashes to pass as `previous` next
    /// time; nil when the scene has no canvas or its regions cannot be hashed, and then nothing is marked.
    public static func mark(
        _ scene : inout SceneSnapshot,
        in image: CGImage,
        since previous: CanvasTiles?
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
        if let previous {
            for (position, index) in indices.enumerated() {
                guard let old = previous.ids.firstIndex(of: ids[position]) else { continue }
                scene.elements[index].hasChangedPixels = changed(
                    from: previous.frame,
                    at  : old,
                    to  : frame,
                    at  : position
                )
            }
        }
        return CanvasTiles(
            ids  : ids,
            frame: frame
        )
    }

    /// Compares one region of each frame alone, so a canvas that changed size elsewhere in the window
    /// does not hide the answer for this one. A comparison the frames refuse is a change.
    private static func changed(
        from old     : RegionTileDiff.Frame,
        at oldIndex  : Int,
        to new       : RegionTileDiff.Frame,
        at newIndex  : Int
    ) -> Bool {
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
            from: single(old, oldIndex),
            to  : single(new, newIndex)
        ) else { return true }
        return changes.contains { !$0.indices.isEmpty }
    }
}
