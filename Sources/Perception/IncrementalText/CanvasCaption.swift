//
//  CanvasCaption.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore

/// CanvasCaption names what the scene reads beside a canvas, in the pixel coordinates of a crop of
/// it, so a model can tell which row and which time a changed area is at.
///
/// Only texts the scene already holds appear, nothing inferred: the labels left of the canvas whose
/// middle falls within its height, with their vertical ranges (row names, track headers); the labels
/// just above it whose middle falls within its width, with their horizontal ranges (a ruler, column
/// names); and its heading, which is its accessibility container or panel, else a single label above
/// it. A range may fall outside the crop: that row or mark is beside the part shown. Editable fields
/// are left out, since their text is a person's value, not a name.
///
/// A label left of the canvas inside a named group that is one of its rows stands for that group: the
/// row is the group's name over the span of all its elements (a track header holds a dozen controls,
/// and the track's name is what tells the row). A group is a row when its span's middle falls within
/// the canvas height and the span is under half of it, so a wrapper around every row never is; of a
/// label's nested groups the outermost row wins.
public enum CanvasCaption {

    /// How far left of the canvas, in points, a row label may end.
    public static let rowReach: CGFloat = 240
    /// How far above the canvas, in points, a ruler label may end.
    public static let rulerReach: CGFloat = 40

    /// The caption of `crop`, a crop of `canvas` in `scene`, whose window is `windowSize` points.
    public static func text(
        of canvas : SceneElement,
        crop      : CanvasCrop.Layout,
        in scene  : SceneSnapshot,
        windowSize: CGSize
    ) -> String {
        let frame = canvas.bounds.pixelBox(in: windowSize)
        let scale = crop.pixelsPerPoint
        let names = scene.elements.compactMap { element -> (label: String, frame: CGRect, container: String?)? in
            guard element.kind == .text || element.kind == .control, !element.isUnlabeled,
                  !element.label.isEmpty,
                  !CanvasPrivacy.editableRoles.contains(element.role ?? "") else { return nil }
            return (element.label, element.bounds.pixelBox(in: windowSize), element.container)
        }
        let groups = groupRows(beside: frame, in: scene, windowSize: windowSize)
        let labelRows = names.filter {
            $0.frame.maxX <= frame.minX + 4 && frame.minX - $0.frame.maxX <= rowReach
                && (frame.minY...frame.maxY).contains($0.frame.midY)
                && $0.container.flatMap(groups.owner) == nil
        }.map { (label: $0.label, frame: $0.frame) }
        let rows = (labelRows + groups.rows).sorted { $0.frame.minY < $1.frame.minY }
        let above = names.filter {
            $0.frame.maxY <= frame.minY + 4 && frame.minY - $0.frame.maxY <= rulerReach
                && (frame.minX...frame.maxX).contains($0.frame.midX)
        }.sorted { $0.frame.minX < $1.frame.minX }
        // One label above is a title; several in a band are a ruler.
        let ruler   = above.count > 1 ? above : []
        let heading = canvas.container ?? canvas.section ?? (above.count == 1 ? above[0].label : nil)

        func span(_ low: CGFloat, _ high: CGFloat, from origin: CGFloat) -> String {
            "\(Int(((low - origin) * scale).rounded()))..\(Int(((high - origin) * scale).rounded()))"
        }
        var lines = [
            "\(canvas.label): crop \(crop.pixelWidth)x\(crop.pixelHeight) px of window points "
                + "\(Int(crop.rect.minX)),\(Int(crop.rect.minY)) \(Int(crop.rect.width))x\(Int(crop.rect.height)), "
                + "\(number(scale)) px per point"
        ]
        if !rows.isEmpty {
            lines.append("rows (y px): " + rows.map {
                String(reflecting: $0.label) + " " + span($0.frame.minY, $0.frame.maxY, from: crop.rect.minY)
            }.joined(separator: ", "))
        }
        if !ruler.isEmpty {
            lines.append("above (x px): " + ruler.map {
                String(reflecting: $0.label) + " " + span($0.frame.minX, $0.frame.maxX, from: crop.rect.minX)
            }.joined(separator: ", "))
        }
        if let heading { lines.append("heading: " + String(reflecting: heading)) }
        return lines.joined(separator: "\n")
    }

    /// The named groups that are rows of `canvas` (window points), and for a container path the row
    /// group it lies in. A group's span covers every element of the scene inside it, at any depth; only
    /// groups holding an element within `rowReach` left of the canvas are considered.
    private static func groupRows(
        beside canvas: CGRect,
        in scene     : SceneSnapshot,
        windowSize   : CGSize
    ) -> (rows: [(label: String, frame: CGRect)], owner: (String) -> String?) {
        func prefixes(_ container: String) -> [String] {
            let parts = container.components(separatedBy: " / ")
            return parts.indices.map { parts[...$0].joined(separator: " / ") }
        }
        var spans: [String: CGRect] = [:]
        var beside: Set<String> = []
        for element in scene.elements where element.kind != .canvas {
            guard let container = element.container else { continue }
            let box = element.bounds.pixelBox(in: windowSize)
            let isBeside = box.maxX <= canvas.minX + 4 && canvas.minX - box.maxX <= rowReach
            for prefix in prefixes(container) {
                spans[prefix] = spans[prefix].map { $0.union(box) } ?? box
                if isBeside { beside.insert(prefix) }
            }
        }
        let rowGroups = beside.filter { prefix in
            guard let span = spans[prefix] else { return false }
            return span.height < canvas.height / 2 && (canvas.minY...canvas.maxY).contains(span.midY)
        }
        func owner(_ container: String) -> String? { prefixes(container).first(where: rowGroups.contains) }
        // A row group nested in another row group is part of that row, not a row of its own.
        let rows = rowGroups.filter { owner($0) == $0 }.compactMap { prefix -> (label: String, frame: CGRect)? in
            guard let span = spans[prefix], let name = prefix.components(separatedBy: " / ").last
            else { return nil }
            return (name, span)
        }
        return (rows, owner)
    }

    /// Two decimals at most, without trailing zeros.
    private static func number(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
