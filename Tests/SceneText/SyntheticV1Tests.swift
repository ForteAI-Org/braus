import Foundation
import PerceptionCore
import Testing

struct SyntheticV1Tests {
    // Expected bytes were derived from SceneRendering.swift at 753d4745^1 (68f0b155),
    // using its header, elementLine, iconsLine and outOfViewLine rules.
    @Test func v1MatchesSynthetic() throws {
        let fixtures = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/synthetic-v1")
        for (name, scene) in Self.scenes {
            let expected = try Data(contentsOf: fixtures.appendingPathComponent(name + ".txt"))
            #expect(Data(scene.text().utf8) == expected, "\(name): default v1 bytes differ")
            #expect(Data(scene.text(cuts: []).utf8) == expected, "\(name): empty cuts bytes differ")
        }
    }

    private static var scenes: [(String, SceneSnapshot)] {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.2, height: 0.04)
        let field = SceneElement(id: "folder", kind: .control, label: "Folder A", bounds: rect,
                                 role: "AXTextField", value: "abcdef", selectedRange: NSRange(location: 3, length: 0))
        let selected = SceneElement(id: "selected", kind: .control, label: "Folder B",
                                    bounds: .init(x: 0.1, y: 0.3, width: 0.2, height: 0.04),
                                    role: "AXTextField", value: "abcdef", selectedRange: NSRange(location: 2, length: 3),
                                    isEnabled: false, container: "Folders")
        func icon(_ id: String, _ y: Double) -> SceneElement {
            SceneElement(id: id, kind: .icon, label: "(unlabeled)",
                         bounds: .init(x: 0.5, y: y, width: 0.04, height: 0.04), isUnlabeled: true)
        }
        let flat = SceneSnapshot(
            bundleID: "test.synthetic", appName: "Example", windowTitle: "Folder A",
            viewportPixelSize: .init(width: 1000, height: 800),
            elements: [field, selected,
                       .init(id: "heading", kind: .text, label: "## Folder A",
                             bounds: .init(x: 0.1, y: 0.4, width: 0.2, height: 0.04)),
                       icon("shared", 0.5), icon("shared", 0.6), icon("unique", 0.7)],
            outOfViewFields: [.init(label: "Folder C", value: "Folder D", role: "AXTextField"),
                              .init(label: "Folder E", value: "hidden", role: "AXSecureTextField",
                                    isEnabled: false, container: "Folders")]
        )
        var sectioned = flat
        sectioned.elements = [field, selected].map { element in
            var element = element
            element.section = "Folders"
            return element
        }
        sectioned.sections = [.init(name: "Folders", bounds: .init(x: 0, y: 0, width: 1, height: 1))]
        sectioned.commands = ["File > Open"]
        return [("flat", flat), ("sectioned", sectioned)]
    }
}
