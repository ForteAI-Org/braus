//
//  WebSelectPopupTests.swift
//  Braus
//

import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import WebDriving

@Suite("Web select pop-up")
struct WebSelectPopupTests {

    static let viewport = CGSize(width: 1000, height: 500)

    static func popup(anchorY: Double, count: Int) -> WebSelectPopup {
        WebSelectPopup(name: "Color", anchor: CGRect(x: 100, y: anchorY, width: 60, height: 20),
                       options: (1...count).map { .init(text: "Option \($0)", isSelected: $0 == 1) })
    }

    @Test("The list hangs under its select, at least a minimum width")
    func underTheSelect() {
        #expect(Self.popup(anchorY: 100, count: 3).frame(in: Self.viewport) == CGRect(x: 100, y: 120, width: 120, height: 60))
    }

    @Test("A list with no room below rises to fit; a long one shrinks its rows to the viewport")
    func fits() {
        #expect(Self.popup(anchorY: 460, count: 3).frame(in: Self.viewport).maxY == 500)
        let long = Self.popup(anchorY: 10, count: 100).frame(in: Self.viewport)
        #expect(long.minY == 0 && long.height == 500)
        #expect(Self.popup(anchorY: 10, count: 1000).elements(in: Self.viewport).count == 250)
    }

    @Test("The scene shows the options as menu items in a pop-up section over what they cover")
    func scene() throws {
        let nodes = [WebAXNode(id: "1", childIDs: ["2", "3"], role: "RootWebArea", backendNodeID: 1),
                     WebAXNode(id: "2", parentID: "1", role: "button", name: "Hidden", backendNodeID: 2),
                     WebAXNode(id: "3", parentID: "1", role: "button", name: "Seen", backendNodeID: 3)]
        let layout = WebLayout(boxes: [2: CGRect(x: 110, y: 125, width: 50, height: 10),
                                       3: CGRect(x: 600, y: 300, width: 50, height: 20)],
                               viewport: Self.viewport, url: "https://example.com")
        let scene = WebSceneBuilder.scene(nodes: nodes, layout: layout, popup: Self.popup(anchorY: 100, count: 3))
        #expect(scene.elements.map(\.label) == ["Seen", "Option 1", "Option 2", "Option 3"])
        let first = try #require(scene.elements.first { $0.label == "Option 1" })
        #expect(first.role == "AXMenuItem" && first.state == .on && first.section == "pop-up (Color)")
        #expect(scene.sections.map(\.name) == ["pop-up (Color)"])
    }

    @Test("A trailing ordinal names which of several; a script string is escaped")
    func ordinalsAndStrings() {
        #expect(WebControls.splitOrdinal("Size #2") == ("Size", 2))
        #expect(WebControls.splitOrdinal("Size") == ("Size", 1))
        #expect(WebControls.splitOrdinal("Room #A") == ("Room #A", 1))
        #expect(WebControls.jsString("a\"b\\c") == "\"a\\\"b\\\\c\"")
    }
}
