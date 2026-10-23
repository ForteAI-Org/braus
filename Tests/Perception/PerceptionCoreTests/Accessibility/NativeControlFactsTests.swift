import CoreGraphics
import Foundation
@testable import PerceptionCore
import Testing

@Suite("Raw native facts remain distinct from qualified state")
struct NativeControlFactsTests {

    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)

    private struct Reader: AccessibilityTreeReading {
        let facts: [Int: NativeControlFacts]

        func role(_ node: Int) -> String? {
            if node == 0 { return "AXWindow" }
            guard case .value(.string(let role)) = facts[node]?.role else { return nil }
            return role
        }
        func subrole(_ node: Int) -> String? { nil }
        func title(_ node: Int) -> String? { node == 0 ? "Fixture" : "Shared control" }
        func descriptionText(_ node: Int) -> String? { nil }
        func identifier(_ node: Int) -> String? { nil }
        func value(_ node: Int) -> String? {
            guard case .value(.string(let value)) = facts[node]?.value else { return nil }
            return value
        }
        func numericValue(_ node: Int) -> Int? { nil }
        func isSelected(_ node: Int) -> Bool? {
            guard case .value(.boolean(let selected)) = facts[node]?.selected else { return nil }
            return selected
        }
        func nativeControlFacts(_ node: Int, isPastDeadline: @Sendable () -> Bool) -> NativeControlFacts? {
            isPastDeadline() ? nil : facts[node]
        }
        func isEnabled(_ node: Int) -> Bool? { true }
        func actions(_ node: Int) -> [String] { ["AXPress"] }
        func frame(_ node: Int) -> CGRect? {
            node == 0 ? CGRect(x: 100, y: 100, width: 1000, height: 800)
                : CGRect(x: node == 1 ? 200 : 600, y: 200, width: 100, height: 30)
        }
        func children(_ node: Int) -> [Int] { node == 0 ? facts.keys.sorted() : [] }
    }

    private func facts(value: NativeAttributeReading, role: String = "AXButton") -> NativeControlFacts {
        NativeControlFacts(role: .value(.string(role)), subrole: .value(.string("AXToggle")),
                           value: value, selected: .value(.boolean(false)), ownerProcessID: 42)
    }

    @Test("empty, selected text and negative selected flags remain raw facts without off inference",
          arguments: [NativeAttributeReading.value(.string("")), .value(.string("Selected")),
                      .noValue, .unsupported, .timedOut, .failed(code: -25202)])
    func rawFactsDoNotSetState(value: NativeAttributeReading) throws {
        let observation = NativeControlObservation(observationID: UUID(), processID: 42,
                                                    windowNumber: 7, windowFrame: frame)
        let harvest = AccessibilityAugmentation.harvest(
            under: 0, windowFrame: frame, reader: Reader(facts: [1: facts(value: value)]),
            observation: observation
        )
        let element = try #require(harvest.elements.first)
        #expect(element.state == nil)
        #expect(element.nativeFacts?.value == value)
        #expect(element.nativeFacts?.observation == observation)
        #expect(element.nativeFacts?.belongs(to: observation) == true)
    }

    @Test("facts stay with their own widget through native/pixel merging and scene encoding")
    func identityAndRendering() throws {
        let observation = NativeControlObservation(observationID: UUID(), processID: 42,
                                                    windowNumber: 7, windowFrame: frame)
        let raw: [NativeAttributeReading] = [.value(.string("")), .value(.string("Selected\nstate"))]
        let harvest = AccessibilityAugmentation.harvest(
            under: 0, windowFrame: frame,
            reader: Reader(facts: [1: facts(value: raw[0]), 2: facts(value: raw[1])]),
            observation: observation
        )
        let pixels = harvest.elements.map {
            SceneElement(id: "pixel-\($0.bounds.x)", kind: .text, label: $0.label, bounds: $0.bounds)
        }
        let merged = AccessibilityAugmentation.merge(pixels: pixels, accessibility: harvest.elements)
            .sorted { $0.bounds.x < $1.bounds.x }
        #expect(merged.count == 2)
        #expect(merged.map { $0.nativeFacts?.value } == raw.map(Optional.some))
        let scene = SceneSnapshot(bundleID: "example.fixture", appName: "Fixture", windowTitle: "Fixture",
                                  viewportPixelSize: .init(width: 1000, height: 800), elements: merged)
        let encoded = try JSONEncoder().encode(scene)
        let decoded = try JSONDecoder().decode(SceneSnapshot.self, from: encoded)
        #expect(decoded.elements.map(\.nativeFacts) == merged.map(\.nativeFacts))
        #expect(decoded.token == scene.token)
        #expect(scene.text().contains("native-raw"))
        #expect(scene.text().contains("value=string:\"\""))
        #expect(scene.text().contains("Selected\\nstate"))
        #expect(!scene.text().contains("Selected\nstate"))
    }

    @Test("a different read, owner, window or frame cannot reuse the observation qualification")
    func observationScope() {
        let expected = NativeControlObservation(observationID: UUID(), processID: 42,
                                               windowNumber: 7, windowFrame: frame)
        var raw = facts(value: .value(.string("Selected")))
        raw.observation = expected
        for other in [
            NativeControlObservation(observationID: UUID(), processID: 42, windowNumber: 7, windowFrame: frame),
            NativeControlObservation(observationID: expected.observationID, processID: 43, windowNumber: 7, windowFrame: frame),
            NativeControlObservation(observationID: expected.observationID, processID: 42, windowNumber: 8, windowFrame: frame),
            NativeControlObservation(observationID: expected.observationID, processID: 42, windowNumber: nil, windowFrame: frame),
            NativeControlObservation(observationID: expected.observationID, processID: 42, windowNumber: 7,
                                     windowFrame: frame.offsetBy(dx: 10, dy: 0)),
        ] {
            #expect(!raw.belongs(to: other))
        }
        raw.observation = nil
        #expect(!raw.belongs(to: expected))
    }

    @Test("geometry-only reads and legacy scenes do not claim attested native provenance")
    func legacyAndGeometry() throws {
        let unbound = NativeControlObservation(observationID: UUID(), processID: 42,
                                              windowNumber: nil, windowFrame: frame)
        var raw = facts(value: .value(.string("")))
        raw.observation = unbound
        #expect(!raw.belongs(to: unbound))
        #expect(raw.diagnosticText.contains("window=unattested"))
        let element = SceneElement(id: "old", kind: .control, label: "Control",
                                   bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        let decoded = try JSONDecoder().decode(SceneElement.self, from: JSONEncoder().encode(element))
        #expect(decoded.nativeFacts == nil)
        #expect(decoded == element)
    }

    @Test("native raw facts are not harvested from editable text fields")
    func noAdditionalTextFieldContent() throws {
        let harvest = AccessibilityAugmentation.harvest(
            under: 0, windowFrame: frame,
            reader: Reader(facts: [1: facts(value: .value(.string("private")), role: "AXTextField")])
        )
        #expect(try #require(harvest.elements.first).nativeFacts == nil)
    }
    @Test("semantic facts invalidate scene identity while a new read UUID alone does not")
    func semanticIdentity() {
        let first = NativeControlObservation(observationID: UUID(), processID: 42, windowNumber: 7, windowFrame: frame)
        let second = NativeControlObservation(observationID: UUID(), processID: 42, windowNumber: 7, windowFrame: frame)
        var off = facts(value: .value(.string("")))
        off.observation = first
        var repeated = off
        repeated.observation = second
        var on = facts(value: .value(.string("Selected")))
        on.observation = second
        func scene(_ raw: NativeControlFacts) -> SceneSnapshot {
            SceneSnapshot(bundleID: "fixture", appName: "Fixture", windowTitle: "Fixture",
                          viewportPixelSize: .init(width: 1000, height: 800), elements: [
                            SceneElement(id: "toggle", kind: .control, label: "Control",
                                         bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1), nativeFacts: raw),
                          ])
        }
        #expect(scene(off).elements == scene(repeated).elements)
        #expect(scene(off).elements.hashValue == scene(repeated).elements.hashValue)
        #expect(scene(off).token == scene(repeated).token)
        #expect(scene(off).elements != scene(on).elements)
        #expect(scene(off).token != scene(on).token)
        let unknownOwner = NativeControlFacts(role: off.role, subrole: off.subrole, value: off.value,
                                              selected: off.selected, observation: first)
        let foreignOwner = NativeControlFacts(role: off.role, subrole: off.subrole, value: off.value,
                                              selected: off.selected, ownerProcessID: 43, observation: first)
        #expect(!unknownOwner.belongs(to: first))
        #expect(!foreignOwner.belongs(to: first))
    }

    @Test("display truncation is explicit and full raw JSON remains available")
    func boundedDisplay() throws {
        let text = String(repeating: "x", count: 500)
        let raw = facts(value: .value(.string(text)))
        #expect(raw.diagnosticText.contains("truncated 436 Unicode scalars"))
        #expect(!raw.diagnosticText.contains(text))
        let decoded = try JSONDecoder().decode(NativeControlFacts.self, from: JSONEncoder().encode(raw))
        #expect(decoded.value == .value(.string(text)))
        let changed = facts(value: .value(.string(String(repeating: "x", count: 499) + "y")))
        #expect(changed.diagnosticText == raw.diagnosticText)
        func token(_ value: NativeControlFacts) -> SceneToken {
            SceneToken(bundleID: "fixture", windowTitle: "Fixture", elements: [
                SceneElement(id: "control", kind: .control, label: "Control",
                             bounds: .init(x: 0.1, y: 0.1, width: 0.1, height: 0.1), nativeFacts: value),
            ])
        }
        #expect(token(changed) != token(raw))
        let combining = facts(value: .value(.string("x" + String(repeating: "\u{0301}", count: 10_000))))
        #expect(combining.diagnosticText.utf8.count < 1000)
        #expect(combining.diagnosticText.contains("truncated"))
        let roundTrip = try JSONDecoder().decode(NativeControlFacts.self, from: JSONEncoder().encode(combining))
        #expect(roundTrip.value == combining.value)
    }

}
