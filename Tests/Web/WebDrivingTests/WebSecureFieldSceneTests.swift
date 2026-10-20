//
//  WebSecureFieldSceneTests.swift
//  Braus
//

import CoreGraphics
import Foundation
import PerceptionCore
import Testing
import WebDriver
@testable import WebDriving

/// W1 in the scene: which fields are secure comes from the DOM snapshot's `type` attribute, in every document,
/// and such a field reaches the scene as `AXSecureTextField` with no value, whatever its label says.
@Suite("Web secure fields in the scene (W1)")
struct WebSecureFieldSceneTests {

    static let sentinel = "Prefilled-Secret-4417"

    /// A snapshot answer: a document with a password input (one a shadow tree flattened in) and a text input,
    /// and a frame's document with another password input.
    private func snapshot() -> JSONValue {
        let strings: [JSONValue] = ["", "#document", "INPUT", "type", "PASSWORD", "text", "Password", "DIV", "TYPE"]
        let main: JSONValue = [
            "nodes": [
                "nodeName"     : [1, 2, 7, 2, 2],
                "backendNodeId": [1, 11, 20, 21, 12],
                "attributes"   : [[], [3, 4], [], [8, 6], [3, 5]],
            ],
            "layout": [
                "nodeIndex": [0, 1, 3, 4],
                "bounds"   : [[0, 0, 1280, 720], [100, 100, 300, 30], [100, 150, 300, 30], [100, 200, 300, 30]],
            ],
        ]
        let frame: JSONValue = [
            "nodes" : ["nodeName": [1, 2], "backendNodeId": [30, 31], "attributes": [[], [3, 4]]],
            "layout": ["nodeIndex": [], "bounds": []],
        ]
        return ["documents": [main, frame], "strings": .array(strings)]
    }

    private let metrics: JSONValue = ["cssLayoutViewport": ["clientWidth": 1280, "clientHeight": 720]]

    @Test("secure fields come from the input's own type attribute, in the page, a flattened shadow tree and a frame")
    func secureFieldsFromTheDOM() throws {
        let layout = try WebLayout(snapshot: snapshot(), metrics: metrics)
        #expect(layout.secureFieldIDs == [11, 21, 31], "attribute names and values in any case; not the text input")
    }

    private func textbox(_ id: Int, _ name: String, _ value: String) -> WebAXNode {
        WebAXNode(id: "field-\(id)", parentID: "root", role: "textbox", name: name, value: value, backendNodeID: id)
    }

    @Test("the DOM's password type wins over the tree's role: any role of a secure node is a secure field with no value",
          arguments: ["textbox", "searchbox", "spinbutton", "combobox", "slider", "PopUpButton", "button", "generic"])
    func secureNodeWhateverItsRole(role: String) throws {
        let layout = try WebLayout(snapshot: snapshot(), metrics: metrics)
        let nodes = [
            WebAXNode(id: "root", childIDs: ["field-11"], role: "RootWebArea", name: "Form", backendNodeID: 1),
            WebAXNode(id: "field-11", parentID: "root", role: role, name: "Accesso", value: Self.sentinel, backendNodeID: 11),
        ]
        let scene = WebSceneBuilder.scene(nodes: nodes, layout: layout)
        let field = try #require(scene.elements.first { $0.label == "Accesso" }, "\(role): \(scene.elements)")
        #expect(field.role == "AXSecureTextField", "\(role)")
        #expect(field.value == nil, "\(role)")
        #expect(!scene.mapText().contains(Self.sentinel), "\(role)")
    }

    @Test("a password field reaches the scene as AXSecureTextField with no value; a text field keeps its own")
    func secureFieldInTheScene() throws {
        let layout = try WebLayout(snapshot: snapshot(), metrics: metrics)
        let nodes = [
            WebAXNode(id: "root", childIDs: ["field-11", "field-21", "field-12"], role: "RootWebArea", name: "Form",
                      backendNodeID: 1),
            textbox(11, "Accesso", Self.sentinel),
            textbox(21, "Codice", Self.sentinel + "-shadow"),
            textbox(12, "Nome", "Ada"),
        ]
        let scene = WebSceneBuilder.scene(nodes: nodes, layout: layout)
        for label in ["Accesso", "Codice"] {
            let field = try #require(scene.elements.first { $0.label == label }, "\(label)")
            #expect(field.role == "AXSecureTextField", "\(label)")
            #expect(field.value == nil, "\(label)")
        }
        let text = try #require(scene.elements.first { $0.label == "Nome" })
        #expect(text.role == "AXTextField" && text.value == "Ada")
        #expect(!scene.mapText().contains(Self.sentinel))
        #expect(scene.elements.allSatisfy { !($0.value ?? "").contains(Self.sentinel) && !$0.label.contains(Self.sentinel) })
    }
}
