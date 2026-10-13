//
//  BrainMemoryDegradationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import CoreGraphics
import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// FaultyMemory reads like a healthy store, a projection that recalls a taught icon's label, the state
/// of every capture and the relations of that state, until some of its reads are told to fail, as a store
/// that cannot be read does. Its error names a query and a canary, which must never reach a scene.
actor FaultyMemory: BrainReading, BrainApplicationStoring, BrainRelationReading {

    enum Read: String, CaseIterable, Sendable { case projection, state, relations }

    struct Unreadable: Error, CustomStringConvertible {
        var description: String { "SQLITE_IOERR in SELECT label FROM brain_anchors WHERE label = 'secret-canary'" }
    }

    private let brain: UIBrain
    private let stored: [BrainRelation]
    private var failing: Set<Read> = []

    init(brain: UIBrain, relations: [BrainRelation]) {
        self.brain  = brain
        self.stored = relations
    }

    func fail(_ reads: Set<Read>) { failing = reads }

    func brain(of bundleID: String) async throws -> UIBrain? {
        if failing.contains(.projection) { throw Unreadable() }
        return brain
    }

    func projection(of bundleID: String, for detections: [BrainDetection]) async throws -> UIBrain? {
        if failing.contains(.projection) { throw Unreadable() }
        return brain
    }

    func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
        BrainApplicationResult(receipt: .committed, applicationID: 1, outcome: .noEffect, requestedAtMS: 0, effectiveAtMS: 0)
    }

    func application(_ key: BrainApplicationKey) async throws -> BrainApplication? { nil }

    func state(of skeleton: SceneSkeleton, isComplete: Bool, in bundleID: String) async throws -> String? {
        if failing.contains(.state) { throw Unreadable() }
        return "S"
    }

    func state(of sample: CaptureSampleKey) async throws -> String? {
        if failing.contains(.state) { throw Unreadable() }
        return "S"
    }

    func relations(from sceneID: String, in bundleID: String, elementKeys: [String],
                   includingContext: Bool) async throws -> [BrainRelation] {
        if failing.contains(.relations) { throw Unreadable() }
        return stored.filter { $0.key.fromSceneID == sceneID && ($0.key.elementKey.map(elementKeys.contains) ?? includingContext) }
    }
}

/// What a scene says when a read its enrichment needs fails (review F05b): the live scene, its elements
/// as perceived and its token, with nothing of the memory on it, no recalled label, no group, no
/// relation on an element, no operation of the window, and `memory: unavailable`, whichever read failed:
/// the part of the projection, the state or the relations. What it shows and what it says agree, in the
/// scene, its rendering and its changes, and the next healthy read says all it finds, nothing left over.
@Suite("A memory that cannot be read leaves the live scene, and says so")
struct BrainMemoryDegradationTests {

    private static let bundle = "com.example.Editor"

    private static let export = SceneElement(id: "control|export", kind: .control, label: "Export",
                                             bounds: Fixtures.rect(0.1, 0.1, 0.05, 0.02), role: "AXButton", labelOrigin: .title)
    private static let icon = SceneElement(id: "icon|1", kind: .icon, label: "icon at 0.4,0.1",
                                           bounds: Fixtures.rect(0.4, 0.1, 0.02, 0.02), isUnlabeled: true)
    private static let text = SceneElement(id: "text|1", kind: .text, label: "Untitled document",
                                           bounds: Fixtures.rect(0.2, 0.4, 0.5, 0.05), role: "AXStaticText")

    private static func scene() -> SceneSnapshot {
        SceneSnapshot(bundleID: bundle, appName: "Editor", windowTitle: "Document",
                      viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: [export, icon, text])
    }

    private static func window(_ scene: SceneSnapshot) -> PerceivedWindow {
        PerceivedWindow(scene: scene, frame: .zero, capture: .unknown, surface: .window)
    }

    /// A store that recalls the icon as Mixer, knows a click on Export and a shortcut of the window.
    private static func memory() throws -> FaultyMemory {
        let named = ObjectAnchor(kind: .icon, label: "Mixer", labelSource: .llm, boundsTypical: icon.bounds, firstSeen: Fixtures.t0,
                                 lastSeen: Fixtures.t0)
        let capture = try #require(CaptureElement(export))
        let exportKey = try #require(SceneElementKey.key(of: capture))
        func relation(_ element: String?, _ verb: BrainVerb, _ arguments: String, _ effect: String) -> BrainRelation {
            let key = BrainRelationKey(bundleID: bundle, contextID: nil, fromSceneID: "S", elementKey: element, verb: verb,
                                       argumentsKey: arguments, toSceneID: "S", outcome: .effect, effectKind: effect)
            return BrainRelation(relationID: key.relationID, key: key, firstSeenMS: 0, lastSeenMS: 1, supports: 2, contradictions: 0)
        }
        return FaultyMemory(brain: UIBrain(objects: [named]), relations: [
            relation(exportKey, .click, "", "menuOpened"),
            relation(nil, .pressKey, "key=s;modifiers=cmd;count=1", "windowTitleChanged"),
        ])
    }

    @Test("whichever read fails, the scene is the live one with nothing of the memory and says it is unavailable, in its text and its changes; the next healthy read says all it finds",
          arguments: FaultyMemory.Read.allCases)
    func failedReadLeavesTheLiveScene(_ read: FaultyMemory.Read) async throws {
        let store = try Self.memory()
        let memory = BrainMemory(brains: store, applications: store, relations: store, clock: { Fixtures.t0 })
        let live = Self.scene()

        let healthy = await memory.enrich(live, window: Self.window(live))
        #expect(healthy.knowledge?.status == .applied && healthy.knowledge?.window.count == 1)
        #expect(healthy.elements[0].does?.hasPrefix("click: menuOpened") == true && healthy.elements[1].label == "Mixer")

        await store.fail([read])
        let degraded = await memory.enrich(live, window: Self.window(live))
        #expect(degraded.knowledge == SceneKnowledge(status: .unavailable), "\(read): no operation of the window either")
        #expect(degraded.elements == live.elements && degraded.token == live.token, "\(read): the live perception, nothing of the memory")
        let rendered = degraded.text()
        #expect(rendered.contains("memory: unavailable right now; the scene is live, what was learned is not shown"))
        for absent in ["Mixer", "click:", "window:", "secret-canary", "SQLITE", "SELECT"] {
            #expect(!rendered.contains(absent), "\(read): \(absent) in \(rendered)")
        }
        let changes = SceneChanges.text(from: healthy, to: degraded, since: 1)
        #expect(changes.contains("memory: unavailable right now") && !changes.contains("window:") && !changes.contains("secret-canary"),
                "\(read): \(changes)")
        // Enriching again what an earlier read annotated leaves no annotation of it behind.
        let again = await memory.enrich(healthy, window: Self.window(healthy))
        #expect(again.knowledge == SceneKnowledge(status: .unavailable) && again.elements.allSatisfy { $0.does == nil })
        let diagnostics = await memory.diagnostics()
        #expect(diagnostics.failedReads == 2 && diagnostics.lastFailure?.contains("SQLITE_IOERR") == true)

        await store.fail([])
        let recovered = await memory.enrich(degraded, window: Self.window(degraded))
        #expect(recovered == healthy, "a healthy read again says all it finds, from the live scene")
    }

    @Test("a projection that cannot be read leaves the scene unannotated also without a state to place it in, and when the caller placed it")
    func projectionFailureOnEveryEntry() async throws {
        let store = try Self.memory()
        let memory = BrainMemory(brains: store, applications: store, relations: store, clock: { Fixtures.t0 })
        let live = Self.scene()
        await store.fail([.projection])
        for degraded in [await memory.enrich(live), await memory.enrich(live, state: "S"),
                         await memory.enrich(live, sample: CaptureSampleKey(eventID: "e1", phase: .before))] {
            #expect(degraded.elements == live.elements && degraded.token == live.token)
            #expect(degraded.knowledge == SceneKnowledge(status: .unavailable))
        }
        // The engine's expectation reads no projection: it still answers from the relations.
        #expect(await memory.expectedEffect(of: .click, on: Self.export, in: Self.window(live)) == .menuOpened(labels: []))
        await store.fail([.relations])
        #expect(await memory.expectedEffect(of: .click, on: Self.export, in: Self.window(live)) == nil)
    }
}
