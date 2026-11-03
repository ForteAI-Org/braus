import ApplicationServices
import AccessibilityActions
import AccessibilityFacts
import EngineCore
import Foundation
import PerceptionCore
import SeatDriving
import Testing

@Suite("Seat focused field")
struct SeatFocusedFieldTests {
    @Test("focus classification reads no value and runs off the main thread",
          arguments: ["AXSecureTextField", "AXTextField", "AXTextArea", "AXComboBox", "AXButton", "AXGroup"])
    @MainActor
    func classification(role: String) async {
        let field = AXUIElementCreateApplication(4242)
        let controls = SeatControls(copyAttributeValue: { _, attribute, result in
            #expect(!Thread.isMainThread)
            switch attribute as String {
                case "AXFocusedUIElement": result.pointee = AXUIElementCreateApplication(4242)
                case "AXRole": result.pointee = role as CFString
                case "AXSubrole": result.pointee = "AXUnknown" as CFString
                case "AXEditable": result.pointee = kCFBooleanFalse
                default:
                    Issue.record("Unexpected attribute: \(attribute)")
                    return .attributeUnsupported
            }
            return .success
        })
        let identity = TargetIdentity(NativeAccessibilityIdentity.token(for: field))
        let expected: FocusedField = switch role {
            case "AXSecureTextField": .secure(identity)
            case "AXTextField", "AXTextArea", "AXComboBox": .ordinary(identity)
            default: .unknown
        }
        #expect(await controls.focusedField(in: 4242) == expected)
    }

    @Test("secure subrole takes precedence over editable and ordinary roles")
    func secureSubrole() async {
        let controls = SeatControls(copyAttributeValue: { _, attribute, result in
            switch attribute as String {
                case "AXFocusedUIElement": result.pointee = AXUIElementCreateApplication(4243)
                case "AXRole": result.pointee = "AXTextField" as CFString
                case "AXSubrole": result.pointee = "AXSecureTextField" as CFString
                default: Issue.record("Unexpected attribute: \(attribute)"); return .attributeUnsupported
            }
            return .success
        })
        guard case .secure = await controls.focusedField(in: 4243) else {
            Issue.record("A secure subrole must be secure")
            return
        }
    }

    @Test("missing focus or unreadable classification stays unknown")
    func unreadable() async {
        let controls = SeatControls(copyAttributeValue: { _, _, _ in .cannotComplete })
        #expect(await controls.focusedField(in: 4244) == .unknown)
    }
}

extension SeatFocusedFieldTests {
    @Test("an explicitly editable custom control is ordinary")
    func editable() async {
        let controls = SeatControls(copyAttributeValue: { _, attribute, result in
            switch attribute as String {
                case "AXFocusedUIElement": result.pointee = AXUIElementCreateApplication(4245)
                case "AXRole": result.pointee = "AXGroup" as CFString
                case "AXSubrole": result.pointee = "AXUnknown" as CFString
                case "AXEditable": result.pointee = kCFBooleanTrue
                default: Issue.record("Unexpected attribute: \(attribute)"); return .attributeUnsupported
            }
            return .success
        })
        #expect(await controls.focusedField(in: 4245) == .ordinary(TargetIdentity(
            NativeAccessibilityIdentity.token(for: AXUIElementCreateApplication(4245))
        )))
    }

    @Test("the native scene preserves secure role and the focused node identity")
    func secureScene() throws {
        let root = AXUIElementCreateApplication(4246)
        let reader = SceneReader()
        let harvest = AccessibilityAugmentation.harvest(
            under: root, windowFrame: reader.windowFrame, reader: reader
        )
        let field = try #require(harvest.elements.first)
        #expect(field.role == "AXSecureTextField")
        #expect(field.value == nil)
        #expect(field.nativeIdentity == NativeAccessibilityIdentity.token(for: reader.field))
        let scene = SceneSnapshot(
            bundleID: "test.app", appName: "Test", windowTitle: "Editor",
            viewportPixelSize: .init(width: 800, height: 600), elements: harvest.elements
        )
        #expect(SeatControls.identities(in: scene)[field.id] == TargetIdentity(try #require(field.nativeIdentity)))
    }

    struct SceneReader: AccessibilityTreeReading {
        var isSecure = true
        var fieldRole = "AXTextField"
        var requiresValueClassification: Bool { true }
        let windowFrame = CGRect(x: 0, y: 0, width: 800, height: 600)
        var field: AXUIElement { AXUIElementCreateApplication(4247) }
        func role(_ node: AXUIElement) -> String? { CFEqual(node, field) ? fieldRole : "AXWindow" }
        func subrole(_ node: AXUIElement) -> String? { CFEqual(node, field) ? (isSecure ? "AXSecureTextField" : "AXUnknown") : nil }
        func title(_ node: AXUIElement) -> String? { "Password" }
        func descriptionText(_ node: AXUIElement) -> String? { nil }
        func identifier(_ node: AXUIElement) -> String? { nil }
        func value(_ node: AXUIElement) -> String? {
            if isSecure { Issue.record("Value read on secure field") }
            return nil
        }
        func numericValue(_ node: AXUIElement) -> Int? { Issue.record("Numeric value read"); return nil }
        func isEnabled(_ node: AXUIElement) -> Bool? { true }
        func actions(_ node: AXUIElement) -> [String] { [] }
        func frame(_ node: AXUIElement) -> CGRect? {
            CFEqual(node, field) ? CGRect(x: 10, y: 10, width: 200, height: 40) : windowFrame
        }
        func children(_ node: AXUIElement) -> [AXUIElement] { CFEqual(node, field) ? [] : [field] }
        func physicalIdentity(_ node: AXUIElement) -> String? { NativeAccessibilityIdentity.token(for: node) }
    }
}

extension SeatFocusedFieldTests {
    @Test("ordinary native fields share their scene identity with focus",
          arguments: ["AXTextField", "AXTextArea", "AXComboBox"])
    func ordinaryScene(role: String) async throws {
        let reader = SceneReader(isSecure: false, fieldRole: role)
        let harvest = AccessibilityAugmentation.harvest(
            under: AXUIElementCreateApplication(4246), windowFrame: reader.windowFrame, reader: reader
        )
        let field = try #require(harvest.elements.first)
        let pixel = SceneElement(
            id: "pixel", kind: .text, label: "Password", bounds: field.bounds
        )
        let merged = AccessibilityAugmentation.merge(pixels: [pixel], accessibility: harvest.elements)
        let native = try #require(merged.first { $0.role == role })
        let controls = SeatControls(copyAttributeValue: { _, attribute, result in
            switch attribute as String {
                case "AXFocusedUIElement": result.pointee = AXUIElementCreateApplication(4247)
                case "AXRole": result.pointee = role as CFString
                case "AXSubrole": result.pointee = "AXUnknown" as CFString
                default: Issue.record("Unexpected attribute: \(attribute)"); return .attributeUnsupported
            }
            return .success
        })
        #expect(await controls.focusedField(in: 4247) == .ordinary(TargetIdentity(try #require(native.nativeIdentity))))
    }

    @Test("missing or malformed classification never attests ordinary focus",
          arguments: ["AXFocusedUIElement", "AXRole", "AXSubrole"])
    func malformed(attribute failed: String) async {
        let controls = SeatControls(copyAttributeValue: { _, attribute, result in
            if attribute as String == failed {
                result.pointee = kCFBooleanTrue
                return .success
            }
            switch attribute as String {
                case "AXFocusedUIElement": result.pointee = AXUIElementCreateApplication(4248)
                case "AXRole": result.pointee = "AXTextField" as CFString
                case "AXSubrole": result.pointee = "AXUnknown" as CFString
                default: Issue.record("Unexpected attribute: \(attribute)"); return .attributeUnsupported
            }
            return .success
        })
        #expect(await controls.focusedField(in: 4248) == .unknown)
    }

    @Test("an exhausted time budget reads no attributes")
    func exhaustedBudget() async {
        let controls = SeatControls(budget: .init(deadline: .zero), copyAttributeValue: { _, attribute, _ in
            Issue.record("Read after deadline: \(attribute)")
            return .cannotComplete
        })
        #expect(await controls.focusedField(in: 4249) == .unknown)
    }

    @Test("native identity leaves scene encoding, equality and tokens unchanged")
    func ephemeralIdentity() throws {
        let plain = SceneElement(
            id: "field", kind: .control, label: "Editor",
            bounds: .init(x: 0, y: 0, width: 0.5, height: 0.1), role: "AXTextArea"
        )
        var native = plain
        native.nativeIdentity = "native:fixture"
        #expect(plain == native)
        #expect(Set([plain, native]).count == 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(plain) == encoder.encode(native))
        let decoded = try JSONDecoder().decode(SceneElement.self, from: encoder.encode(native))
        #expect(decoded.nativeIdentity == nil)
        func scene(_ elements: [SceneElement]) -> SceneSnapshot {
            SceneSnapshot(bundleID: "test.app", appName: "Test", windowTitle: "Editor",
                          viewportPixelSize: .init(width: 800, height: 600), elements: elements)
        }
        #expect(scene([plain]).token == scene([native]).token)
        #expect(SeatControls.identities(in: scene([plain])).isEmpty)
        #expect(SeatControls.identities(in: scene([native])) == ["field": TargetIdentity("native:fixture")])
        #expect(SeatControls.identities(in: scene([native, plain])).isEmpty)
    }
}

extension SeatFocusedFieldTests {
    @Test("a native reader without secure classification preserves unattested identities")
    func identityRequiresClassification() {
        let field = AXUIElementCreateApplication(4250)
        #expect(LiveAccessibilityReader().physicalIdentity(field) == nil)
        let guarded = LiveAccessibilityReader(valueGuard: ValueGuard(
            refusesLabel: { _ in false }, withholdsValue: { _, _ in false }
        ))
        #expect(guarded.physicalIdentity(field) == NativeAccessibilityIdentity.token(for: field))
        #expect(guarded.physicalIdentity(field) != NativeAccessibilityIdentity.token(
            for: AXUIElementCreateApplication(4251)
        ))
    }
}
