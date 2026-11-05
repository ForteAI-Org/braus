//
//  UncoveredAreas.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics

/// UncoveredAreas finds the rectangles of a window's content that no accessibility element covers.
/// An application that draws its main view itself can leave it as a hole in the tree rather than as
/// an element: Pro Tools' playlist has no element at all, beside track groups that end where it begins.
///
/// The content (the window below its title bar, inside its rounded edge) is a grid of `cell`-point
/// cells; a cell any frame touches is covered, so a hole never takes in an element's edge. Among the
/// maximal uncovered rectangles at least `minimumThickness` on both sides and `minimumShare` of the
/// window, the largest are taken first and one that overlaps a rectangle already taken is skipped. A
/// long strip therefore stays one rectangle, and an L-shaped hole is its larger bar.
/// Geometry only: whether a hole shows anything is decided where its pixels are (`ScenePipeline`).
///
/// Cost: one pass over the frames and one over the cells (a 1515x923 window is 22k cells).
package enum UncoveredAreas {

    /// The side of a grid cell, in points: the precision of a hole's edges.
    package static let cell: CGFloat = 8
    /// The window's top band left out: the title bar, which shows no content.
    static let titleBarHeight: CGFloat = 28
    /// The band left out along the other edges: a capture shows the rounded corners transparent, which
    /// would pass for structure in a margin. 8 points clear a corner radius up to 27.
    static let edgeInset: CGFloat = 8
    /// The thinnest hole, in points: below it an uncovered area is a margin or a gap between controls.
    static let minimumThickness: CGFloat = 40
    /// The smallest hole as a share of the window's area.
    static let minimumShare = 0.05

    /// The holes of `window` that none of `frames` (global points, already clipped to what is visible)
    /// covers, at most `limit`, ordered top to bottom and then left to right so their order holds while
    /// the layout does. None when the largest hole exceeds `maximumShare` of the window: a tree that
    /// covers almost nothing does not describe the window, so nothing in it is a hole.
    static func areas(
        in window   : CGRect,
        covered     : [CGRect],
        limit       : Int,
        maximumShare: Double
    ) -> [CGRect] {
        let content = CGRect(
            x     : window.minX + edgeInset,
            y     : window.minY + titleBarHeight,
            width : window.width - 2 * edgeInset,
            height: window.height - titleBarHeight - edgeInset
        )
        guard limit > 0, content.width >= minimumThickness, content.height >= minimumThickness else { return [] }
        let columns = Int((content.width / cell).rounded(.up))
        let rows    = Int((content.height / cell).rounded(.up))
        let stride  = columns + 1
        // A 2D difference array: each frame costs four writes whatever its size, one prefix pass sums them.
        var counts = [Int32](repeating: 0, count: (rows + 1) * stride)
        for frame in covered {
            let visible = frame.intersection(content)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
            let left   = max(0, Int(((visible.minX - content.minX) / cell).rounded(.down)))
            let right  = min(columns, Int(((visible.maxX - content.minX) / cell).rounded(.up)))
            let top    = max(0, Int(((visible.minY - content.minY) / cell).rounded(.down)))
            let bottom = min(rows, Int(((visible.maxY - content.minY) / cell).rounded(.up)))
            guard left < right, top < bottom else { continue }
            counts[top * stride + left]     += 1
            counts[top * stride + right]    -= 1
            counts[bottom * stride + left]  -= 1
            counts[bottom * stride + right] += 1
        }

        let windowArea = Double(window.width * window.height)
        let candidates = counts.withUnsafeMutableBufferPointer { counts in
            freeRectangles(
                counts,
                rows        : rows,
                columns     : columns,
                minimumSide : Int((minimumThickness / cell).rounded(.up)),
                minimumCells: Int((minimumShare * windowArea / Double(cell * cell)).rounded(.up))
            )
        }.sorted { ($1.width * $1.height, $0.top, $0.left) < ($0.width * $0.height, $1.top, $1.left) }

        var taken: [(top: Int, left: Int, width: Int, height: Int)] = []
        var found: [CGRect] = []
        for candidate in candidates where found.count < limit {
            guard !taken.contains(where: {
                candidate.left < $0.left + $0.width && $0.left < candidate.left + candidate.width
                    && candidate.top < $0.top + $0.height && $0.top < candidate.top + candidate.height
            }) else { continue }
            taken.append(candidate)
            let rect = CGRect(
                x     : content.minX + CGFloat(candidate.left) * cell,
                y     : content.minY + CGFloat(candidate.top) * cell,
                width : CGFloat(candidate.width) * cell,
                height: CGFloat(candidate.height) * cell
            ).intersection(content)
            let area = Double(rect.width * rect.height)
            guard area <= maximumShare * windowArea else { return [] }
            // A last cell cut by the window's edge can leave a hole under a minimum: spent, not kept.
            guard area >= minimumShare * windowArea, rect.width >= minimumThickness,
                  rect.height >= minimumThickness else { continue }
            found.append(rect)
        }
        return found.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// The maximal rectangles of uncovered cells, out of the difference counts summed here in place,
    /// with both sides at least `minimumSide` and at least `minimumCells` cells. The histogram method
    /// meets every maximal rectangle; one is kept only when no free row lies under its whole width and
    /// no taller column continues it to the right, so each comes once and none of its parts does.
    /// Buffers, not arrays, keep a Debug build fast.
    private static func freeRectangles(
        _ counts    : UnsafeMutableBufferPointer<Int32>,
        rows        : Int,
        columns     : Int,
        minimumSide : Int,
        minimumCells: Int
    ) -> [(top: Int, left: Int, width: Int, height: Int)] {
        let stride = columns + 1
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * stride + column
                if row > 0 { counts[index] += counts[index - stride] }
                if column > 0 { counts[index] += counts[index - 1] }
                if row > 0, column > 0 { counts[index] -= counts[index - stride - 1] }
            }
        }
        var found: [(top: Int, left: Int, width: Int, height: Int)] = []
        var heights = [Int](repeating: 0, count: columns + 1)
        var stack   = [Int](repeating: 0, count: columns + 1)
        var below   = [Int](repeating: 0, count: columns + 1)
        heights.withUnsafeMutableBufferPointer { heights in
            stack.withUnsafeMutableBufferPointer { stack in
                below.withUnsafeMutableBufferPointer { below in
                    for row in 0..<rows {
                        let offset = row * stride
                        for column in 0..<columns {
                            heights[column] = counts[offset + column] == 0 ? heights[column] + 1 : 0
                            // Covered cells of the next row up to `column`; past the last row everything is.
                            let isCoveredBelow = row + 1 == rows || counts[offset + stride + column] != 0
                            below[column + 1] = below[column] + (isCoveredBelow ? 1 : 0)
                        }
                        // `heights[columns]` stays 0: it closes every bar still open at the row's end.
                        var depth = 0
                        for column in 0...columns {
                            let height = heights[column]
                            while depth > 0 {
                                let barHeight = heights[stack[depth - 1]]
                                guard barHeight >= height else { break }
                                depth -= 1
                                let left  = depth > 0 ? stack[depth - 1] + 1 : 0
                                let width = column - left
                                if barHeight > height, barHeight >= minimumSide, width >= minimumSide,
                                   barHeight * width >= minimumCells, below[column] > below[left] {
                                    found.append((row - barHeight + 1, left, width, barHeight))
                                }
                            }
                            stack[depth] = column
                            depth += 1
                        }
                    }
                }
            }
        }
        return found
    }
}
