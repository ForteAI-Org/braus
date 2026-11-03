//
//  BrainMemoryTests.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// InMemoryBrainStore is a pure double of the stored brain for the seam's tests: one `UIBrain` per
/// application and each application applied once per key, by the rules the SQLite repositories
/// apply (`BrainUpdater` unchanged, a retry answers the stored outcome). Nothing here is the store.
actor InMemoryBrainStore: BrainReading, BrainApplicationStoring {

    private var brains: [String: UIBrain] = [:]
    private var applied: [BrainApplicationKey: BrainApplicationResult] = [:]
    private var nextID: Int64 = 1

    func brain(of bundleID: String) async throws -> UIBrain? { brains[bundleID] }

    func apply(_ command: BrainApplicationCommand) async throws -> BrainApplicationResult {
        if let stored = applied[command.key] {
            return BrainApplicationResult(receipt: .alreadyApplied, applicationID: stored.applicationID,
                                          outcome: stored.outcome, requestedAtMS: stored.requestedAtMS,
                                          effectiveAtMS: stored.effectiveAtMS)
        }
        var brain = brains[command.bundleID] ?? UIBrain()
        let now = Date(timeIntervalSince1970: Double(command.requestedAtMS) / 1000)
        let outcome: BrainApplicationOutcome
        switch command.input {
            case .observe(let window, let detections):
                let stats = BrainUpdater.ingest(detections, into: &brain, now: now, window: window)
                outcome = .observed(created: stats.created, updated: stats.updated, skippedAmbiguous: stats.skippedAmbiguous)
            case .record(let verb, let target, let effect):
                guard let effect else { outcome = .noEffect; break }
                var key: String?
                if case .found(let found) = BrainMatcher.match(target, in: brain) { key = found }
                if key == nil, effect.kind == "menuOpened" {
                    _ = BrainUpdater.ingest([target], into: &brain, now: now)
                    if case .found(let found) = BrainMatcher.match(target, in: brain) { key = found }
                }
                guard let key else { outcome = .noAnchor; break }
                let evidence = BrainUpdater.recordTransition(
                    anchorKey: key, trigger: TransitionTrigger(verb), effect: effect.effect, into: &brain, now: now
                )
                outcome = .recorded(anchorKey: key, transitionID: "\(key)/\(effect.effect)", evidence: evidence)
            case .setName(let anchorKey, let name):
                outcome = BrainUpdater.setName(name, anchorKey: anchorKey, into: &brain, now: now)
                    ? .named(anchorKey: anchorKey) : .notNamed
        }
        brains[command.bundleID] = brain
        let result = BrainApplicationResult(receipt: .committed, applicationID: nextID, outcome: outcome,
                                            requestedAtMS: command.requestedAtMS, effectiveAtMS: command.requestedAtMS)
        nextID += 1
        applied[command.key] = result
        return result
    }

    func application(_ key: BrainApplicationKey) async throws -> BrainApplication? { nil }
}

/// RelationsDouble answers a fixed state for any capture and the relations it was given, filtered as the
/// store filters them: by state and element key. Nothing here is the store.
actor RelationsDouble: BrainRelationReading {

    private let fixedState: String?
    private var stored: [BrainRelation] = []
    private let savedSkeleton: SceneSkeleton?

    init(state: String?, skeleton: SceneSkeleton? = nil) {
        fixedState = state
        savedSkeleton = skeleton
    }

    func set(_ relations: [BrainRelation]) { stored = relations }

    func state(of skeleton: SceneSkeleton, isComplete: Bool, in bundleID: String) async throws -> String? {
        guard savedSkeleton == nil || savedSkeleton == skeleton else { return nil }
        return fixedState
    }

    func state(of sample: CaptureSampleKey) async throws -> String? { fixedState }

    func relations(from sceneID: String, in bundleID: String, elementKeys: [String],
                   includingContext: Bool) async throws -> [BrainRelation] {
        stored.filter { relation in
            relation.key.fromSceneID == sceneID
                && (relation.key.elementKey.map(elementKeys.contains) ?? includingContext)
        }
    }
}

@Suite("The brain seam: expectations in, records out")
struct BrainMemoryTests {

    private let bundle = "com.adobe.PremierePro"
    private let export = SceneElement(id: "control|export", kind: .control, label: "Export", bounds: Fixtures.rect(0.1, 0.1, 0.05, 0.02),
                                      role: "AXButton", labelOrigin: .title)
    private let platform = SceneElement(id: "control|platform", kind: .control, label: "Platform", bounds: Fixtures.rect(0.5, 0.1, 0.05, 0.02))

    private func scene(_ elements: [SceneElement], title: String = "Export Settings") -> SceneSnapshot {
        SceneSnapshot(bundleID: bundle, appName: "Premiere", windowTitle: title,
                      viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements)
    }

    private func memory(_ store: InMemoryBrainStore) -> BrainMemory {
        BrainMemory(brains: store, applications: store, clock: { Fixtures.t0 })
    }

    private func sample(_ event: String) -> CaptureSampleKey { CaptureSampleKey(eventID: event, phase: .current) }

    private func record(_ element: SceneElement, _ effect: SceneEffect?) -> ActionRecord {
        ActionRecord(bundleID: bundle, element: element, verb: .click, effect: effect, windowTitleAfter: nil)
    }

    private func contentWindow(_ bundleID: String) -> PerceivedWindow {
        let caption = SceneElement(
            id         : "control|content",
            kind       : .control,
            label      : "Personal entry",
            bounds     : Fixtures.rect(0.2, 0.2, 0.1, 0.1),
            role       : "AXLink",
            labelOrigin: .title
        )
        let item = SceneElement(
            id            : "control|item",
            kind          : .control,
            label         : "Personal item",
            bounds        : Fixtures.rect(0.3, 0.3, 0.1, 0.1),
            role          : "AXButton",
            labelOrigin   : .title,
            collectionPath: "Personal entries"
        )
        var shown = scene([export, caption, item])
        shown.bundleID = bundleID
        return PerceivedWindow(scene: shown, frame: .zero, capture: .unknown, surface: .window)
    }

    @Test
    func callSecretsReachBothComparisons() async throws {
        let capture = secretCapture()
        let saved = SceneSkeleton(sample: ValueMinimization(secrets: ["731"]).minimize(sample: capture, confidential: nil).0)
        let relations = RelationsDouble(state: "S", skeleton: saved)
        let store = InMemoryBrainStore()
        let memory = BrainMemory(brains: store, applications: store, relations: relations, clock: { Fixtures.t0 })
        let shown = window([exportWithSecret()])
        let capturedTarget = try #require(CaptureElement(shown.scene.elements[0]))
        let key = try #require(SceneElementKey.key(of: capturedTarget))
        await relations.set([relation(key, .click, supports: 2, effect: "elementsAppeared")])
        #expect(await memory.enrich(shown.scene, window: shown).knowledge?.status == .unrecognized)
        #expect(await memory.expectedEffect(of: .click, on: shown.scene.elements[0], in: shown) == nil)
        await CallMinimization.$current.withValue(ValueMinimization(secrets: ["731"])) {
            #expect(await memory.enrich(shown.scene, window: shown).knowledge?.status == .applied)
            #expect(await memory.expectedEffect(of: .click, on: shown.scene.elements[0], in: shown) == .elementsAppeared(labels: []))
        }
        #expect(CallMinimization.current == nil)
    }

    private func exportWithSecret() -> SceneElement {
        var target = export
        target.label = "731"
        target.container = "Panel 731"
        return target
    }

    @Test
    func callMinimizationIsolated() async {
        await withTaskGroup(of: Void.self) { group in
            for secret in ["731", "942"] {
                group.addTask {
                    var admitted = ValueMinimization(secrets: [secret])
                    await CallMinimization.$current.withValue(admitted) {
                        admitted = admitted.adding(secrets: ["later"])
                        await Task.yield()
                        #expect(CallMinimization.current?.secrets == [secret])
                        #expect(admitted.secrets == [secret, "later"])
                        #expect(CallMinimization.current?.minimize(text: secret).0 == ValueMinimization.marker)
                    }
                }
            }
        }
        #expect(CallMinimization.current == nil)
    }

    @Test(arguments: ["com.apple.Notes", "com.apple.iCal"])
    func liveSkeletonMatchesSavedOne(bundleID: String) {
        let capture = CaptureSample(key: sample("live"), of: contentWindow(bundleID))
        let minimization = ValueMinimization()
        let surface = ConfidentialSurfaces.surface(of: bundleID)
        let saved = SceneSkeleton(sample: minimization.minimize(sample: capture, confidential: surface).0)
        let live = SceneSkeleton.comparable(capture, minimization: minimization, surface: surface)
        #expect(SceneSkeleton(sample: capture) != saved)
        #expect(saved.collections == [ValueMinimization.marker])
        #expect(saved.captions.contains(SceneSkeleton.Caption(role: "AXLink", label: ValueMinimization.marker)))
        #expect(live == saved)
        #expect(live.canonical == saved.canonical)
    }

    @Test(arguments: ["com.apple.Notes", "com.apple.iCal"], [false, true])
    func stateFoundForMinimizedCapture(bundleID: String, hasSecret: Bool) async throws {
        var liveScene = contentWindow(bundleID).scene
        if hasSecret {
            liveScene.elements[0].label = "731"
            liveScene.elements[0].container = "Panel 731"
        }
        let shown = PerceivedWindow(scene: liveScene, frame: .zero, capture: .unknown, surface: .window)
        let minimization = ValueMinimization(secrets: hasSecret ? ["731"] : [])
        let capture = CaptureSample(key: sample("saved"), of: shown)
        let saved = SceneSkeleton(sample: minimization.minimize(
            sample      : capture,
            confidential: ConfidentialSurfaces.surface(of: bundleID)
        ).0)
        let relations = RelationsDouble(state: "S", skeleton: saved)
        let store = InMemoryBrainStore()
        let memory: BrainMemory
        if hasSecret {
            memory = BrainMemory(
                brains      : store,
                applications: store,
                relations   : relations,
                minimization: minimization,
                clock       : { Fixtures.t0 }
            )
        } else {
            memory = BrainMemory(brains: store, applications: store, relations: relations, clock: { Fixtures.t0 })
        }
        let target = shown.scene.elements[0]
        let capturedTarget = try #require(CaptureElement(target))
        let key = try #require(SceneElementKey.key(of: capturedTarget))
        let relationKey = BrainRelationKey(
            bundleID    : bundleID,
            contextID   : nil,
            fromSceneID : "S",
            elementKey  : key,
            verb        : .click,
            argumentsKey: "",
            toSceneID   : nil,
            outcome     : .effect,
            effectKind  : "elementsAppeared"
        )
        await relations.set([BrainRelation(
            relationID    : relationKey.relationID,
            key           : relationKey,
            firstSeenMS   : 0,
            lastSeenMS    : 0,
            supports      : 2,
            contradictions: 0
        )])
        let enriched = await memory.enrich(shown.scene, window: shown)
        #expect(enriched.knowledge?.status == .applied)
        #expect(enriched.elements[0].does != nil)
        #expect(await memory.expectedEffect(of: .click, on: target, in: shown) == .elementsAppeared(labels: []))
    }

    @Test
    func comparableIsIdentityWithoutContent() {
        let capture = CaptureSample(key: sample("plain"), of: window([export]))
        let original = SceneSkeleton(sample: capture)
        let comparable = SceneSkeleton.comparable(capture, minimization: ValueMinimization(), surface: nil)
        #expect(comparable == original)
        #expect(comparable.canonical == original.canonical)
    }

    private func secretCapture() -> CaptureSample {
        var target = export
        target.label = "731"
        target.container = "Panel 731"
        return CaptureSample(key: sample("secret"), of: window([target]))
    }

    @Test
    func comparableUsesExplicitSecrets() {
        let capture = secretCapture()
        let minimization = ValueMinimization(secrets: ["731"])
        let saved = SceneSkeleton(sample: minimization.minimize(sample: capture, confidential: nil).0)
        let comparable = SceneSkeleton.comparable(capture, minimization: minimization, surface: nil)
        #expect(saved.captions == [SceneSkeleton.Caption(role: "AXButton", label: ValueMinimization.marker)])
        #expect(saved.paths == ["Panel " + ValueMinimization.marker])
        #expect(comparable == saved)
        #expect(comparable.canonical == saved.canonical)
    }

    @Test
    func defaultDoesNotRepresentCallSecrets() {
        let capture = secretCapture()
        let saved = SceneSkeleton(sample: ValueMinimization(secrets: ["731"]).minimize(
            sample: capture, confidential: nil
        ).0)
        let comparable = SceneSkeleton.comparable(capture, minimization: ValueMinimization(), surface: nil)
        #expect(comparable != saved)
        #expect(comparable == SceneSkeleton(sample: capture))
    }

    @Test("observing a scene anchors its elements, scoped to the window's title family, once per sample")
    func observe() async throws {
        let store = InMemoryBrainStore()
        let memory = memory(store)
        let result = try await memory.observe(scene([export, platform,
            SceneElement(id: "control|cancel", kind: .control, label: "Cancel", bounds: Fixtures.rect(0.3, 0.1, 0.05, 0.02))]),
            sample: sample("e1"))
        #expect(result.outcome == .observed(created: 3, updated: 0, skippedAmbiguous: 0))
        #expect(result.receipt == .committed)
        let brain = try #require(await store.brain(of: bundle))
        #expect(brain.objects.count == 3)
        #expect(brain.objects.allSatisfy { $0.window == "exportsettings" })
        #expect(brain.ingestEpoch == 1)
        // The same sample offered again is the same observation: the brain's clock does not move.
        let again = try await memory.observe(scene([export, platform]), sample: sample("e1"))
        #expect(again.receipt == .alreadyApplied)
        #expect(try #require(await store.brain(of: bundle)).ingestEpoch == 1)
    }

    @Test("a transition the projection learned is no expectation and no affordance: those come from qualified relations")
    func projectionIsNoExpectation() async throws {
        let store = InMemoryBrainStore()
        let memory = memory(store)
        _ = try await memory.observe(scene([export, platform]), sample: sample("e1"))
        let taught = record(export, .elementsAppeared(labels: ["Queue", "Export"]))
        let first = try #require(try await memory.record(taught, eventID: "r1"))
        #expect(first.outcome == .recorded(anchorKey: try #require(await store.brain(of: bundle)).objects[0].anchorKey,
                                           transitionID: first.outcome.transitionID ?? "", evidence: 1))
        // The same call offered again is a retry of one fact, not a second observation.
        #expect(try #require(try await memory.record(taught, eventID: "r1")).receipt == .alreadyApplied)
        _ = try await memory.record(taught, eventID: "r2")
        #expect(try #require(await store.brain(of: bundle)).transitions.first?.evidence == 2)
        #expect(await memory.expectedEffect(of: .click, on: export, in: window([export, platform])) == nil,
                "a trusted projection transition no longer sets the engine's expectation")
        #expect(await memory.enrich(scene([export])).elements[0].does == nil)
    }

    @Test("the expectation is the one exposed, never contradicted relation of the element and verb in the window's state")
    func expectation() async throws {
        let relations = RelationsDouble(state: "S")
        let memory = BrainMemory(brains: InMemoryBrainStore(), applications: InMemoryBrainStore(), relations: relations,
                                 clock: { Fixtures.t0 })
        let shown = window([export, platform])
        let capture = try #require(CaptureElement(export))
        let key = try #require(SceneElementKey.key(of: capture))
        await relations.set([relation(key, .click, supports: 1, effect: "elementsAppeared")])
        #expect(await memory.expectedEffect(of: .click, on: export, in: shown) == nil, "one proof is below the threshold")
        await relations.set([relation(key, .click, supports: 2, effect: "elementsAppeared")])
        #expect(await memory.expectedEffect(of: .click, on: export, in: shown) == .elementsAppeared(labels: []),
                "the family only: the engine compares families")
        #expect(await memory.expectedEffect(of: .doubleClick, on: export, in: shown) == nil, "another verb, no opinion")
        #expect(await memory.expectedEffect(of: .setToggle, on: export, in: shown) == nil, "a toggle's state is read back")
        await relations.set([relation(key, .click, supports: 3, contradictions: 1, effect: "elementsAppeared")])
        #expect(await memory.expectedEffect(of: .click, on: export, in: shown) == nil, "a contradiction limits the prediction")
        await relations.set([relation(key, .click, supports: 2, effect: "elementsAppeared"),
                             relation(key, .click, supports: 2, effect: "windowTitleChanged", to: "T")])
        #expect(await memory.expectedEffect(of: .click, on: export, in: shown) == nil, "two possible outcomes, none is certain")
        await relations.set([relation(key, .click, supports: 1, effect: "menuOpened")])
        #expect(await memory.expectedEffect(of: .click, on: export, in: shown) == .menuOpened(labels: []),
                "a menu that opened is exposed at its first proof")
        let unknownState = BrainMemory(brains: InMemoryBrainStore(), applications: InMemoryBrainStore(),
                                       relations: RelationsDouble(state: nil), clock: { Fixtures.t0 })
        #expect(await unknownState.expectedEffect(of: .click, on: export, in: shown) == nil, "no state recognized, no opinion")
    }

    @Test("a menu reveal still anchors an element the projection had never seen, and its revealer is found")
    func menuReveal() async throws {
        let store = InMemoryBrainStore()
        let memory = memory(store)
        _ = try await memory.record(record(platform, .menuOpened(labels: ["Desktop", "Mobile", "Web"])), eventID: "r1")
        let brain = try #require(await store.brain(of: bundle))
        #expect(brain.objects.count == 1)
        #expect(brain.transitions.count == 1)
        #expect(brain.revealers(of: "Mobile").first?.label == "Platform")
    }

    @Test("enrich shows each element's offered relations in the state the scene is in, alternatives side by side")
    func enrich() async throws {
        let relations = RelationsDouble(state: "S")
        let store = InMemoryBrainStore()
        let memory = BrainMemory(brains: store, applications: store, relations: relations, clock: { Fixtures.t0 })
        var untouched = scene([export])
        untouched.outOfViewFields = [OutOfViewField(label: "Tempo", value: "97", role: "AXTextField")]
        #expect(await memory.enrich(untouched) == untouched)
        let capture = try #require(CaptureElement(export))
        let key = try #require(SceneElementKey.key(of: capture))
        await relations.set([relation(key, .click, supports: 2, effect: "elementsAppeared", to: "X"),
                             relation(key, .click, supports: 2, contradictions: 1, effect: "windowTitleChanged"),
                             relation(key, .rightClick, supports: 1, effect: "elementsAppeared")])
        #expect(await memory.enrich(untouched).elements[0].does == nil, "no state given, no relation read")
        let enriched = await memory.enrich(untouched, state: "S")
        let does = try #require(enriched.elements[0].does)
        #expect(does.contains("click: elementsAppeared → another state"))
        #expect(does.contains("click: windowTitleChanged → unknown state (contradicted ×1)"))
        #expect(!does.contains("right_click"), "a relation below its threshold is kept and not offered")
        #expect(enriched.elements[0].bounds == export.bounds)
        #expect(enriched.outOfViewFields == untouched.outOfViewFields)
        #expect(enriched.token == untouched.token, "an annotation never moves the token an action must echo")
        #expect(await memory.enrich(untouched, state: "elsewhere").elements[0].does == nil,
                "nothing is carried over from another state")
    }

    private func window(_ elements: [SceneElement]) -> PerceivedWindow {
        PerceivedWindow(scene: scene(elements), frame: .zero, capture: .unknown, surface: .window)
    }

    private func relation(_ element: String?, _ verb: BrainVerb, supports: Int, contradictions: Int = 0, effect: String,
                          to: String? = nil) -> BrainRelation {
        let key = BrainRelationKey(bundleID: bundle, contextID: nil, fromSceneID: "S", elementKey: element, verb: verb,
                                   argumentsKey: "", toSceneID: to, outcome: .effect, effectKind: effect)
        return BrainRelation(relationID: key.relationID, key: key, firstSeenMS: 0, lastSeenMS: 0, supports: supports,
                             contradictions: contradictions)
    }

    @Test("a record without an effect is no application; an unknown element with a non-menu effect teaches nothing")
    func nothingLearned() async throws {
        let store = InMemoryBrainStore()
        let memory = memory(store)
        #expect(try await memory.record(record(export, nil), eventID: "r1") == nil)
        let unknown = try #require(try await memory.record(record(export, .stateFlip(from: .off, to: .on)), eventID: "r3"))
        #expect(unknown.outcome == .noAnchor)
        #expect(try await store.brain(of: bundle)?.transitions.isEmpty ?? true)
    }
}

private extension BrainApplicationOutcome {
    var transitionID: String? {
        if case .recorded(_, let id, _) = self { id } else { nil }
    }
}
