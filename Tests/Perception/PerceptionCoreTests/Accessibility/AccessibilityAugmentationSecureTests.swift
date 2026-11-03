import CoreGraphics
import Foundation
@testable import PerceptionCore
import Synchronization
import Testing

struct AccessibilityAugmentationSecureTests {
    @Test(arguments: ["role", "subrole", "unreadable", "combo"], [false, true])
    func secureFields(scenario: String, outside: Bool) throws {
        let window = CGRect(x: 0, y: 0, width: 500, height: 400)
        let field = FakeNode(
            scenario == "role" ? "AXSecureTextField" : scenario == "combo" ? "AXComboBox" : "AXTextField",
            subrole: scenario == "subrole" ? "AXSecureTextField" : nil,
            title: "Password", value: "fake-private-value",
            frame: CGRect(x: outside ? 550 : 50, y: 50, width: 100, height: 24), isEnabled: false
        )
        field.selectedRange = NSRange(location: 0, length: 2)
        let root = FakeNode("AXWindow", frame: window).adding(field)
        let reader = SecureCountingReader()
        let result = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: reader)
        #expect(reader.reads.withLock { $0 } == 0)
        if outside {
            #expect(result.elements.isEmpty)
            let fact = try #require(result.outOfViewFields.first)
            #expect(fact.role == "AXSecureTextField")
            #expect(fact.value == "")
            #expect(fact.isEnabled == false)
            #expect(SceneSnapshot.outOfViewLine(fact) == "[field] Password secret [disabled]")
        } else {
            let element = try #require(result.elements.first)
            #expect(result.elements.count == 1)
            #expect(element.role == "AXSecureTextField")
            #expect(element.value == nil)
            #expect(element.selectedRange == nil)
            #expect(element.isEnabled == false)
            let pixel = SceneElement(id: "ocr", kind: .text, label: "Password", bounds: element.bounds)
            let merged = AccessibilityAugmentation.merge(pixels: [pixel], accessibility: result.elements)
            #expect(merged.count == 1)
            #expect(merged.first?.role == "AXSecureTextField")
            #expect(SceneSnapshot.elementLine(try #require(merged.first)).contains(" secret"))
        }
    }

    @Test("Eight ordinary scenes retain byte-identical text with classification enabled", arguments: 0..<8)
    func ordinaryScenes(index: Int) {
        let window = CGRect(x: 0, y: 0, width: 500, height: 400)
        let field = FakeNode("AXTextField", subrole: "", title: ["Key", "Token", "PIN", "Password"][index % 4],
                             value: "Value \(index)", frame: CGRect(x: 50, y: 50, width: 100, height: 24))
        let root = FakeNode("AXWindow", frame: window).adding(field)
        let plain = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: FakeReader())
        let guarded = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: SecureCountingReader())
        func text(_ elements: [SceneElement]) -> String {
            SceneSnapshot(bundleID: "example.app", appName: "Example", windowTitle: "Form",
                          viewportPixelSize: .init(width: 500, height: 400), elements: elements).text()
        }
        #expect(text(plain.elements).utf8.elementsEqual(text(guarded.elements).utf8))
    }
}

private final class SecureCountingReader: AccessibilityTreeReading {
    let reads = Mutex(0)
    var requiresValueClassification: Bool { true }
    func role(_ node: FakeNode) -> String? { node.role }
    func subrole(_ node: FakeNode) -> String? { node.subrole }
    func title(_ node: FakeNode) -> String? { node.title }
    func descriptionText(_ node: FakeNode) -> String? { node.descriptionText }
    func identifier(_ node: FakeNode) -> String? { node.identifier }
    func value(_ node: FakeNode) -> String? {
        reads.withLock { $0 += 1 }
        return node.value
    }
    func numericValue(_ node: FakeNode) -> Int? { node.numericValue }
    func isEnabled(_ node: FakeNode) -> Bool? { node.isEnabled }
    func actions(_ node: FakeNode) -> [String] { [] }
    func frame(_ node: FakeNode) -> CGRect? { node.frame }
    func children(_ node: FakeNode) -> [FakeNode] { node.children }
    func selectedRange(_ node: FakeNode) -> NSRange? { node.selectedRange }
}
