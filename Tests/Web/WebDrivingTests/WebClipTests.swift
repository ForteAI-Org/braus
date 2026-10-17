//
//  WebClipTests.swift
//  Braus
//

import CoreGraphics
import Foundation
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving

/// W09: what a scroll container hides is not in the scene. The clips are read from one snapshot, as Chrome writes it
/// with the computed `overflow-x`, `overflow-y` and `position` of each laid-out node; Chrome's own layout is the
/// Chrome tier's.
@Suite("Scroll containers clip the web scene (W09)")
struct WebClipTests {

    /// One laid-out node of the synthetic page: its name, parent, backend id, box and styles.
    struct Node {
        let name    : String
        let parent  : Int
        let id      : Int
        let box     : [Double]
        var overflow: (String, String) = ("visible", "visible")
        var position = "static"
    }

    /// A page of 800 by 600. Container A (0,0 300x200) clips; inside it a1 is seen, a2 lies below it, B (150..250 in
    /// y, clipping y only) holds b1 seen and b2 below A, and a3 is absolute under a static A and escapes it. C is a
    /// positioned container whose absolute child c1 lies outside it. f is fixed inside A. D clips x only: d1 lies
    /// beside it, d2 below it. The body clips, and is left to the viewport.
    static let nodes: [Node] = [
        Node(name: "#document", parent: -1, id: 1, box: [0, 0, 800, 600]),
        Node(name: "HTML", parent: 0, id: 2, box: [0, 0, 800, 600], overflow: ("hidden", "hidden")),
        Node(name: "BODY", parent: 1, id: 3, box: [0, 0, 800, 50], overflow: ("hidden", "hidden")),
        Node(name: "DIV", parent: 2, id: 10, box: [0, 0, 300, 200], overflow: ("hidden", "hidden")),
        Node(name: "BUTTON", parent: 3, id: 11, box: [10, 10, 50, 20]),
        Node(name: "BUTTON", parent: 3, id: 12, box: [10, 250, 50, 20]),
        Node(name: "DIV", parent: 3, id: 13, box: [0, 150, 300, 100], overflow: ("visible", "auto")),
        Node(name: "BUTTON", parent: 6, id: 14, box: [10, 170, 50, 20]),
        Node(name: "BUTTON", parent: 6, id: 15, box: [10, 210, 50, 20]),
        Node(name: "BUTTON", parent: 3, id: 16, box: [10, 300, 50, 20], position: "absolute"),
        Node(name: "DIV", parent: 2, id: 20, box: [400, 0, 200, 100], overflow: ("hidden", "hidden"),
             position: "relative"),
        Node(name: "BUTTON", parent: 10, id: 21, box: [400, 150, 50, 20], position: "absolute"),
        Node(name: "BUTTON", parent: 3, id: 30, box: [10, 400, 50, 20], position: "fixed"),
        Node(name: "DIV", parent: 2, id: 40, box: [0, 300, 100, 100], overflow: ("hidden", "visible")),
        Node(name: "BUTTON", parent: 13, id: 41, box: [150, 320, 40, 20]),
        Node(name: "BUTTON", parent: 13, id: 42, box: [10, 450, 40, 20]),
    ]

    static func layout(_ nodes: [Node] = nodes) throws -> WebLayout {
        var strings: [String] = []
        func index(_ text: String) -> JSONValue {
            if let found = strings.firstIndex(of: text) { return .number(Double(found)) }
            strings.append(text)
            return .number(Double(strings.count - 1))
        }
        let names = nodes.map { index($0.name) }
        let styles: [JSONValue] = nodes.map { .array([index($0.overflow.0), index($0.overflow.1), index($0.position)]) }
        let snapshot: JSONValue = [
            "documents": [[
                "documentURL": index("https://fixture.test/"), "title": index("Clips"),
                "scrollOffsetX": 0, "scrollOffsetY": 0,
                "nodes": [
                    "nodeName": .array(names), "parentIndex": .array(nodes.map { .number(Double($0.parent)) }),
                    "backendNodeId": .array(nodes.map { .number(Double($0.id)) }),
                ],
                "layout": [
                    "nodeIndex": .array(nodes.indices.map { .number(Double($0)) }),
                    "bounds"   : .array(nodes.map { .array($0.box.map { .number($0) }) }),
                    "styles"   : .array(styles),
                ],
            ]],
            "strings": .array(strings.map { .string($0) }),
        ]
        return try WebLayout(snapshot: snapshot, metrics: metrics)
    }

    static let metrics: JSONValue = ["cssLayoutViewport": ["clientWidth": 800, "clientHeight": 600]]

    /// Whether the node `id` can be seen at all, and where.
    static func seen(_ id: Int, in layout: WebLayout) -> CGRect? {
        guard let box = layout.boxes[id] else { return nil }
        let visible = box.intersection(layout.clips[id] ?? .infinite)
        return visible.isNull || visible.isEmpty ? nil : visible
    }

    @Test("a container clips its children, nested containers narrow it, and only the axes they clip")
    func nested() throws {
        let layout = try Self.layout()
        #expect(Self.seen(11, in: layout) == CGRect(x: 10, y: 10, width: 50, height: 20), "a1, inside A")
        #expect(Self.seen(12, in: layout) == nil, "a2, below A")
        #expect(Self.seen(14, in: layout) == CGRect(x: 10, y: 170, width: 50, height: 20), "b1, inside A and B")
        #expect(Self.seen(15, in: layout) == nil, "b2, inside B but below A")
        #expect(Self.seen(41, in: layout) == nil, "d1, beside D, which clips x")
        #expect(Self.seen(42, in: layout) == CGRect(x: 10, y: 450, width: 40, height: 20),
                "d2, below D, which does not clip y")
    }

    @Test("the containing block decides: absolute escapes a static container, not a positioned one; fixed escapes all")
    func containingBlock() throws {
        let layout = try Self.layout()
        #expect(layout.clips[16] == nil && Self.seen(16, in: layout) != nil, "a3, absolute under a static A")
        #expect(Self.seen(21, in: layout) == nil, "c1, absolute under a positioned C, outside it")
        #expect(layout.clips[30] == nil, "f, fixed")
        #expect(layout.clips[11] != nil && layout.clips[2] == nil && layout.clips[10] == nil,
                "html and body do not clip")
    }

    @Test("a snapshot without computed styles clips nothing, as before")
    func noStyles() throws {
        let snapshot: JSONValue = [
            "strings": [],
            "documents": [[
                "nodes": ["backendNodeId": [7, 8], "parentIndex": [-1, 0]],
                "layout": ["nodeIndex": [0, 1], "bounds": [[0, 0, 100, 100], [10, 500, 20, 20]]],
            ]],
        ]
        #expect(try WebLayout(snapshot: snapshot, metrics: Self.metrics).clips.isEmpty)
    }

    @Test("the scene leaves out what a container hides, and keeps the seen part of what it cuts")
    func scene() throws {
        var nodes = Self.nodes
        // b1 cut by A's bottom edge: 190..210 laid out, 190..200 seen.
        nodes[7] = Node(name: "BUTTON", parent: 6, id: 14, box: [10, 190, 50, 20])
        let layout = try Self.layout(nodes)
        let ax = [
            WebAXNode(id: "1", childIDs: ["11", "12", "14"], role: "RootWebArea", name: "Clips", backendNodeID: 1),
            WebAXNode(id: "11", parentID: "1", role: "button", name: "Seen", backendNodeID: 11),
            WebAXNode(id: "12", parentID: "1", role: "button", name: "Hidden", backendNodeID: 12),
            WebAXNode(id: "14", parentID: "1", role: "button", name: "Cut", backendNodeID: 14),
        ]
        let scene = WebSceneBuilder.scene(nodes: ax, layout: layout)
        #expect(scene.elements.contains { $0.label == "Seen" })
        #expect(!scene.elements.contains { $0.label == "Hidden" }, "what A hides is not in the scene")
        let cut = try #require(scene.elements.first { $0.label == "Cut" }).bounds.pixelBox(in: layout.viewport)
        let expected = CGRect(x: 10, y: 190, width: 50, height: 10)
        #expect(abs(cut.minY - expected.minY) < 0.5 && abs(cut.height - expected.height) < 0.5, "\(cut)")
    }
}
