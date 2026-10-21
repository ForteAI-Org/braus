//
//  TextTargetTests.swift
//  Braus
//

import CoreGraphics
@testable import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

/// W1 typed secrets in the engine: what a fresh perception attests about where a text would go before the call
/// writes anything, and a bound dispatch that types only into the field it was classified for. Over the act
/// cycle's doubles; the identities are the doubles' own tokens, as a provider's would be.
@Suite("Text targets (W1 typed secrets)")
struct TextTargetTests {

    typealias ScriptedScenes    = ActionEngineTests.ScriptedScenes
    typealias RecordingActuator = ActionEngineTests.RecordingActuator
    typealias ScriptedWindows   = ActionEngineTests.ScriptedWindows
    typealias FakeControls      = ActionEngineTests.FakeControls

    private let pid: pid_t = 4242
    private let frame = CGRect(x: 100, y: 100, width: 1000, height: 800)
    private let mainWindow = WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800),
                                       title: "Form", number: 1)
    private let nodeA = TargetIdentity("double|tab|doc|12")
    private let nodeB = TargetIdentity("double|tab|doc|99")

    private func field(_ label: String = "Nome", role: String = "AXTextField", value: String? = "Ada") -> SceneElement {
        SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label,
                     bounds: NormalizedRect(x: 0.3, y: 0.4, width: 0.2, height: 0.03), role: role, value: value)
    }

    private func window(_ elements: [SceneElement], _ identities: [String: TargetIdentity] = [:]) -> PerceivedWindow {
        PerceivedWindow(scene: SceneSnapshot(bundleID: "web:fixture.test", appName: "fixture.test", windowTitle: "Form",
                                             viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600),
                                             elements: elements),
                        frame: frame, identities: identities)
    }

    private func engine(_ scenes: [PerceivedWindow], actuator: RecordingActuator = RecordingActuator(),
                        controls: FakeControls? = nil) -> ActionEngine {
        ActionEngine(ActionEngine.Dependencies(scenes: ScriptedScenes(scenes), actuator: actuator,
                                               windows: ScriptedWindows([[mainWindow]]), controls: controls),
                     pause: { _ in })
    }

    private func typing(_ text: String = "Grace", into target: String = "Nome", replacing: Bool = true,
                        binding: TextTargetBinding? = nil) -> InputRequest {
        InputRequest(processID: pid, bundleID: "web:fixture.test", appName: "fixture.test",
                     input: .typeText(text, into: target, replacing: replacing), binding: binding)
    }

    private func inserting(_ text: String, expecting: String? = nil, binding: TextTargetBinding? = nil) -> InputRequest {
        InputRequest(processID: pid, bundleID: "web:fixture.test", appName: "fixture.test",
                     input: .insertText(text, expecting: expecting), binding: binding)
    }

    private func typed(_ gestures: [Gesture]) -> Bool {
        gestures.contains { if case .type = $0 { true } else if case .insert = $0 { true } else { false } }
    }

    private var bound: TextTargetBinding { TextTargetBinding(identity: nodeA, role: "AXTextField", label: "Nome") }

    // MARK: Classification

    @Test("type_text: an attested ordinary field is ordinary, bound to its identity; a secure one is secure; no gesture")
    func classifiesTypeText() async {
        let nome = field()
        let actuator = RecordingActuator()
        let ordinary = await engine([window([nome], [nome.id: nodeA])], actuator: actuator).classify(typing())
        #expect(ordinary == .ordinary(TextTargetBinding(identity: nodeA, role: "AXTextField", label: "Nome")))
        let secure = field("Accesso", role: "AXSecureTextField", value: nil)
        #expect(await engine([window([secure], [secure.id: nodeA])]).classify(typing(into: "Accesso")) == .secure)
        #expect(actuator.gestures.isEmpty, "classifying sends nothing")
    }

    @Test("type_text: no identity, no element, two elements, a button or no scene: unclassified, each with its cause")
    func unclassifiedTypeText() async {
        let nome = field()
        #expect(await engine([window([nome])]).classify(typing()) == .unclassified(.identityUnattested),
                "the scene's element id is no physical identity")
        #expect(await engine([window([nome], [nome.id: nodeA])]).classify(typing(into: "Missing")) == .unclassified(.unresolved))
        var twin = field()
        twin.bounds = NormalizedRect(x: 0.3, y: 0.7, width: 0.2, height: 0.03)
        twin.id = "control|nome-2"
        #expect(await engine([window([nome, twin], [nome.id: nodeA, twin.id: nodeB])]).classify(typing())
                == .unclassified(.unresolved))
        let button = SceneElement(id: "control|send", kind: .control, label: "Send",
                                  bounds: NormalizedRect(x: 0.6, y: 0.4, width: 0.1, height: 0.03), role: "AXButton")
        #expect(await engine([window([button], [button.id: nodeA])]).classify(typing(into: "Send")) == .unclassified(.notTextEntry))
        #expect(await engine([]).classify(typing()) == .unclassified(.noScene))
    }

    @Test("insert_text: the attested focus classifies it; a focus the provider cannot attest is unclassified")
    func classifiesInsertText() async {
        let controls = FakeControls()
        controls.focus = [.ordinary(nodeA)]
        #expect(await engine([window([])], controls: controls).classify(inserting("Ada"))
                == .ordinary(TextTargetBinding(identity: nodeA, role: nil, label: "")))
        controls.focus = [.secure(nodeA)]
        #expect(await engine([window([])], controls: controls).classify(inserting("pw")) == .secure)
        controls.focus = [.unknown]
        #expect(await engine([window([])], controls: controls).classify(inserting("x")) == .unclassified(.focusUnknown))
        #expect(await engine([window([])]).classify(inserting("x")) == .unclassified(.focusUnknown), "no controls role")
    }

    // MARK: A bound dispatch

    @Test("bound: a node replaced in the same place, same label, role and bounds, is refused before any gesture")
    func replacedNodeIsRefused() async {
        let nome = field()
        let actuator = RecordingActuator()
        let outcome = await engine([window([nome], [nome.id: nodeB])], actuator: actuator).deliver(typing(binding: bound))
        #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
        #expect(actuator.gestures.isEmpty, "\(actuator.gestures)")
        #expect(outcome.message.contains("nothing was typed"), Comment(rawValue: outcome.message))
    }

    @Test("bound: the field became secure, or lost its identity, before the dispatch: refused before any gesture")
    func changedFieldIsRefused() async {
        let secure = field("Nome", role: "AXSecureTextField", value: nil)
        let actuator = RecordingActuator()
        let flipped = await engine([window([secure], [secure.id: nodeA])], actuator: actuator).deliver(typing(binding: bound))
        #expect(flipped.kind == .refused && actuator.gestures.isEmpty, Comment(rawValue: flipped.message))
        let unattested = await engine([window([field()])], actuator: actuator).deliver(typing(binding: bound))
        #expect(unattested.kind == .refused && actuator.gestures.isEmpty, Comment(rawValue: unattested.message))
    }

    @Test("bound: right after the click the focus is another node: only the click went out, a partial effect")
    func focusMovedAfterTheClick() async throws {
        let nome = field()
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.focus = [.ordinary(nodeB)]
        let outcome = await engine([window([nome], [nome.id: nodeA])], actuator: actuator, controls: controls)
            .deliver(typing(binding: bound))
        #expect(actuator.gestures.count == 1, "the click alone, before the selection's keys: \(actuator.gestures)")
        if case .click = actuator.gestures.first {} else { Issue.record("not the click: \(actuator.gestures)") }
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(outcome.message.contains("nothing was typed"), Comment(rawValue: outcome.message))
        let check = try #require(outcome.check)
        #expect(check.performed == .uncertain && check.limits.contains(.deliveryUncertain), "a partial delivery, not none")
        #expect(check.expected == nil)
        #expect(actuator.confirmations.contains(.unknown), "the receipt is closed as unknown, never replayed")
    }

    @Test("bound: right after the click the same node is now a password field: only the click went out")
    func typeFlippedAfterTheClick() async {
        let nome = field()
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.focus = [.secure(nodeA)]
        let outcome = await engine([window([nome], [nome.id: nodeA])], actuator: actuator, controls: controls)
            .deliver(typing(binding: bound))
        #expect(actuator.gestures.count == 1 && !typed(actuator.gestures), "\(actuator.gestures)")
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("nothing was typed"), Comment(rawValue: outcome.message))
    }

    @Test("bound: the focus holds after the click but not before the text: the click and the preparation key went out, no text")
    func focusMovedBeforeTheText() async {
        let nome = field()
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.focus = [.ordinary(nodeA), .ordinary(nodeB)]
        let outcome = await engine([window([nome], [nome.id: nodeA])], actuator: actuator, controls: controls)
            .deliver(typing(replacing: false, binding: bound))
        #expect(actuator.gestures.count == 2 && !typed(actuator.gestures), "click and end of field: \(actuator.gestures)")
        #expect(controls.focusReads == 2, "checked after the click and again before the text")
        #expect(outcome.kind == .actedUnverified && outcome.message.contains("nothing was typed"), Comment(rawValue: outcome.message))
    }

    @Test("bound and aimed: the click names its field to the actuator, and a surface change refused after it types nothing")
    func boundTextOverAnAttestedSurface() async throws {
        let nome = field()
        let actuator = RecordingActuator()
        // The actuator binds the input to the surface its first gesture reached (the Seat's `input_target_changed`).
        actuator.failure = GestureNotSent(reason: "input_target_changed", sentence: "The window changed during this input.")
        actuator.failsFrom = 1
        let controls = FakeControls()
        controls.focus = [.ordinary(nodeA)]
        let outcome = await engine([window([nome], [nome.id: nodeA])], actuator: actuator, controls: controls)
            .deliver(typing(binding: bound))
        #expect(actuator.labels == ["Nome"], "the field's click is aimed at the field the scene named")
        #expect(controls.focusReads == 1, "the focus held after the click; the surface refused the next gesture")
        #expect(actuator.gestures.count == 1 && !typed(actuator.gestures), "\(actuator.gestures)")
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        let check = try #require(outcome.check)
        #expect(check.performed == .uncertain && check.limits.contains(.deliveryUncertain), "the click went out: uncertain")
        #expect(actuator.confirmations == [.unknown], "closed as unknown once, never replayed")
    }

    @Test("bound and coherent: the focus is the bound node, the text goes out and is read back as today")
    func boundAndCoherent() async {
        let nome = field()
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.focus = [.ordinary(nodeA)]
        controls.focused = "Grace"
        let outcome = await engine([window([nome], [nome.id: nodeA]), window([field(value: "Grace")], [nome.id: nodeA])],
                                   actuator: actuator, controls: controls).deliver(typing(binding: bound))
        #expect(typed(actuator.gestures))
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(controls.focusReads >= 1, "the focus was read before the keys")
    }

    @Test("bound insert_text: a focus that is not the bound node is refused before anything is sent")
    func boundInsertMismatch() async {
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.focus = [.ordinary(nodeB)]
        let outcome = await engine([window([])], actuator: actuator, controls: controls)
            .deliver(inserting("Ada", binding: TextTargetBinding(identity: nodeA, role: nil, label: "")))
        #expect(outcome.kind == .refused && actuator.gestures.isEmpty, Comment(rawValue: outcome.message))
    }

    @Test("insert_text into a secure focus: never read back; its expected value is kept out of the check")
    func insertIntoSecureFocus() async throws {
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.focus = [.secure(nil)]
        controls.focused = "Prefilled-Secret-4417"
        let outcome = await engine([window([])], actuator: actuator, controls: controls)
            .deliver(inserting("typed-pw", expecting: "typed-pw"))
        #expect(!outcome.message.contains("Prefilled-Secret-4417") && !outcome.message.contains("typed-pw"),
                Comment(rawValue: outcome.message))
        let check = try #require(outcome.check)
        #expect(check.expected == nil && check.observed == nil)
        #expect(check.limits.contains(.valueWithheld))
    }

    @Test("insert_text at a focus no provider attests: not read back, no expected or observed value, even when delivery fails")
    func insertIntoUnattestedFocus() async throws {
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.focused = "Readback-Sentinel-55"
        let outcome = await engine([window([])], actuator: actuator, controls: controls)
            .deliver(inserting("typed-pw", expecting: "Expected-Sentinel-55"))
        #expect(outcome.kind == .actedUnverified, Comment(rawValue: outcome.message))
        #expect(!outcome.message.contains("Readback-Sentinel-55") && !outcome.message.contains("Expected-Sentinel-55"))
        let check = try #require(outcome.check)
        #expect(check.expected == nil && check.observed == nil && check.limits.contains(.valueWithheld), "\(check)")
        let none = await engine([window([])]).deliver(inserting("typed-pw", expecting: "Expected-Sentinel-55"))
        #expect(none.check?.expected == nil && none.check?.observed == nil, "no controls role: \(String(describing: none.check))")
        let failing = RecordingActuator()
        failing.failure = CocoaError(.userCancelled)
        let failed = await engine([window([])], actuator: failing, controls: controls)
            .deliver(inserting("typed-pw", expecting: "Expected-Sentinel-55"))
        #expect(failed.message.contains("delivery failed") && failed.check?.expected == nil, "\(String(describing: failed.check))")
    }

    @Test("a text the call withholds: read back and judged, but no value quoted in the answer and none kept in the check")
    func withheldTextIsNotQuoted() async throws {
        let nome = field()
        let controls = FakeControls()
        controls.focused = "Withheld-Sentinel-31"
        var request = typing("Withheld-Sentinel-31")
        request.withholdsText = true
        let outcome = await engine([window([nome]), window([field(value: "Withheld-Sentinel-31")])], controls: controls)
            .deliver(request)
        #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(!outcome.message.contains("Withheld-Sentinel-31") && !outcome.message.contains("Ada"), Comment(rawValue: outcome.message))
        let check = try #require(outcome.check)
        #expect(check.verdict == .passed && check.expected == nil && check.observed == nil && check.limits.contains(.valueWithheld))
        controls.focus = [.ordinary(nodeA)]
        var inserting = inserting("Inserted-Sentinel-31", expecting: "Inserted-Sentinel-31")
        inserting.withholdsText = true
        controls.focused = "Inserted-Sentinel-31"
        let inserted = await engine([window([])], controls: controls).deliver(inserting)
        #expect(inserted.kind == .foundActed && !inserted.message.contains("Inserted-Sentinel-31"), Comment(rawValue: inserted.message))
        #expect(inserted.check?.expected == nil && inserted.check?.observed == nil && inserted.check?.verdict == .passed)
    }

    @Test("a long text: unwithheld, the answer quotes its first 59 characters; withheld, no form of it at all")
    func longTextPrefix() async throws {
        let long = "Lungo-" + String(repeating: "abcdefghij", count: 8) + "-Sentinel-77"
        let prefix = String(long.prefix(59))
        for withholds in [false, true] {
            let controls = FakeControls()
            controls.focused = long
            var request = typing(long)
            request.withholdsText = withholds
            let outcome = await engine([window([field()]), window([field(value: long)])], controls: controls).deliver(request)
            #expect(outcome.kind == .foundActed, Comment(rawValue: outcome.message))
            #expect(outcome.message.contains(prefix) == !withholds, "withheld: \(withholds): \(outcome.message)")
        }
    }

    @Test("unbound type_text, as before W1's increment: no focus read, typed and read back")
    func unboundUnchanged() async {
        let nome = field()
        let actuator = RecordingActuator()
        let controls = FakeControls()
        controls.focused = "Grace"
        let outcome = await engine([window([nome]), window([field(value: "Grace")])], actuator: actuator, controls: controls)
            .deliver(typing())
        #expect(typed(actuator.gestures) && outcome.kind == .foundActed, Comment(rawValue: outcome.message))
        #expect(controls.focusReads == 0)
    }
}
