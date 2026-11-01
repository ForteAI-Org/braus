import Foundation
@testable import PerceptionCore
import Testing

struct SecureFieldRenderingTests {
    @Test(arguments: [nil, "fake-private-value"] as [String?])
    func visibleField(value: String?) {
        let element = SceneElement(
            id: "secure", kind: .control, label: "Password",
            bounds: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
            role: "AXSecureTextField", value: value, selectedRange: NSRange(location: 0, length: 2),
            isEnabled: false, container: "Account"
        )
        let line = SceneSnapshot.elementLine(element)
        #expect(line == "[field] Password id:'secure' secret [disabled] {Account} @10,20\n")
        #expect(!line.contains(" = "))
        #expect(!line.contains("fake-private-value"))
        var member = element
        member.section = "Account"
        let scene = SceneSnapshot(
            bundleID: "example.app", appName: "Example", windowTitle: "Form",
            viewportPixelSize: .init(width: 500, height: 400), elements: [member],
            sections: [SceneSection(name: "Account", bounds: .init(x: 0, y: 0, width: 1, height: 1))]
        )
        for text in [scene.text(), scene.mapText()] {
            #expect(text.contains("[field] Password id:'secure' secret"))
            #expect(!text.contains(" = "))
            #expect(!text.contains("fake-private-value"))
            #expect(!text.contains("[sel"))
        }
    }

    @Test(arguments: ["", "fake-private-value"])
    func beyondEdge(value: String) {
        let field = OutOfViewField(label: "Password", value: value, role: "AXSecureTextField",
                                   isEnabled: false, container: "Account")
        #expect(SceneSnapshot.outOfViewLine(field) == "[field] Password secret [disabled] {Account}")
    }
}
