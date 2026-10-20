import CoreGraphics
import EngineCore
import Foundation
import MacDriver
import MacDriving
import PerceptionCore
import Testing

/// The scene builder on trees recorded with `braus mac record` on 15 Oct (Settings' Keyboard pane,
/// a Finder window in column view, Calculator) and on small built trees for the rules no recording
/// shows on its own.
@Suite("MacDriver scene builder")
struct MacSceneBuilderTests {

    private func scene(_ name: String) throws -> MacScene {
        MacSceneBuilder.scene(from: try Trees.read(name), bundleID: "com.example.\(name)", appName: name)
    }

    private func element(_ scene: MacScene, _ label: String) throws -> SceneElement {
        try #require(scene.perceived.scene.elements.first { $0.label == label })
    }

    @Test("Settings: the sidebar's rows, the selected pane, switches named by the text before them")
    func settings() throws {
        let scene = try scene("settings-keyboard")
        let keyboard = try element(scene, "Tastiera")
        #expect(keyboard.role == "AXRow" && keyboard.section == "sidebar" && keyboard.state == .on)
        #expect(try element(scene, "Trackpad").state == .off)
        #expect(try element(scene, "Cerca").section == "sidebar")

        let backlight = try element(scene, "Regola la luminosità della tastiera in condizioni di luce scarsa")
        let switches = scene.perceived.scene.elements.filter { $0.role == "AXSwitch" }
        #expect(switches.count == 2 && switches.allSatisfy { !$0.isUnlabeled && $0.state == .off })
        #expect(switches.contains { $0.label == backlight.label })

        let repeatRate = try element(scene, "Velocità ripetizione tasto")
        #expect(repeatRate.role == "AXSlider" && repeatRate.value == "6" && repeatRate.section == "content")
        #expect(!scene.perceived.scene.elements.contains { $0.role == "AXValueIndicator" })
        #expect(scene.coverage.isRich)
    }

    @Test("Finder: sidebar, toolbar segments with their state, an empty folder reads sparse")
    func finder() throws {
        let scene = try scene("finder-column")
        #expect(try element(scene, "Documenti").section == "sidebar")
        #expect(try element(scene, "vista colonna").state == .on)
        #expect(try element(scene, "vista icone").state == .off)
        #expect(try element(scene, "indietro").isEnabled == false)
        #expect(try element(scene, "Cerca").role == "AXSearchField")
        #expect(try element(scene, "close").section == "window controls")
        #expect(!scene.coverage.isRich)
        #expect(scene.perceived.scene.sections.map(\.name).contains("toolbar"))
    }

    @Test("Calculator: every key a named button, the display as text, rich coverage")
    func calculator() throws {
        let scene = try scene("calculator")
        for key in ["7", "8", "9", "Elimina", "Cancella tutto"] {
            #expect(try element(scene, key).role == "AXButton")
        }
        #expect(scene.perceived.scene.elements.contains { $0.kind == .text })
        #expect(scene.coverage.isRich)
        #expect(scene.perceived.capture.isComplete)
        #expect(scene.perceived.surface == .window)
    }

    @Test("Ids are the paths from the window, unique, and every box lies inside the window",
          arguments: ["settings-keyboard", "finder-column", "calculator"])
    func addresses(name: String) throws {
        let elements = try scene(name).perceived.scene.elements
        #expect(Set(elements.map(\.id)).count == elements.count)
        #expect(elements.allSatisfy { $0.id.hasPrefix("m") })
        #expect(elements.allSatisfy { $0.bounds.x >= 0 && $0.bounds.y >= 0 && $0.bounds.maxX <= 1.0001 && $0.bounds.maxY <= 1.0001 })
    }

    @Test("A secure field never carries its value, even when the tree reported one")
    func secureField() {
        let field = MacTreeNode(role: "AXTextField", subrole: "AXSecureTextField", title: "Password", value: "••••",
                                frame: CGRect(x: 10, y: 10, width: 100, height: 20))
        #expect(field.value == nil)
        let window = Trees.window("Login", CGRect(x: 0, y: 0, width: 200, height: 100), children: [field])
        let scene = MacSceneBuilder.scene(from: MacTreeRead(window: window, nodesVisited: 2), bundleID: "x", appName: "x")
        let element = scene.perceived.scene.elements.first
        #expect(element?.role == "AXSecureTextField" && element?.value == nil && element?.label == "Password")
    }

    @Test("A field with no name of its own takes the static text before it, as Mail's \"A:\"")
    func precedingText() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let window = Trees.window("Nuovo messaggio", frame, children: [
            MacTreeNode(role: "AXStaticText", value: "A:", frame: CGRect(x: 10, y: 10, width: 20, height: 20)),
            MacTreeNode(role: "AXGroup", frame: CGRect(x: 30, y: 10, width: 2, height: 20)),
            MacTreeNode(role: "AXTextField", value: "", frame: CGRect(x: 40, y: 10, width: 300, height: 20)),
        ])
        let scene = MacSceneBuilder.scene(from: MacTreeRead(window: window, nodesVisited: 4), bundleID: "x", appName: "x")
        let field = scene.perceived.scene.elements.first { $0.role == "AXTextField" }
        #expect(field?.label == "A:" && field?.isUnlabeled == false)
    }

    @Test("A row is one element named by its texts, which are not repeated")
    func rows() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let row = MacTreeNode(role: "AXRow", isSelected: true, frame: CGRect(x: 0, y: 50, width: 400, height: 20), children: [
            MacTreeNode(role: "AXCell", frame: CGRect(x: 0, y: 50, width: 200, height: 20), children: [
                MacTreeNode(role: "AXStaticText", value: "Fattura", frame: CGRect(x: 5, y: 52, width: 100, height: 16)),
            ]),
            MacTreeNode(role: "AXCell", frame: CGRect(x: 200, y: 50, width: 200, height: 20), children: [
                MacTreeNode(role: "AXStaticText", value: "12 ott", frame: CGRect(x: 205, y: 52, width: 100, height: 16)),
                MacTreeNode(role: "AXCheckBox", title: "Segna", value: "1",
                            frame: CGRect(x: 380, y: 52, width: 16, height: 16), actions: ["AXPress"]),
            ]),
        ])
        let table = MacTreeNode(role: "AXTable", descriptionText: "Messaggi", frame: CGRect(x: 0, y: 40, width: 400, height: 200),
                                children: [row])
        let window = Trees.window("Posta", frame, children: [table])
        let elements = MacSceneBuilder.scene(from: MacTreeRead(window: window, nodesVisited: 7), bundleID: "x", appName: "x")
            .perceived.scene.elements
        #expect(elements.map(\.label) == ["Fattura · 12 ott", "Segna"])
        #expect(elements[0].state == .on && elements[0].labelOrigin == .rowContent && elements[0].container == "Messaggi")
        #expect(elements[1].state == .on)
    }

    @Test("A static text is its own value, so a display that reads another result changes the token")
    func staticTextValue() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        func scene(_ display: String) -> SceneSnapshot {
            let window = Trees.window("Calcolatrice", frame, children: [
                MacTreeNode(role: "AXStaticText", value: display, frame: CGRect(x: 10, y: 10, width: 280, height: 40)),
                MacTreeNode(role: "AXButton", title: "Uguale", frame: CGRect(x: 10, y: 300, width: 60, height: 60),
                            actions: ["AXPress"]),
            ])
            return MacSceneBuilder.scene(from: MacTreeRead(window: window, nodesVisited: 3), bundleID: "x", appName: "x")
                .perceived.scene
        }
        let before = scene("7×6"), after = scene("42")
        let text = before.elements.first { $0.kind == .text }
        #expect(text?.label == "7×6" && text?.value == "7×6")
        #expect(before.token != after.token)
        #expect(SceneDifference.effect(before: before, after: after, targetID: "m1", countsNativeTextChange: true)
            == .valueChanged(label: "7×6", value: "42"))
    }

    @Test("On = the recorded Calculator moves the display's id, and the display still reads 42")
    func calculatorEquals() throws {
        // The recorded tree is after =: 7×6 in the expression area, 42 in the display. Before it the
        // expression area is absent and the display reads 7×6.
        func typing(_ node: MacTreeNode) -> MacTreeNode {
            var node = node
            node.children = node.children
                .filter { $0.identifier != "StandardResultView" }
                .map(typing)
            if node.role == "AXStaticText", node.value == "\u{200E}42" { node.value = "\u{200E}7\u{200E}×\u{200E}6" }
            return node
        }
        let recorded = try Trees.recorded("calculator")
        func scene(_ window: MacTreeNode) -> SceneSnapshot {
            MacSceneBuilder.scene(from: MacTreeRead(window: window, nodesVisited: window.flattened.count),
                                  bundleID: "com.apple.calculator", appName: "Calcolatrice").perceived.scene
        }
        let before = scene(typing(recorded).addressed()), after = scene(recorded)
        let typed = try #require(before.elements.first { $0.kind == .text && $0.value == "\u{200E}7\u{200E}×\u{200E}6" })
        let shown = try #require(after.elements.first { $0.kind == .text && $0.value == "\u{200E}42" })
        // The display's id now names the expression, with the same value: the id reading sees no change.
        #expect(typed.id != shown.id)
        #expect(after.elements.first { $0.id == typed.id }?.value == typed.value)
        let equals = try #require(before.elements.first { $0.label == "Uguale" })
        #expect(SceneDifference.effect(before: before, after: after, targetID: equals.id, countsNativeTextChange: true)
            == .valueChanged(label: typed.label, value: "\u{200E}42"))
    }

    @Test("A cut walk is a partial capture with its reason")
    func cut() throws {
        var read = try Trees.read("calculator")
        read.stoppedBy = .deadline
        let quality = MacSceneBuilder.scene(from: read, bundleID: "x", appName: "x").perceived.capture
        #expect(quality.completeness == .partial && quality.stoppedBy == .deadline)
    }

    @Test("M2: a read with an element that did not answer is partial with no limit named; the known elements are emitted as before, the counts are on the scene")
    func unanswered() throws {
        var read = try Trees.read("calculator")
        let complete = MacSceneBuilder.scene(from: read, bundleID: "x", appName: "x")
        #expect(complete.perceived.capture.isComplete && complete.unread.isEmpty, "the recorded tree, read in full")
        read.window.children.append(MacTreeNode(path: [read.window.children.count], role: "AXUnknown",
                                                unread: MacUnread(cause: .timedOut, element: true)))
        let scene = MacSceneBuilder.scene(from: read, bundleID: "x", appName: "x")
        let quality = scene.perceived.capture
        #expect(quality.completeness == .partial && quality.walkCompleted == false && quality.stoppedBy == nil)
        #expect(quality.inconsistency == nil)
        #expect(scene.perceived.scene.elements == complete.perceived.scene.elements)
        #expect(scene.unread == MacTreeRead.Unread(nodes: 1, elements: 1, cause: .timedOut))
    }

    @Test("M2: a cut walk that also met an element that did not answer keeps the limit it met")
    func cutAndUnanswered() throws {
        var read = try Trees.read("calculator")
        read.stoppedBy = .elementLimit
        read.window.children[0].unread = MacUnread(cause: .failed(code: -25200), attributes: ["AXValue"])
        let quality = MacSceneBuilder.scene(from: read, bundleID: "x", appName: "x").perceived.capture
        #expect(quality.completeness == .partial && quality.stoppedBy == .elementLimit && quality.inconsistency == nil)
    }

    @Test("A canvas: one big group with no actions reads sparse")
    func canvas() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = Trees.window("Disegno", frame, children: [MacTreeNode(role: "AXGroup", frame: frame)])
        let coverage = MacCoverage(window: window)
        #expect(coverage.coveredShare == 0 && coverage.actionableCount == 0 && !coverage.isRich)
    }
}
