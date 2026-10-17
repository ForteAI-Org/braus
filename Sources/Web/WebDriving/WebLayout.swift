//
//  WebLayout.swift
//  Braus
//

import CoreGraphics
import Foundation
import WebDriver

/// WebLayout is where the main document's nodes are painted, in viewport CSS pixels, from one
/// `DOMSnapshot.captureSnapshot`, with the page's title and address, and which nodes are secure
/// fields whose value is never read (`secureFieldIDs`).
///
/// Only the main document's boxes are read: a frame's boxes are relative to its own document, and its
/// nodes are not in the main frame's accessibility tree either. Secure fields are read from every
/// document, since the snapshot flattens shadow trees into theirs and lists each frame as one.
///
/// A box is where a node is laid out, not where it can be seen: a scroll container (`overflow` other than
/// `visible`, on either axis) hides what lies outside it. `clips` keeps, for each node such a container
/// clips, the part of the viewport it can be seen in at most (W09). It follows the containing block: an
/// absolutely positioned node escapes the containers between it and its nearest positioned ancestor, a
/// fixed one escapes them all, and `html` and `body` leave their overflow to the viewport. What it does
/// not read stays unclipped: transforms, `contain`, `clip-path`, and frames.
public struct WebLayout: Sendable, Equatable {

    /// The computed styles the snapshot is asked for, in this order, to read the clipping containers.
    public static let clippingStyles = ["overflow-x", "overflow-y", "position"]

    /// Each laid-out node's box by its backend node id. Where Chrome lays one node out more than
    /// once, the first box is kept.
    public var boxes   : [Int: CGRect]
    /// The part of the viewport each node clipped by a scroll container can be seen in at most, by its
    /// backend node id; absent for a node no container clips.
    public var clips   : [Int: CGRect]
    /// The layout viewport, the frame every box is relative to.
    public var viewport: CGSize
    public var title   : String
    public var url     : String
    /// The backend node ids of the inputs `WebSecureFields` names secure, by the DOM's own attributes and
    /// never by a label: their value stays out of every scene.
    public var secureFieldIDs: Set<Int>

    public init(
        boxes         : [Int: CGRect],
        clips         : [Int: CGRect] = [:],
        viewport      : CGSize,
        title         : String        = "",
        url           : String        = "",
        secureFieldIDs: Set<Int>      = []
    ) {
        self.boxes          = boxes
        self.clips          = clips
        self.viewport       = viewport
        self.title          = title
        self.url            = url
        self.secureFieldIDs = secureFieldIDs
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
        let styles     = document["layout"]?["styles"]?.arrayValue ?? []
        var boxes: [Int: CGRect] = [:]
        // The first box and the computed styles of each laid-out node, by its index in the document.
        var laidOut: [Int: (box: CGRect, styles: [String])] = [:]
        for (position, (index, box)) in zip(indices, bounds).enumerated() {
            guard let node = index.intValue, backendIDs.indices.contains(node),
                  let values = box.arrayValue?.compactMap(\.doubleValue), values.count == 4
            else { continue }
            let id   = backendIDs[node]
            let rect = CGRect(x: values[0] - scrollX, y: values[1] - scrollY, width: values[2], height: values[3])
            if boxes[id] == nil { boxes[id] = rect }
            if laidOut[node] == nil {
                let named = styles.indices.contains(position) ? (styles[position].arrayValue ?? []).map(string) : []
                laidOut[node] = (rect, named)
            }
        }
        let clips = Self.clips(
            parents   : (document["nodes"]?["parentIndex"]?.arrayValue ?? []).map { $0.intValue ?? -1 },
            names     : (document["nodes"]?["nodeName"]?.arrayValue ?? []).map(string),
            backendIDs: backendIDs,
            laidOut   : laidOut
        )
        self.init(
            boxes         : boxes,
            clips         : clips,
            viewport      : CGSize(width: width, height: height),
            title         : string(document["title"]),
            url           : string(document["documentURL"]),
            secureFieldIDs: Self.secureFields(in: snapshot["documents"]?.arrayValue ?? [], strings: strings)
        )
    }

    /// The clip of each node a scroll container clips, by its backend id, in one pass in document order, where a
    /// parent comes before its children. Each node passes on two clips: the one its normal-flow children are seen
    /// in, its own narrowed by its box on each axis it clips, and the one its absolutely positioned descendants
    /// are seen in, which only a positioned node narrows.
    static func clips(
        parents   : [Int],
        names     : [String],
        backendIDs: [Int],
        laidOut   : [Int: (box: CGRect, styles: [String])]
    ) -> [Int: CGRect] {
        let count = backendIDs.count
        var flow    = [CGRect?](repeating: nil, count: count)
        var settled = [CGRect?](repeating: nil, count: count)
        var clips: [Int: CGRect] = [:]
        for node in 0..<count {
            let parent   = parents.indices.contains(node) ? parents[node] : -1
            let above    = parent >= 0 && parent < node ? parent : nil
            let styles   = laidOut[node]?.styles ?? []
            let position = styles.count > 2 && !styles[2].isEmpty ? styles[2] : "static"
            let own: CGRect? = switch position {
                case "fixed":    nil
                case "absolute": above.flatMap { settled[$0] }
                default:         above.flatMap { flow[$0] }
            }
            if let own, clips[backendIDs[node]] == nil { clips[backendIDs[node]] = own }
            var passed = own
            let name = names.indices.contains(node) ? names[node].uppercased() : ""
            if let box = laidOut[node]?.box, name != "HTML", name != "BODY", styles.count > 1 {
                let clipsX = styles[0] != "visible" && !styles[0].isEmpty
                let clipsY = styles[1] != "visible" && !styles[1].isEmpty
                if clipsX || clipsY {
                    let bound = CGRect(x: clipsX ? box.minX : -1e9, y: clipsY ? box.minY : -1e9,
                                       width: clipsX ? box.width : 2e9, height: clipsY ? box.height : 2e9)
                    passed = passed.map { $0.intersection(bound) } ?? bound
                }
            }
            flow[node] = passed
            settled[node] = position == "static" ? above.flatMap { settled[$0] } : passed
        }
        return clips
    }

    /// The backend ids of the secure fields in any of the documents. The snapshot lists a node's
    /// attributes as string indexes, name then value.
    static func secureFields(
        in documents: [JSONValue],
        strings     : [String]
    ) -> Set<Int> {
        func string(_ index: JSONValue?) -> String {
            guard let index = index?.intValue, strings.indices.contains(index) else { return "" }
            return strings[index]
        }
        var secure: Set<Int> = []
        for document in documents {
            let nodes      = document["nodes"]
            let names      = nodes?["nodeName"]?.arrayValue ?? []
            let attributes = nodes?["attributes"]?.arrayValue ?? []
            let backendIDs = nodes?["backendNodeId"]?.arrayValue ?? []
            for (index, name) in names.enumerated() where string(name).uppercased() == "INPUT" {
                guard attributes.indices.contains(index), backendIDs.indices.contains(index),
                      let id = backendIDs[index].intValue
                else { continue }
                let pairs = attributes[index].arrayValue ?? []
                var named: [String: String] = [:]
                for pair in stride(from: 0, to: pairs.count - 1, by: 2) {
                    named[string(pairs[pair]).lowercased()] = string(pairs[pair + 1])
                }
                if WebSecureFields.isSecure(tag: "INPUT", attributes: named) { secure.insert(id) }
            }
        }
        return secure
    }
}
