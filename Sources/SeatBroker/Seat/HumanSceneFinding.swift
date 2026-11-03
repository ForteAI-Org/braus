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
        #if DEBUG
        // Scene encoding omits label origins; retain only SG3's positions while that provenance is available.
        var replayProtectedPositions: [Int: [Int]]? = nil
        var initialReplayProtectedPositions: [Int: [Int]]? = nil
        #endif
    }

    let sequence: UInt64
    var mode: ProductionPerception.Mode { sequence == 0 ? .full : .textOnly }
    let windowNumber: Int?
    let baselineSequence: UInt64?
    let kind: Kind
    let reason: Reason?
    private(set) var compressed: Data
    private var compressedScenes: Data
    private(set) var rawBytes: Int
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
        var evidence = SceneEvidence(
            scenes: scenes.mapValues(HumanInterventionConsumer.minimized),
            initialScenes: initialScenes.mapValues(HumanInterventionConsumer.minimized),
            closedWindowNumbers: closedWindowNumbers
        )
        #if DEBUG
        let classifier = SensitivityClassifier()
        func protectedPositions(_ scenes: [Int: SceneSnapshot]) -> [Int: [Int]] {
            scenes.mapValues { scene in
                scene.elements.indices.filter { classifier.classify(scene.elements[$0]).sensitivity != .ordinary }
            }
        }
        evidence.replayProtectedPositions = protectedPositions(evidence.scenes)
        evidence.initialReplayProtectedPositions = protectedPositions(evidence.initialScenes)
        #endif
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
import Memory

extension HumanSceneFinding: Codable {
    /// Decodes and minimizes both compressed payloads before retaining any replay bytes.
    /// Invalid evidence throws so the writer can omit it and count the omission.
    func withholding(_ transform: (String) -> String) throws -> HumanSceneFinding {
        let evidence = try sceneEvidence()
        let classifier = SensitivityClassifier()
        var sensitive: Set<String> = []
        func collect(_ scenes: [Int: SceneSnapshot], positions: [Int: [Int]]?) {
            for (window, scene) in scenes {
                let protected = positions?[window].map(Set.init)
                for index in scene.elements.indices {
                    let element = scene.elements[index]
                    let isProtected = protected?.contains(index)
                        ?? (classifier.classify(element).sensitivity != .ordinary)
                    guard isProtected else { continue }
                    if !element.label.isEmpty { sensitive.insert(element.label) }
                    if let value = element.value, !value.isEmpty { sensitive.insert(value) }
                }
            }
        }
        collect(evidence.scenes, positions: evidence.replayProtectedPositions)
        collect(evidence.initialScenes, positions: evidence.initialReplayProtectedPositions)
        let fragments = sensitive.sorted { $0.count > $1.count }
        func safe(_ text: String) -> String {
            var result = transform(text)
            for fragment in fragments { result = result.replacingOccurrences(of: fragment, with: "[withheld]") }
            return result
        }
        let raw = Data(try safe(text()).utf8)
        let minimized = try Self.withheldValue(evidence, by: safe)
        let sceneBytes = try JSONEncoder().encode(minimized)
        var result = self
        result.compressed = try (raw as NSData).compressed(using: .lzfse) as Data
        result.compressedScenes = try (sceneBytes as NSData).compressed(using: .lzfse) as Data
        result.rawBytes = raw.count + sceneBytes.count
        result.provenance = try Self.withheldValue(provenance, by: safe)
        result.recordedAction = try Self.withheldValue(recordedAction, by: safe)
        return result
    }

    /// Visits string values, including future Codable text fields; object keys remain structural.
    private static func withheldValue<T: Codable>(_ value: T, by transform: (String) -> String) throws -> T {
        func visit(_ value: Any) -> Any {
            if let text = value as? String { return transform(text) }
            if let array = value as? [Any] { return array.map(visit) }
            if let object = value as? [String: Any] { return object.mapValues(visit) }
            return value
        }
        let bytes = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
        let minimized = try JSONSerialization.data(withJSONObject: visit(object), options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: minimized)
    }
}
#endif
