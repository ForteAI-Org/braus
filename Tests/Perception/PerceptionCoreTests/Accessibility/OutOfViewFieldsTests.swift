//
//  OutOfViewFieldsTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import CoreGraphics
import Foundation
@testable import PerceptionCore
import Testing

@Suite("Fields past the window edge")
struct OutOfViewFieldsTests {

    private let window = CGRect(x: 2070, y: -303, width: 1261, height: 827)
    private let outside = CGRect(x: 3460, y: -250, width: 100, height: 24)

    private func harvest(_ children: [FakeNode]) -> AccessibilityHarvest {
        let root = FakeNode("AXWindow", frame: window)
        for child in children { root.adding(child) }
        return AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: FakeReader())
    }

    private func scene(_ fields: [OutOfViewField] = []) -> SceneSnapshot {
        SceneSnapshot(
            bundleID: "com.avid.ProTools", appName: "Pro Tools", windowTitle: "Edit",
            viewportPixelSize: .init(width: 1261, height: 827), elements: [], outOfViewFields: fields
        )
    }

    private func tempo(_ value: String = "  97.0000") -> OutOfViewField {
        OutOfViewField(label: "Tempo value", value: value, role: "AXTextField",
                       isEnabled: true, container: "MIDI Control Cluster")
    }

    @Test("an off-window toolbar field is a fact with no change to emitted elements",
          arguments: ["AXTextField", "AXTextArea", "AXComboBox"])
    func toolbarField(role: String) throws {
        let visible = FakeNode("AXButton", title: "Play", frame: CGRect(x: 2100, y: -250, width: 30, height: 24))
        let baseline = harvest([visible])
        let field = FakeNode(role, title: "Tempo value", value: "  97.0000", frame: outside, isEnabled: false)
        let group = FakeNode("AXGroup", title: "MIDI Control Cluster", frame: outside).adding(field)
        let result = harvest([visible, group])
        #expect(result.elements == baseline.elements)
        let fact = try #require(result.outOfViewFields.first)
        #expect(result.outOfViewFields.count == 1)
        #expect(fact.label == "Tempo value")
        #expect(fact.value == "  97.0000")
        #expect(fact.role == role)
        #expect(fact.isEnabled == false)
        #expect(fact.container == "MIDI Control Cluster")
        #expect(result.quality.walkCompleted == true)
        #expect(result.quality.elementsEmitted == 1)
    }

    @Test("scrolling and tightened group clips never yield out-of-view facts")
    func clippedFields() {
        for role in ["AXScrollArea", "AXList", "AXOutline", "AXTable", "AXGrid", "AXGroup"] {
            let field = FakeNode("AXTextField", title: "Track gain", value: "0", frame: outside)
            let clip = CGRect(x: 2100, y: -200, width: 600, height: 400)
            #expect(harvest([FakeNode(role, frame: clip).adding(field)]).outOfViewFields.isEmpty)
        }
        let field = FakeNode("AXTextField", title: "Track gain", value: "0", frame: outside)
        #expect(harvest([FakeNode("AXScrollArea", frame: window).adding(field)]).outOfViewFields.isEmpty)
    }

    @Test("only a field's own label and a readable nonempty value qualify")
    func ownLabelAndValue() {
        let caption = FakeNode("AXStaticText", value: "Name:", frame: outside)
        for value: String? in [nil, "", "   ", "missing value", "97"] {
            let unnamed = FakeNode("AXTextField", value: value, frame: outside)
            #expect(harvest([caption, unnamed]).outOfViewFields.isEmpty)
        }
        for value: String? in [nil, "", "   ", "missing value"] {
            #expect(harvest([FakeNode("AXTextField", title: "Tempo", value: value, frame: outside)])
                .outOfViewFields.isEmpty)
        }
        let identified = FakeNode("AXTextField", value: "97", frame: outside)
        identified.identifier = "Tmpo"
        #expect(harvest([identified]).outOfViewFields.first?.label == "Tmpo")
        #expect(harvest([FakeNode("AXButton", title: "Tempo", value: "97", frame: outside)])
            .outOfViewFields.isEmpty)
        #expect(harvest([FakeNode("AXTextField", title: "Tempo", value: "97", frame: .zero)])
            .outOfViewFields.isEmpty)
    }

    @Test("the first sixteen facts survive without stopping the walk or dropping visible elements")
    func boundedFacts() {
        let fields = (0..<20).map { FakeNode("AXTextField", title: "Field \($0)", value: "97", frame: outside) }
        let visible = FakeNode("AXButton", title: "Play", frame: CGRect(x: 2100, y: -250, width: 30, height: 24))
        let result = harvest(fields + [visible])
        #expect(result.outOfViewFields.map(\.label) == (0..<16).map { "Field \($0)" })
        #expect(result.elements.map(\.label) == ["Play"])
        #expect(result.quality.walkCompleted == true)
        #expect(result.quality.stoppedBy == nil)
        #expect(result.quality.nodesVisited == 22)
    }

    @Test("scene text appends read-only facts without target references")
    func rendering() {
        let text = scene([tempo()]).text()
        #expect(text.hasSuffix("## past the window's edge (read only, not visible)\n[field] Tempo value = \"97.0000\" {MIDI Control Cluster}\n"))
        #expect(!text.contains("id:"))
        #expect(!text.contains("@"))
        #expect(!scene().text().contains("past the window"))
        var mapped = scene([tempo()])
        mapped.sections = [SceneSection(name: "toolbar", bounds: .init(x: 0, y: 0, width: 1, height: 0.2))]
        #expect(mapped.mapText().contains("[field] Tempo value = \"97.0000\""))
    }

    @Test("field values round trip and missing legacy keys decode empty")
    func codingAndToken() throws {
        let before = scene([tempo("120.0000")])
        let after = scene([tempo()])
        #expect(before.token != after.token)
        #expect(Set([before, after]).count == 2)
        #expect(try JSONDecoder().decode(SceneSnapshot.self, from: JSONEncoder().encode(after)) == after)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(scene())) as? [String: Any])
        legacy.removeValue(forKey: "outOfViewFields")
        let decoded = try JSONDecoder().decode(SceneSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.outOfViewFields.isEmpty)
        #expect(decoded.token == scene().token)
    }

    @Test("diffs report changed values, additions and removals in the read-only section")
    func changes() {
        let before = scene([tempo("120.0000")])
        let after = scene([tempo("97.0000")])
        let change = SceneChanges.text(from: before, to: after, since: 1)
        #expect(change.contains("## past the window's edge (read only, not visible)"))
        #expect(change.contains("~ [field] Tempo value = \"97.0000\" {MIDI Control Cluster}  (was \"120.0000\")"))
        #expect(SceneChanges.text(from: scene(), to: after, since: 1).contains("+ [field] Tempo value"))
        #expect(SceneChanges.text(from: after, to: scene(), since: 1).contains("- [field] Tempo value"))
        #expect(SceneChanges.text(from: after, to: after, since: 1) == "Unchanged since revision 1.")
    }

    @Test("unchanged duplicate fields survive additions and removals without false value changes")
    func duplicateChanges() {
        let pair = scene([tempo("120.0000"), tempo("97.0000")])
        let single = scene([tempo("97.0000")])
        let removed = SceneChanges.text(from: pair, to: single, since: 1)
        #expect(removed.contains("- [field] Tempo value = \"120.0000\""))
        #expect(!removed.contains("~ [field]"))
        #expect(!removed.contains("- [field] Tempo value = \"97.0000\""))
        let added = SceneChanges.text(from: single, to: pair, since: 1)
        #expect(added.contains("+ [field] Tempo value = \"120.0000\""))
        #expect(!added.contains("~ [field]"))
        #expect(SceneChanges.text(from: pair, to: scene([tempo("97.0000"), tempo("120.0000")]), since: 1)
            == "Unchanged since revision 1.")
    }

    @Test("action and text-entry resolution cannot target an out-of-view fact")
    func noTarget() {
        let snapshot = scene([tempo()])
        for query in ["Tempo value", "97.0000", "Tmpo", "[field] Tempo value = \"97.0000\" {MIDI Control Cluster}"] {
            #expect(snapshot.resolve(target: query) == .none)
            #expect(snapshot.resolve(target: query, preferNativeControls: true) == .none)
            #expect(snapshot.resolve(target: query, preferTextEntry: true) == .none)
            #expect(snapshot.resolve(target: query, section: "MIDI Control Cluster") == .none)
        }
        #expect(snapshot.elements.isEmpty)
    }
}
