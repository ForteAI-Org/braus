//
//  BrainMemory.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// BrainMemory fills the engine's expectation seam and the scene's enrichment from the stored Brain, and
/// carries what a producer teaches it to the brain's applications.
///
/// What an operation does comes from the relations of the functional state the window is in
/// (`BrainRelationReading`): the engine expects an effect only from the one relation of an identified
/// element and verb that is exposed and never contradicted, and the scene shows, on each identified
/// element of the current state, the relations offered for it (exposed, or limited as a possibility),
/// alternatives side by side, and, apart, the operations learned on the window itself, with what they
/// need that was not recorded. An element whose structural key another element of the window shares is
/// identified by neither, so nothing learned on one reaches the other. Every read is targeted: the
/// state of the capture, the relations of that state and those elements, and the part of the
/// projection (sibling groups, recalled labels) the scene's labels, kinds and groups can match; never an
/// application's whole Brain.
///
/// A read never fails an action or a scene: the scene keeps its live elements and token, and says what
/// the memory could say (`SceneKnowledge`): what was learned applies, nothing is learned yet, the state
/// is not recognized, or the memory could not be read. When any read a scene's enrichment needs fails
/// (the part of the projection, the state, the relations), the scene is the live one with nothing of the
/// memory on it, no recalled label, group, relation or window line, and says the memory is unavailable:
/// what it shows and what it says agree. The error of a failed read is kept here, for a local diagnosis
/// (`diagnostics`), and never put in a scene. A write that fails is thrown to the
/// producer, which reports the memory as degraded and goes on. The clock arrives at construction;
/// nothing here reads the wall.
public actor BrainMemory: EffectExpecting {

    private let brains: any BrainReading
    private let applications: any BrainApplicationStoring
    private let relations: (any BrainRelationReading)?
    private let clock: @Sendable () -> Date

    public init(
        brains      : any BrainReading,
        applications: any BrainApplicationStoring,
        relations   : (any BrainRelationReading)? = nil,
        clock       : @escaping @Sendable () -> Date
    ) {
        self.brains       = brains
        self.applications = applications
        self.relations    = relations
        self.clock        = clock
    }

    // MARK: EffectExpecting

    /// The effect family the one exposed, never contradicted relation of the element and verb in the
    /// window's functional state predicts, or nil: no state recognized, an element the structure does
    /// not tell from another, no relation, several possible outcomes, a contradiction, a toggle (whose
    /// state is read back, not diffed) or a store that cannot be read (counted in `diagnostics`). The
    /// effect carries its family only; the engine compares families.
    public func expectedEffect(
        of verb    : ActionVerb,
        on element : SceneElement,
        in window  : PerceivedWindow
    ) async -> SceneEffect? {
        guard verb != .setToggle, let relations else { return nil }
        let bundleID = window.scene.bundleID
        let sample   = CaptureSample(key: CaptureSampleKey(eventID: "expectation", phase: .current), of: window, sessionRevision: nil)
        // The element is identified among the window's own elements, the capture it was resolved in.
        guard let target = CaptureElement(element),
              let index = sample.elements.firstIndex(where: { $0 == target }),
              let key = SceneElementKey.identities(in: sample.elements)[index]?.key else { return nil }
        let found: [BrainRelation]
        do {
            guard let state = try await relations.state(of: SceneSkeleton(sample: sample), isComplete: sample.quality.isComplete,
                                                        in: bundleID) else { return nil }
            found = try await relations.relations(from: state, in: bundleID, elementKeys: [key], includingContext: false)
        } catch {
            failed(error)
            return nil
        }
        let wanted  = BrainVerb(verb)
        let offered = found.filter { $0.key.verb == wanted && $0.key.argumentsKey.isEmpty && $0.standing != .candidate }
        guard offered.count == 1, let only = offered.first, only.standing == .exposed, only.key.outcome == .effect,
              let family = only.key.effectKind else { return nil }
        return Self.effect(ofFamily: family)
    }

    /// An effect of a family with no payload, for a comparison by family.
    static func effect(ofFamily family: String) -> SceneEffect? {
        switch family {
            case "windowTitleChanged"  : .windowTitleChanged(title: "")
            case "stateFlip"           : .stateFlip(from: .unknown, to: .unknown)
            case "menuOpened"          : .menuOpened(labels: [])
            case "elementsAppeared"    : .elementsAppeared(labels: [])
            case "elementsDisappeared" : .elementsDisappeared(labels: [])
            case "textSelectionChanged": .textSelectionChanged
            case "valueChanged"        : .valueChanged(label: "", value: "")
            default                    : nil
        }
    }

    // MARK: What a producer teaches

    /// Records what an action taught the projection, keyed by the event of the call that performed it:
    /// the record's effect against its element's anchor, with the rules the brain always had (no effect
    /// teaches nothing; an element with no anchor teaches nothing unless it revealed a menu). Nil when the
    /// record carries no effect or no element, which is no application at all. A producer offers it only
    /// for an effect its check verified. `requestedAt` is the instant the application is asked for, part
    /// of what the store compares a retry against: a producer passes the call's own instant, so the same
    /// call is the same command; nil reads the clock.
    public func record(_ record: ActionRecord, eventID: String, requestedAt: Date? = nil) async throws -> BrainApplicationResult? {
        guard record.effect != nil else { return nil }
        let command = try BrainApplicationCommand.record(record, eventID: eventID, requestedAt: requestedAt ?? clock())
        return try await applications.apply(command)
    }

    /// Ingests a scene's elements into its application's brain, scoped to the window's title
    /// family, keyed by the real sample the scene was captured as. `requestedAt` as in `record`.
    @discardableResult
    public func observe(_ scene: SceneSnapshot, sample: CaptureSampleKey, requestedAt: Date? = nil) async throws -> BrainApplicationResult {
        let command = try BrainApplicationCommand.observe(scene, sample: sample, requestedAt: requestedAt ?? clock())
        return try await applications.apply(command)
    }

    // MARK: Scenes

    /// Diagnostics is what failed in this process's reads, for a local diagnosis: never in a scene.
    public struct Diagnostics: Sendable, Equatable {
        public let failedReads: Int
        public let lastFailure: String?
    }

    private var failedReads = 0
    private var lastFailure: String?

    /// The reads that failed since this memory was made, and the last one's error, for a diagnosis.
    public func diagnostics() -> Diagnostics {
        Diagnostics(failedReads: failedReads, lastFailure: lastFailure)
    }

    private func failed(_ error: any Error) {
        failedReads += 1
        lastFailure = "\(error)"
    }

    /// The scene with its elements named from the projection (sibling groups, recalled labels), and
    /// nothing said about the state: for a scene whose capture is not at hand, so its state cannot be
    /// placed. The live scene, said unavailable, when the projection cannot be read.
    public func enrich(_ scene: SceneSnapshot) async -> SceneSnapshot {
        guard let elements = await named(scene) else { return Self.unavailable(scene) }
        return Self.rebuilt(scene, elements: elements, knowledge: nil)
    }

    /// The scene of a live window, annotated with what was learned in the functional state its capture
    /// is placed in: its elements named, each identified element with the relations offered for it, the
    /// operations learned on the window itself, and what the memory could say (`SceneKnowledge`).
    public func enrich(_ scene: SceneSnapshot, window: PerceivedWindow) async -> SceneSnapshot {
        let sample = CaptureSample(key: CaptureSampleKey(eventID: "enrichment", phase: .current), of: window, sessionRevision: nil)
        return await enrich(scene) { relations in
            try await relations.state(of: SceneSkeleton(sample: sample), isComplete: sample.quality.isComplete,
                                      in: window.scene.bundleID)
        }
    }

    /// The scene of a sample the archive confirmed in a state, annotated with that state's relations.
    public func enrich(_ scene: SceneSnapshot, sample: CaptureSampleKey) async -> SceneSnapshot {
        await enrich(scene) { relations in try await relations.state(of: sample) }
    }

    /// The scene annotated with the relations of a state the caller placed it in, or as not recognized
    /// when it gives none.
    public func enrich(_ scene: SceneSnapshot, state sceneID: String?) async -> SceneSnapshot {
        await enrich(scene) { _ in sceneID }
    }

    /// The scene named, placed in its state and annotated, every read it needs done first: the part of
    /// the projection, the state, the relations of that state. A read that fails leaves the live scene,
    /// said unavailable, with nothing any read gave.
    private func enrich(_ scene: SceneSnapshot,
                        state: (any BrainRelationReading) async throws -> String?) async -> SceneSnapshot {
        guard let elements = await named(scene) else { return Self.unavailable(scene) }
        guard let relations else { return Self.rebuilt(scene, elements: elements, knowledge: nil) }
        do {
            guard let sceneID = try await state(relations) else {
                return Self.rebuilt(scene, elements: elements, knowledge: SceneKnowledge(status: .unrecognized))
            }
            let read = try await Self.annotate(elements, from: sceneID, in: scene.bundleID, relations: relations)
            return Self.rebuilt(scene, elements: read.elements,
                                knowledge: SceneKnowledge(status: read.applied ? .applied : .nothing, window: read.window))
        } catch {
            failed(error)
            return Self.unavailable(scene)
        }
    }

    /// The elements named from the part of the projection they can match, or nil when it could not be
    /// read. What an earlier enrichment said of them is dropped first: every read says only what it found.
    private func named(_ scene: SceneSnapshot) async -> [SceneElement]? {
        let elements = Self.live(scene)
        let detections = elements.filter { $0.kind == .control || $0.kind == .icon }.map(BrainDetection.init)
        guard !detections.isEmpty else { return elements }
        do {
            guard let brain = try await brains.projection(of: scene.bundleID, for: detections) else { return elements }
            return brain.enrich(elements, affordances: false)
        } catch {
            failed(error)
            return nil
        }
    }

    /// The scene's elements as perceived, without what an earlier enrichment said they do.
    static func live(_ scene: SceneSnapshot) -> [SceneElement] {
        scene.elements.map { element -> SceneElement in
            var fresh = element
            fresh.does = nil
            return fresh
        }
    }

    /// The live scene, said unavailable: its elements as perceived and its token, nothing of the memory.
    static func unavailable(_ scene: SceneSnapshot) -> SceneSnapshot {
        rebuilt(scene, elements: live(scene), knowledge: SceneKnowledge(status: .unavailable))
    }

    /// The scene with other elements and what the memory said, its token the live one.
    static func rebuilt(_ scene: SceneSnapshot, elements: [SceneElement], knowledge: SceneKnowledge?) -> SceneSnapshot {
        guard elements != scene.elements || knowledge != scene.knowledge else { return scene }
        return SceneSnapshot(
            bundleID         : scene.bundleID,
            appName          : scene.appName,
            windowTitle      : scene.windowTitle,
            viewportPixelSize: scene.viewportPixelSize,
            elements         : elements,
            outOfViewFields  : scene.outOfViewFields,
            sections         : scene.sections,
            commands         : scene.commands,
            token            : scene.token,
            knowledge        : knowledge
        )
    }

    /// The identity of every element of a scene, as a capture of it gives them: nil for content and for
    /// an element no capture keeps.
    static func identities(of elements: [SceneElement]) -> [SceneElementKey.Identity?] {
        let captures = elements.map(CaptureElement.init)
        let kept = captures.compactMap { $0 }
        var identities = SceneElementKey.identities(in: kept).makeIterator()
        return captures.map { capture in capture == nil ? nil : identities.next() ?? nil }
    }

    /// Each identified element of the state with what its relations offer, and the operations offered on
    /// the window itself: the verb with its arguments, the outcome and where it leads, alternatives side
    /// by side and a contradicted one marked. An element the structure does not tell from another gets
    /// nothing, whatever was learned on a control of its kind. One query for the whole scene.
    static func annotate(_ elements: [SceneElement], from sceneID: String, in bundleID: String,
                         relations: any BrainRelationReading) async throws -> (elements: [SceneElement], window: [String], applied: Bool) {
        var keys: [Int: String] = [:]
        for (index, identity) in identities(of: elements).enumerated() {
            if let key = identity?.key { keys[index] = key }
        }
        let found = try await relations.relations(from: sceneID, in: bundleID, elementKeys: Array(Set(keys.values)).sorted(),
                                                  includingContext: true)
        let offered = found.filter { $0.standing != .candidate }
        func line(_ relation: BrainRelation) -> String {
            relation.summary + (relation.standing == .limited ? " (contradicted ×\(relation.contradictions))" : "")
        }
        func ordered(_ relations: [BrainRelation]) -> [BrainRelation] {
            relations.sorted { ($0.supports, $1.relationID) > ($1.supports, $0.relationID) }
        }
        let byKey = Dictionary(grouping: offered.filter { $0.key.elementKey != nil }) { $0.key.elementKey ?? "" }
        var applied = false
        let annotated = elements.enumerated().map { index, element in
            guard let key = keys[index], let relations = byKey[key], !relations.isEmpty else { return element }
            applied = true
            var enriched = element
            enriched.does = ordered(relations).map(line).joined(separator: " | ")
            return enriched
        }
        let window = ordered(offered.filter { $0.key.elementKey == nil }).map { relation in
            line(relation) + condition(of: relation.key.verb)
        }
        return (annotated, window, applied || !window.isEmpty)
    }

    /// What an operation on the window needs that the memory does not know, said with it.
    static func condition(of verb: BrainVerb) -> String {
        switch verb {
            case .pressKey, .insertText: " · acts on the focused element, which was not recorded"
            case .scroll: " · over the window"
            default: ""
        }
    }
}
