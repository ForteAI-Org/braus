//
//  WebLayout.swift
//  Braus
//

import CoreGraphics
import Foundation
import WebDriver

/// WebLayout is where the main document's nodes are painted, in viewport CSS pixels, from one
/// `DOMSnapshot.captureSnapshot`, with the page's title and address.
///
/// Only the main document is read: a frame's boxes are relative to its own document, and its
/// nodes are not in the main frame's accessibility tree either.
public struct WebLayout: Sendable, Equatable {

    /// Each laid-out node's box by its backend node id. Where Chrome lays one node out more than
    /// once, the first box is kept.
    public var boxes   : [Int: CGRect]
    /// The layout viewport, the frame every box is relative to.
    public var viewport: CGSize
    public var title   : String
    public var url     : String

    public init(boxes: [Int: CGRect], viewport: CGSize, title: String = "", url: String = "") {
        self.boxes    = boxes
        self.viewport = viewport
        self.title    = title
        self.url      = url
    }

    /// Reads a snapshot, whose boxes are in document coordinates, and moves them by the document's
    /// scroll offset into the viewport. `metrics` is the `Page.getLayoutMetrics` answer.
    public init(snapshot: JSONValue, metrics: JSONValue) throws {
        guard let document = snapshot["documents"]?[0],
              let width    = metrics["cssLayoutViewport"]?["clientWidth"]?.doubleValue,
              let height   = metrics["cssLayoutViewport"]?["clientHeight"]?.doubleValue
        else { throw WebDrivingError.unreadablePage("no main document or viewport") }
        let strings  = (snapshot["strings"]?.arrayValue ?? []).map { $0.stringValue ?? "" }
        func string(_ index: JSONValue?) -> String {
            guard let index = index?.intValue, strings.indices.contains(index) else { return "" }
            return strings[index]
        }
        let backendIDs = (document["nodes"]?["backendNodeId"]?.arrayValue ?? []).map { $0.intValue ?? -1 }
        let indices    = document["layout"]?["nodeIndex"]?.arrayValue ?? []
        let bounds     = document["layout"]?["bounds"]?.arrayValue ?? []
        let scrollX    = document["scrollOffsetX"]?.doubleValue ?? 0
        let scrollY    = document["scrollOffsetY"]?.doubleValue ?? 0
        var boxes: [Int: CGRect] = [:]
        for (index, box) in zip(indices, bounds) {
            guard let node = index.intValue, backendIDs.indices.contains(node),
                  let values = box.arrayValue?.compactMap(\.doubleValue), values.count == 4
            else { continue }
            let id = backendIDs[node]
            if boxes[id] == nil {
                boxes[id] = CGRect(x: values[0] - scrollX, y: values[1] - scrollY, width: values[2], height: values[3])
            }
        }
        self.init(
            boxes   : boxes,
            viewport: CGSize(width: width, height: height),
            title   : string(document["title"]),
            url     : string(document["documentURL"])
        )
    }
}
