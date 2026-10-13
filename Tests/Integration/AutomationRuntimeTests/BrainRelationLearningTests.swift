//
//  BrainRelationLearningTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// BrainRelationLearningTests prove the functional Brain through the recorder a producer uses, on a real
/// archive: a call's samples are placed in structural states, its verification teaches the relation of
/// its precise verb once, and the states, the relations and the expectations read back by targeted
/// queries. Documents, values and positions are no state; a dialog is one; an incomplete capture places
/// nothing; alternatives stay side by side; a contradiction limits a prediction.
@Suite("Functional states and relations learned through the recorder")
struct BrainRelationLearningTests {

    static let bundle = W.bundle

    static func window(_ elements: [SceneElement], title: String = "Document", surface: CaptureSurface = .window,
                       complete: Bool = true) -> PerceivedWindow {
        PerceivedWindow(
            scene  : SceneSnapshot(bundleID: bundle, appName: "Editor", windowTitle: title,
                                   viewportPixelSize: ViewportPixelSize(width: 1600, height: 1200), elements: elements),
            frame  : CGRect(x: 0, y: 0, width: 800, height: 600),
            capture: CaptureQuality(walkCompleted: complete, windowFound: true, isGrantAvailable: true, windowRole: "AXWindow",
                                    nodesVisited: elements.count + 1, elementsEmitted: elements.count),
            surface: surface
        )
    }

    static func field(_ value: String) -> SceneElement {
        SceneElement(id: "field|name", kind: .control, label: value, bounds: NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.04),
                     role: "AXTextField", labelOrigin: .value)
    }

    static let export = W.button("Export", x: 0.2), cancel = W.button("Cancel", x: 0.6), save = W.button("Save", x: 0.8)
    static let checkbox = SceneElement(id: "check|wrap", kind: .control, label: "Wrap", bounds: NormalizedRect(x: 0.1, y: 0.6, width: 0.05, height: 0.04),
                                       role: "AXCheckBox", state: .off, labelOrigin: .title)

    /// One act through its own recorder: begun, its perceptions recorded, ended with its check.
    @discardableResult
    static func act(_ service: MemoryService, _ element: SceneElement, verb: ActionVerb = .click, before: PerceivedWindow,
                    after: PerceivedWindow, check: OperationCheck, effect: SceneEffect? = .elementsAppeared(labels: ["x"])) async throws -> String {
        let recorder = W.recorder(service)
        try await recorder.begin(.act(target: element.label, verb: verb, value: verb == .setToggle ? .on : nil, section: nil),
                                 app: AppContextIdentity(bundleID: bundle))
        await recorder.record(ActionRecord(bundleID: bundle, element: element, verb: verb, effect: effect,
                                           windowTitleAfter: after.scene.windowTitle, before: before, after: after))
        try await recorder.end(.completed, result: .outcome(.foundActed, message: "done"), tool: .act, check: check)
        return recorder.eventID
    }

    static func passed(_ element: SceneElement, observed: String = "elementsAppeared") -> OperationCheck {
        OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: .passed, observed: observed,
                       limits: [.windowWide, .noExpectation], performed: .requested, target: OperationCheck.Target(element))
    }

    @Test("two documents and two values of one structure are one state; a dialog is another; an incomplete capture places nothing")
    func functionalStates() async throws {
        let service = try W.service()
        let first = Self.window([Self.export, Self.cancel, Self.field("a.png")], title: "a.png")
        let second = Self.window([Self.export, Self.cancel, Self.field("ritratto finale.png")], title: "ritratto finale.png")
        let dialog = Self.window([Self.save, Self.cancel, Self.field("untitled.png")], title: "Export", surface: .dialog)
        try await Self.act(service, Self.export, before: first, after: dialog, check: Self.passed(Self.export))
        try await Self.act(service, Self.export, before: second, after: dialog, check: Self.passed(Self.export))
        let unfinished = try await Self.act(service, Self.export, before: Self.window([Self.export, Self.cancel], complete: false),
                                            after: dialog, check: Self.passed(Self.export))
        #expect(await service.flush(within: .seconds(10)))
        let relations = try await service.perform { try await $0.relations.relations(of: Self.bundle) }
        #expect(relations.count == 1, "the two documents' clicks are one relation: \(relations.map(\.summary))")
        let relation = try #require(relations.first)
        #expect(relation.supports == 2 && relation.standing == .exposed)
        #expect(relation.key.toSceneID != nil && relation.key.toSceneID != relation.key.fromSceneID,
                "the dialog is a state of its own: \(relation.summary)")
        #expect(try await service.perform { try await $0.relations.application(of: unfinished) }?.exclusion == .noBeforeState,
                "an incomplete capture proves no state")
        // The state is recognized from a new capture by a targeted read: the scenes of its roles only.
        let state = try await service.state(of: SceneSkeleton(sample: CaptureSample(
            key: CaptureSampleKey(eventID: "probe", phase: .current), of: Self.window([Self.export, Self.cancel, Self.field("z.tif")]),
            sessionRevision: nil)), isComplete: true, in: Self.bundle)
        #expect(state == relation.key.fromSceneID)
        let captionChanged = try await service.state(of: SceneSkeleton(sample: CaptureSample(
            key: CaptureSampleKey(eventID: "probe", phase: .current), of: Self.window([W.button("Esporta", x: 0.2), Self.cancel,
                                                                                       Self.field("z")]),
            sessionRevision: nil)), isComplete: true, in: Self.bundle)
        #expect(captionChanged == nil, "another caption is uncertain: no equivalence is forced")
        await service.close()
    }

    @Test("the same command with two verified outcomes keeps both relations side by side; the engine expects neither; a failure contradicts the predicted one")
    func alternativesAndContradictions() async throws {
        let service = try W.service()
        let editing = Self.window([Self.export, Self.cancel, Self.field("a.png")])
        let dialog = Self.window([Self.save, Self.cancel, Self.field("untitled.png")], title: "Export", surface: .dialog)
        let collision = Self.window([W.button("Replace", x: 0.5), Self.cancel], title: "Replace?", surface: .sheet)
        for _ in 0..<2 { try await Self.act(service, Self.export, before: editing, after: dialog, check: Self.passed(Self.export)) }
        #expect(await service.flush(within: .seconds(10)))
        let brain = W.brain(service)
        #expect(await brain.expectedEffect(of: .click, on: Self.export, in: editing) == .elementsAppeared(labels: []))
        for _ in 0..<2 {
            try await Self.act(service, Self.export, before: editing, after: collision,
                               check: Self.passed(Self.export, observed: "windowTitleChanged"), effect: .windowTitleChanged(title: "Replace?"))
        }
        #expect(await service.flush(within: .seconds(10)))
        let relations = try await service.perform { try await $0.relations.relations(of: Self.bundle) }
        #expect(relations.count == 2 && relations.allSatisfy { $0.standing == .exposed })
        #expect(Set(relations.compactMap(\.key.toSceneID)).count == 2, "two destinations, each with its own proofs")
        #expect(await brain.expectedEffect(of: .click, on: Self.export, in: editing) == nil, "two possible outcomes: no certain one")
        let enriched = await brain.enrich(editing.scene, state: relations[0].key.fromSceneID)
        let does = try #require(enriched.elements.first { $0.label == "Export" }?.does)
        #expect(does.contains("elementsAppeared") && does.contains("windowTitleChanged"), "\(does)")
        // A click that changed nothing contradicts the effect relations of its group.
        try await Self.act(service, Self.export, before: editing, after: editing, check: OperationCheck(
            condition: .structuralEffect, method: .sceneDifference, verdict: .failed, observed: "unchanged",
            limits: [.noExpectation], performed: .requested, target: OperationCheck.Target(Self.export)), effect: nil)
        #expect(await service.flush(within: .seconds(10)))
        let after = try await service.perform { try await $0.relations.relations(of: Self.bundle) }
        #expect(after.allSatisfy { $0.standing == .limited && $0.contradictions == 1 }, "\(after.map { ($0.summary, $0.contradictions) })")
        await service.close()
    }

    @Test("a double click, a triple click and a toggle are relations of their own; a no-op stays in its state; a retry or a rebuild adds no proof")
    func preciseVerbsAndOneProof() async throws {
        let service = try W.service()
        let editing = Self.window([Self.export, Self.cancel, Self.checkbox])
        let call = try await Self.act(service, Self.export, before: editing, after: editing, check: Self.passed(Self.export))
        try await Self.act(service, Self.export, verb: .doubleClick, before: editing, after: editing, check: Self.passed(Self.export))
        try await Self.act(service, Self.export, verb: .tripleClick, before: editing, after: editing, check: Self.passed(Self.export))
        try await Self.act(service, Self.checkbox, verb: .setToggle, before: editing, after: editing, check: OperationCheck(
            condition: .requestedStateAlreadyPresent, method: .controlState, verdict: .passed, expected: "on", observed: "on",
            performed: .none, target: OperationCheck.Target(Self.checkbox)), effect: nil)
        #expect(await service.flush(within: .seconds(10)))
        let relations = try await service.perform { try await $0.relations.relations(of: Self.bundle) }
        #expect(relations.map { "\($0.key.verb.rawValue):\($0.key.outcome.rawValue)" }.sorted()
                == ["click:effect", "double_click:effect", "set_toggle:already_satisfied", "triple_click:effect"])
        #expect(relations.allSatisfy { $0.key.toSceneID == $0.key.fromSceneID }, "a self-loop is a lawful relation")
        // The same call applied again, as a retried write or a rebuild would, teaches nothing twice.
        _ = try await service.perform { try await $0.relations.apply(callEventID: call, at: 9_999) }
        #expect(try await service.perform { try await $0.relations.applyPending(at: 9_999) } == 0)
        let click = try #require(try await service.perform { try await $0.relations.relations(of: Self.bundle) }
            .first { $0.key.verb == .click })
        #expect(click.supports == 1)
        await service.close()
    }

    @Test("a recovery gesture and an unattributed change teach nothing, and say why")
    func nothingFromRecoveryOrExtraneousChange() async throws {
        let service = try W.service()
        let editing = Self.window([Self.export, Self.cancel])
        let recovered = try await Self.act(service, Self.export, before: editing, after: editing, check: OperationCheck(
            condition: .recoveryInsteadOfRequest, method: .windowCensus, verdict: .passed, expected: "pop-up closed",
            observed: "pop-up closed", performed: .substitute, substitute: "escape", target: OperationCheck.Target(Self.export)))
        let extraneous = try await Self.act(service, Self.export, before: editing, after: editing, check: OperationCheck(
            condition: .structuralEffect, method: .sceneDifference, verdict: .unknown, limits: [.unattributed, .noExpectation],
            performed: .requested, target: OperationCheck.Target(Self.export)))
        #expect(await service.flush(within: .seconds(10)))
        #expect(try await service.perform { try await $0.relations.application(of: recovered) }?.exclusion == .substituteGesture)
        #expect(try await service.perform { try await $0.relations.application(of: extraneous) }?.exclusion == .verdictUnknown)
        #expect(try await service.perform { try await $0.relations.relations(of: Self.bundle) }.isEmpty)
        #expect(try await service.brain(of: Self.bundle)?.transitions.isEmpty ?? true,
                "the projection learns no transition from a gesture its check did not verify")
        await service.close()
    }
}
