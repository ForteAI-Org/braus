//
//  BrainMemoryDeliveryTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import CoreGraphics
import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// FailingRelations answers like `RelationsDouble` until it is told to fail, and then throws on every
/// read, as a store that cannot be read does. Nothing here is the store.
actor FailingRelations: BrainRelationReading {

    struct Unreadable: Error, CustomStringConvertible {
        var description: String { "disk I/O error in SELECT relation_id FROM brain_relations WHERE secret-canary" }
    }

    private let state: String?
    private var stored: [BrainRelation] = []
    private var failing = false

    init(state: String?) { self.state = state }

    func set(_ relations: [BrainRelation]) { stored = relations }
    func fail(_ on: Bool) { failing = on }

    func state(of skeleton: SceneSkeleton, isComplete: Bool, in bundleID: String) async throws -> String? {
        if failing { throw Unreadable() }
        return state
    }

    func state(of sample: CaptureSampleKey) async throws -> String? {
        if failing { throw Unreadable() }
        return state
    }

    func relations(from sceneID: String, in bundleID: String, elementKeys: [String],
                   includingContext: Bool) async throws -> [BrainRelation] {
        if failing { throw Unreadable() }
        return stored.filter { $0.key.fromSceneID == sceneID && ($0.key.elementKey.map(elementKeys.contains) ?? includingContext) }
    }
}

/// SpyBrains counts how the projection is read: whole (`brain(of:)`) or by the keys of a scene
/// (`projection(of:for:)`), and answers the part it holds.
actor SpyBrains: BrainReading, BrainApplicationStoring {

    private(set) var wholeReads = 0
    private(set) var partReads = 0
    private let brain: UIBrain

    init(_ brain: UIBrain) { self.brain = brain }

    func brain(of bundleID: String) async throws -> UIBrain? {
        wholeReads += 1
        return brain
    }

    func projection(of bundleID: String, for detections: [BrainDetection]) async throws -> UIBrain? {
        partReads += 1
        return brain
    }

    func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
        BrainApplicationResult(receipt: .committed, applicationID: 1, outcome: .noEffect, requestedAtMS: 0, effectiveAtMS: 0)
    }

    func application(_ key: BrainApplicationKey) async throws -> BrainApplication? { nil }
}

/// What reaches the scene a model reads (F01, F02, F05, F08 of the review): nothing learned crosses an
/// element the structure does not identify; the operations learned on the window itself are delivered
/// with their conditions, rendered and in the changes; a read that fails leaves the live scene and says
/// so, without the error; and the ordinary enrichment reads only the part of the projection its scene
/// can match.
@Suite("What the memory delivers with a scene")
struct BrainMemoryDeliveryTests {

    private let bundle = "com.example.Editor"

    private func scene(_ elements: [SceneElement]) -> SceneSnapshot {
        SceneSnapshot(bundleID: bundle, appName: "Editor", windowTitle: "Document",
                      viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements)
    }

    private func window(_ elements: [SceneElement]) -> PerceivedWindow {
        PerceivedWindow(scene: scene(elements), frame: .zero, capture: .unknown, surface: .window)
    }

    private func field(_ value: String, x: Double) -> SceneElement {
        SceneElement(id: "field|\(x)", kind: .control, label: value, bounds: NormalizedRect(x: x, y: 0.3, width: 0.2, height: 0.04),
                     role: "AXTextField", labelOrigin: .value)
    }

    private let export = SceneElement(id: "control|export", kind: .control, label: "Export", bounds: Fixtures.rect(0.1, 0.1, 0.05, 0.02),
                                      role: "AXButton", labelOrigin: .title)
    private let text = SceneElement(id: "text|1", kind: .text, label: "Untitled document", bounds: Fixtures.rect(0.2, 0.4, 0.5, 0.05),
                                    role: "AXStaticText")

    private func relation(_ element: String?, _ verb: BrainVerb, arguments: String = "", supports: Int = 2,
                          outcome: BrainRelationOutcome = .effect, effect: String? = "elementsAppeared") -> BrainRelation {
        let key = BrainRelationKey(bundleID: bundle, contextID: nil, fromSceneID: "S", elementKey: element, verb: verb,
                                   argumentsKey: arguments, toSceneID: "S", outcome: outcome, effectKind: effect)
        return BrainRelation(relationID: key.relationID, key: key, firstSeenMS: 0, lastSeenMS: 1, supports: supports, contradictions: 0)
    }

    @Test("an element the structure does not tell from another gets no expectation and no relation, whatever was learned on its template")
    func noKnowledgeAcrossAnAmbiguity() async throws {
        let name = field("photo.png", x: 0.1), destination = field("/tmp", x: 0.6)
        let nameCapture = try #require(CaptureElement(name))
        let template = try #require(SceneElementKey.key(of: nameCapture))
        let relations = RelationsDouble(state: "S")
        await relations.set([relation(template, .click), relation(template, .typeText, arguments: "replace=true", outcome: .valueSet,
                                                                   effect: nil)])
        let store = InMemoryBrainStore()
        let memory = BrainMemory(brains: store, applications: store, relations: relations, clock: { Fixtures.t0 })
        let shown = window([name, destination, export])
        #expect(await memory.expectedEffect(of: .click, on: name, in: shown) == nil)
        #expect(await memory.expectedEffect(of: .click, on: destination, in: shown) == nil)
        let enriched = await memory.enrich(scene([name, destination, export]), state: "S")
        #expect(enriched.elements[0].does == nil && enriched.elements[1].does == nil)
        #expect(enriched.knowledge?.status == .nothing, "nothing learned applies to an identified element of this state")
        // Alone in its window, the same field is identified, and what was learned on it applies.
        let alone = window([name, export])
        #expect(await memory.expectedEffect(of: .click, on: name, in: alone) == .elementsAppeared(labels: []))
    }

    @Test("the operations learned on the window itself reach the scene a model reads, rendered and in its changes: a shortcut, an insertion on the focus, a scroll of the window, in a window with no structural control")
    func windowOperationsDelivered() async throws {
        let relations = RelationsDouble(state: "S")
        await relations.set([
            relation(nil, .pressKey, arguments: "key=s;modifiers=cmd;count=1", effect: "windowTitleChanged"),
            relation(nil, .insertText, outcome: .valueSet, effect: nil),
            relation(nil, .scroll, arguments: "direction=down;over=window"),
            relation(nil, .menu, arguments: "path=file>export", supports: 1, outcome: .windowSetChanged, effect: nil),
        ])
        let store = InMemoryBrainStore()
        let memory = BrainMemory(brains: store, applications: store, relations: relations, clock: { Fixtures.t0 })
        let original = scene([text])
        let enriched = await memory.enrich(original, state: "S")
        #expect(enriched.token == original.token && enriched.elements == original.elements, "the live scene is untouched")
        let knowledge = try #require(enriched.knowledge)
        #expect(knowledge.status == .applied)
        #expect(knowledge.window.count == 3, "a relation below its threshold is kept and not offered: \(knowledge.window)")
        #expect(knowledge.window.contains { $0.hasPrefix("press_key [key=s;modifiers=cmd;count=1]: windowTitleChanged")
                                               && $0.hasSuffix("acts on the focused element, which was not recorded") })
        #expect(knowledge.window.contains { $0.hasPrefix("insert_text (any text, any expected_value): sets its value")
                                               && $0.contains("focused element") })
        #expect(knowledge.window.contains { $0.contains("scroll [direction=down;over=window] (any lines)") && $0.hasSuffix("over the window") })
        let rendered = enriched.text()
        #expect(rendered.contains("memory: what was learned in this window's state is shown"))
        #expect(rendered.contains("  window: press_key [key=s;modifiers=cmd;count=1]"))
        #expect(enriched.mapText().contains("  window: scroll"), "the map a model reads first carries it too")
        let changes = SceneChanges.text(from: original, to: enriched, since: 1)
        #expect(changes.contains("  window: insert_text"), "a scene whose only change is what the memory says shows it: \(changes)")
        let encoded = String(decoding: try JSONEncoder().encode(enriched), as: UTF8.self)
        #expect(encoded.contains("\"memory\"") && encoded.contains("press_key"))
        let decoded = try JSONDecoder().decode(SceneSnapshot.self, from: Data(encoded.utf8))
        #expect(decoded == enriched)
    }

    @Test("a read that fails keeps the live scene and token and says the memory is unavailable, with no error in it; the next read says what it finds, with nothing left over")
    func failedReadIsSaid() async throws {
        let relations = FailingRelations(state: "S")
        let exportCapture = try #require(CaptureElement(export))
        let key = try #require(SceneElementKey.key(of: exportCapture))
        await relations.set([relation(key, .click)])
        let store = InMemoryBrainStore()
        let memory = BrainMemory(brains: store, applications: store, relations: relations, clock: { Fixtures.t0 })
        let original = scene([export])
        await relations.fail(true)
        let failed = await memory.enrich(original, window: window([export]))
        #expect(failed.elements == original.elements && failed.token == original.token)
        #expect(failed.knowledge?.status == .unavailable)
        #expect(!failed.text().contains("secret-canary") && !failed.text().contains("SELECT"), "the error stays local")
        #expect(await memory.expectedEffect(of: .click, on: export, in: window([export])) == nil)
        let diagnostics = await memory.diagnostics()
        #expect(diagnostics.failedReads == 2 && diagnostics.lastFailure?.contains("disk I/O") == true)
        await relations.fail(false)
        let recovered = await memory.enrich(failed, window: window([export]))
        #expect(recovered.knowledge?.status == .applied && recovered.elements[0].does?.hasPrefix("click: elementsAppeared") == true)
        // A state not recognized and a recognized state with nothing learned are said apart.
        let unrecognized = BrainMemory(brains: store, applications: store, relations: RelationsDouble(state: nil), clock: { Fixtures.t0 })
        #expect(await unrecognized.enrich(original, window: window([export])).knowledge?.status == .unrecognized)
        let empty = BrainMemory(brains: store, applications: store, relations: RelationsDouble(state: "S"), clock: { Fixtures.t0 })
        #expect(await empty.enrich(recovered, window: window([export])).elements[0].does == nil,
                "an annotation of an earlier read is not carried over")
        #expect(await empty.enrich(original, window: window([export])).knowledge?.status == .nothing)
    }

    @Test("the ordinary enrichment reads the part of the projection its scene can match, never the whole projection, and still recalls a taught label")
    func targetedProjection() async throws {
        let icon = SceneElement(id: "icon|1", kind: .icon, label: "icon at 0.4,0.1", bounds: Fixtures.rect(0.4, 0.1, 0.02, 0.02),
                                isUnlabeled: true)
        let named = ObjectAnchor(kind: .icon, label: "Mixer", labelSource: .llm, boundsTypical: icon.bounds, firstSeen: Fixtures.t0,
                                 lastSeen: Fixtures.t0)
        let spy = SpyBrains(UIBrain(objects: [named]))
        let relations = RelationsDouble(state: "S")
        let memory = BrainMemory(brains: spy, applications: spy, relations: relations, clock: { Fixtures.t0 })
        let shown = scene([export, icon])
        let enriched = await memory.enrich(shown, window: window([export, icon]))
        _ = await memory.enrich(shown, state: "S")
        _ = await memory.enrich(shown)
        _ = await memory.expectedEffect(of: .click, on: export, in: window([export, icon]))
        #expect(await spy.wholeReads == 0, "no ordinary path reads an application's whole projection")
        #expect(await spy.partReads == 3)
        #expect(enriched.elements[1].label == "Mixer" && enriched.elements[1].isRecalled, "the taught label is recalled")
    }
}
