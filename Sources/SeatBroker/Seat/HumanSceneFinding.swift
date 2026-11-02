//
//  HumanSceneFinding.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AutomationRuntime
import Foundation
import InteractionObservation
import PerceptionCore

/// HumanSceneFinding retains one reconstruction as LZFSE bytes, or a named absence of evidence.
/// Window and baseline sequence identify a difference even when another window intervened.
/// Sequence zero is the full final state; action findings use text-only perception.
/// Sizes count UTF-8 before compression and retained bytes after it.
nonisolated struct HumanSceneFinding: Sendable {
    enum Kind: String, Sendable, Codable {
        case keyframe
        case changes
        case unchanged = "no changes"
        case covered
        case superseded
        case failed = "read failed"
    }

    enum Reason: String, Sendable, Codable {
        case read = "surface unavailable"
        case noWindows = "no current windows"
        case byteBudget = "intervention byte budget exhausted"
        case compression = "compression failed"
    }

    /// SceneEvidence keeps minimized snapshots for net and transient differences, charged with the finding.
    struct SceneEvidence: Codable, Sendable {
        var scenes: [Int: SceneSnapshot] = [:]
        var initialScenes: [Int: SceneSnapshot] = [:]
        var closedWindowNumbers: [Int] = []
    }

    let sequence: UInt64
    var mode: ProductionPerception.Mode { sequence == 0 ? .full : .textOnly }
    let windowNumber: Int?
    let baselineSequence: UInt64?
    let kind: Kind
    let reason: Reason?
    let compressed: Data
    private let compressedScenes: Data
    let rawBytes: Int
    var readMilliseconds: Double
    var coveredBySequence: UInt64?
    var inputDuringRead = false
    var provenance: HumanReadProvenance? = nil
    var recordedAction: HumanRecordedInteraction.SummaryAction?
    var compressedBytes: Int {
        compressed.count + compressedScenes.count + (provenance?.surfaces.reduce(256) {
            $0 + 256 + ($1.semantics?.retainedBytes ?? 0)
        } ?? 0)
    }

    init(
        sequence: UInt64,
        kind: Kind,
        text: String,
        readMilliseconds: Double,
        reason: Reason? = nil,
        windowNumber: Int? = nil,
        baselineSequence: UInt64? = nil,
        scenes: [Int: SceneSnapshot] = [:],
        initialScenes: [Int: SceneSnapshot] = [:],
        closedWindowNumbers: [Int] = []
    ) throws {
        let raw = Data(text.utf8)
        self.sequence = sequence
        self.windowNumber = windowNumber
        self.baselineSequence = baselineSequence
        self.kind = kind
        self.reason = reason
        let evidence = SceneEvidence(
            scenes: scenes.mapValues(HumanInterventionConsumer.minimized),
            initialScenes: initialScenes.mapValues(HumanInterventionConsumer.minimized),
            closedWindowNumbers: closedWindowNumbers
        )
        let sceneBytes = scenes.isEmpty && initialScenes.isEmpty && closedWindowNumbers.isEmpty
            ? Data() : try JSONEncoder().encode(evidence)
        compressedScenes = sceneBytes.isEmpty ? Data() : try (sceneBytes as NSData).compressed(using: .lzfse) as Data
        rawBytes = raw.count + sceneBytes.count
        compressed = try (raw as NSData).compressed(using: .lzfse) as Data
        self.readMilliseconds = readMilliseconds
    }

    init(
        sequence: UInt64,
        kind: Kind,
        reason: Reason? = nil,
        readMilliseconds: Double = 0,
        windowNumber: Int? = nil
    ) {
        self.sequence = sequence
        self.windowNumber = windowNumber
        baselineSequence = nil
        self.kind = kind
        self.reason = reason
        compressed = Data()
        compressedScenes = Data()
        rawBytes = 0
        self.readMilliseconds = readMilliseconds
    }

    func sceneEvidence() throws -> SceneEvidence {
        guard !compressedScenes.isEmpty else { return SceneEvidence() }
        let data = try (compressedScenes as NSData).decompressed(using: .lzfse) as Data
        return try JSONDecoder().decode(SceneEvidence.self, from: data)
    }

    func text() throws -> String {
        guard !compressed.isEmpty else { return "" }
        let data = try (compressed as NSData).decompressed(using: .lzfse) as Data
        return String(decoding: data, as: UTF8.self)
    }
}

#if DEBUG
extension HumanSceneFinding: Codable {}
#endif
