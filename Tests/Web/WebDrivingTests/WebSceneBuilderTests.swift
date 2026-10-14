//
//  WebSceneBuilderTests.swift
//  Braus
//

import CoreGraphics
import Foundation
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving

@Suite("Web scene builder")
struct WebSceneBuilderTests {

    /// A page of 1000 by 500 with a header, a main landmark holding a form, and one button below the fold.
    static func page() -> ([WebAXNode], WebLayout) {
        let nodes = [
            WebAXNode(id: "1", childIDs: ["2", "3"], role: "RootWebArea", name: "Inbox", backendNodeID: 1),
            WebAXNode(id: "2", parentID: "1", childIDs: ["4"], role: "banner", backendNodeID: 2),
            WebAXNode(id: "4", parentID: "2", childIDs: ["5"], role: "heading", name: "Mail", backendNodeID: 4),
            WebAXNode(id: "5", parentID: "4", role: "StaticText", name: "Mail", backendNodeID: 5),
            WebAXNode(id: "3", parentID: "1", childIDs: ["6", "7", "8", "9", "10", "11", "12", "13", "14"],
                      role: "main", backendNodeID: 3),
            WebAXNode(id: "6", parentID: "3", childIDs: ["15"], role: "button", name: "Send", backendNodeID: 6,
                      properties: ["focusable": true]),
            WebAXNode(id: "15", parentID: "6", role: "StaticText", name: "Send", backendNodeID: 15),
            WebAXNode(id: "7", parentID: "3", role: "textbox", name: "To", value: "ada@example.com", backendNodeID: 7,
                      properties: ["editable": "plaintext", "multiline": false]),
            WebAXNode(id: "8", parentID: "3", role: "textbox", backendNodeID: 8,
                      properties: ["editable": "plaintext", "multiline": true]),
            WebAXNode(id: "9", parentID: "3", role: "checkbox", name: "Urgent", backendNodeID: 9,
                      properties: ["checked": "true"]),
            WebAXNode(id: "10", parentID: "3", role: "combobox", name: "Folder", value: "Work", backendNodeID: 10,
                      properties: ["hasPopup": "menu"]),
            WebAXNode(id: "11", parentID: "3", role: "button", name: "Send", backendNodeID: 11,
                      properties: ["disabled": true]),
            WebAXNode(id: "12", parentID: "3", role: "StaticText", name: "  Draft   saved ", backendNodeID: 12),
            WebAXNode(id: "13", parentID: "3", role: "button", name: "Far", backendNodeID: 13),
            WebAXNode(id: "14", parentID: "3", childIDs: ["16"], role: "LabelText", backendNodeID: 14),
            WebAXNode(id: "16", parentID: "14", role: "StaticText", name: "To", backendNodeID: 16),
        ]
        let boxes: [Int: CGRect] = [
            1 : CGRect(x: 0, y: 0, width: 1000, height: 500),
            2 : CGRect(x: 0, y: 0, width: 1000, height: 50),
            4 : CGRect(x: 10, y: 10, width: 100, height: 30),
            5 : CGRect(x: 10, y: 10, width: 100, height: 30),
            3 : CGRect(x: 0, y: 50, width: 1000, height: 450),
            6 : CGRect(x: 10, y: 60, width: 80, height: 20),
            15: CGRect(x: 20, y: 62, width: 60, height: 16),
            7 : CGRect(x: 10, y: 100, width: 300, height: 20),
            8 : CGRect(x: 10, y: 130, width: 300, height: 100),
            9 : CGRect(x: 10, y: 240, width: 13, height: 13),
            10: CGRect(x: 10, y: 260, width: 100, height: 20),
            11: CGRect(x: 120, y: 60, width: 80, height: 20),
            12: CGRect(x: 10, y: 300, width: 200, height: 18),
            13: CGRect(x: 10, y: 900, width: 80, height: 20),
            16: CGRect(x: 320, y: 100, width: 20, height: 18),
        ]
        return (nodes, WebLayout(boxes: boxes, viewport: CGSize(width: 1000, height: 500), title: "Inbox",
                                 url: "https://www.mail.example.com/inbox?x=1"))
    }

    static func element(_ label: String, in scene: SceneSnapshot) throws -> SceneElement {
        try #require(scene.elements.first { $0.label == label })
    }

    @Test("A page's knowledge is filed under its host")
    func appKey() {
        #expect(WebSceneBuilder.appKey(for: "https://www.WhatsApp.com/chat") == "web:whatsapp.com")
        #expect(WebSceneBuilder.appKey(for: "https://app.slack.com/client") == "web:app.slack.com")
        #expect(WebSceneBuilder.appKey(for: "file:///tmp/page.html") == "web:file")
        #expect(WebSceneBuilder.appKey(for: "about:blank") == "web:blank")
    }

    @Test("Chrome's roles become the roles the engine acts on")
    func roles() throws {
        let (nodes, layout) = Self.page()
        let scene = WebSceneBuilder.scene(nodes: nodes, layout: layout)
        #expect(scene.bundleID == "web:mail.example.com")
        #expect(scene.windowTitle == "Inbox")
        #expect(scene.viewportPixelSize == ViewportPixelSize(width: 1000, height: 500))

        let send = try Self.element("Send", in: scene)
        #expect(send.role == "AXButton" && send.kind == .control && send.isEnabled == true)
        #expect(send.id == "control|send")
        #expect(send.bounds == NormalizedRect(x: 0.01, y: 0.12, width: 0.08, height: 0.04))

        let to = try Self.element("To", in: scene)
        #expect(to.role == "AXTextField" && to.value == "ada@example.com")
        let area = try Self.element("Text area", in: scene)
        #expect(area.role == "AXTextArea" && area.value == "" && !area.isUnlabeled)
        let urgent = try Self.element("Urgent", in: scene)
        #expect(urgent.role == "AXCheckBox" && urgent.state == .on)
        let folder = try Self.element("Folder", in: scene)
        #expect(folder.role == "AXPopUpButton" && folder.value == "Work")
    }

    @Test("Text a control or heading already says is not repeated; loose text is kept, cleaned")
    func text() throws {
        let (nodes, layout) = Self.page()
        let scene = WebSceneBuilder.scene(nodes: nodes, layout: layout)
        #expect(scene.elements.filter { $0.kind == .text }.map(\.label) == ["Mail", "Draft saved"])
        #expect(try Self.element("Mail", in: scene).role == "AXStaticText")
    }

    @Test("A twin reads apart by ordinal, and what is below the fold is not in the scene")
    func ordinalsAndViewport() throws {
        let (nodes, layout) = Self.page()
        let scene = WebSceneBuilder.scene(nodes: nodes, layout: layout)
        let twin = try Self.element("Send #2", in: scene)
        #expect(twin.isEnabled == false)
        #expect(!scene.elements.contains { $0.label == "Far" })
    }

    @Test("Landmarks are the sections and the containers")
    func sections() throws {
        let (nodes, layout) = Self.page()
        let scene = WebSceneBuilder.scene(nodes: nodes, layout: layout)
        #expect(scene.sections.map(\.name) == ["header", "main"])
        #expect(try Self.element("Send", in: scene).section == "main")
        #expect(try Self.element("Send", in: scene).container == "main")
        #expect(try Self.element("Mail", in: scene).section == "header")
    }

    @Test("A long text is cut to a label's length")
    func longText() throws {
        let long = String(repeating: "word ", count: 40)
        let nodes = [WebAXNode(id: "1", childIDs: ["2"], role: "RootWebArea", backendNodeID: 1),
                     WebAXNode(id: "2", parentID: "1", role: "StaticText", name: long, backendNodeID: 2)]
        let layout = WebLayout(boxes: [2: CGRect(x: 0, y: 0, width: 500, height: 20)],
                               viewport: CGSize(width: 500, height: 500))
        let label = try #require(WebSceneBuilder.scene(nodes: nodes, layout: layout).elements.first?.label)
        #expect(label.count == WebSceneBuilder.maxTextLength && label.hasSuffix("…"))
    }

    @Test("The layout moves document boxes by the scroll offset and reads title and address")
    func layout() throws {
        let snapshot: JSONValue = [
            "strings": ["https://example.com/", "Example"],
            "documents": [[
                "documentURL": 0, "title": 1, "scrollOffsetX": 0, "scrollOffsetY": 300,
                "nodes": ["backendNodeId": [7, 8]],
                "layout": ["nodeIndex": [0, 1, 1], "bounds": [[0, 0, 800, 2000], [10, 350, 50, 20], [0, 0, 1, 1]]],
            ]],
        ]
        let metrics: JSONValue = ["cssLayoutViewport": ["clientWidth": 800, "clientHeight": 600]]
        let layout = try WebLayout(snapshot: snapshot, metrics: metrics)
        #expect(layout.boxes[8] == CGRect(x: 10, y: 50, width: 50, height: 20))
        #expect(layout.viewport == CGSize(width: 800, height: 600))
        #expect(layout.title == "Example" && layout.url == "https://example.com/")
    }

    @Test("A tree node reads its role, name, value and properties")
    func node() throws {
        let json: JSONValue = [
            "nodeId": "24", "parentId": "23", "childIds": ["50"], "ignored": false, "backendDOMNodeId": 24,
            "role": ["type": "role", "value": "slider"], "name": ["type": "computedString", "value": "Volume"],
            "value": ["type": "number", "value": 40],
            "properties": [["name": "disabled", "value": ["type": "boolean", "value": true]]],
        ]
        let node = try #require(WebAXNode(json: json))
        #expect(node.role == "slider" && node.name == "Volume" && node.value == "40")
        #expect(node.parentID == "23" && node.childIDs == ["50"] && node.backendNodeID == 24)
        #expect(node.flag("disabled") == true)
    }
}
