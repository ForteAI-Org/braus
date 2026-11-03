//
//  HumanInterventionReplay.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

#if DEBUG
import Foundation
import Engine
import Memory

/// HumanInterventionReplay retains minimized findings and action metadata, never event payloads or pictures.
/// Archives are version 3 (findings with structural reads); earlier versions are not read. Blobs contain LZFSE-compressed Codable findings, including their minimized compressed evidence.
nonisolated enum HumanInterventionReplay {
    private struct Manifest: Codable {
        let version: Int
        let actions: [HumanRecordedInteraction.SummaryAction?]
        let findingCount: Int
        /// The model whose vectors ranked the report's causes, "id@revision"; absent in older archives.
        var embeddingModel: String? = nil
        var omittedFindingCount: Int? = nil
    }

    private enum Failure: Error {
        case unsupportedArchive
    }

    /// Keeps the owner's transform on its calling actor; compressed findings are processed on the pool.
    static func write(
        _ review: HumanInterventionConsumer.Intervention.Review,
        embeddingModel: String? = nil,
        to directory: URL,
        withholding: (String) -> String = { $0 },
        processing: @Sendable () -> Void = {}
    ) async throws {
        let prepared = await prepare(review, embeddingModel: embeddingModel, processing: processing)
        let replacements = Dictionary(uniqueKeysWithValues: prepared.strings.map { ($0, withholding($0)) })
        try await persist(prepared, embeddingModel: embeddingModel, replacements: replacements,
                          to: directory, processing: processing)
    }

    private struct Prepared: Sendable {
        let findings: [HumanSceneFinding]
        let finalState: HumanSceneFinding
        let strings: Set<String>
        let omitted: Int
    }

    /// Collects every string the owner's transform will visit without transferring its actor-bound callback.
    @concurrent
    private static func prepare(
        _ review: HumanInterventionConsumer.Intervention.Review,
        embeddingModel: String?,
        processing: @Sendable () -> Void
    ) async -> Prepared {
        processing()
        var strings: Set<String> = []
        if let embeddingModel { strings.insert(embeddingModel) }
        func collect(_ text: String) -> String { strings.insert(text); return text }
        var findings: [HumanSceneFinding] = []
        var omitted = 0
        for finding in review.findings {
            do {
                _ = try finding.withholding(collect)
                findings.append(finding)
            } catch { omitted += 1 }
        }
        let finalState: HumanSceneFinding
        do {
            _ = try review.finalState.withholding(collect)
            finalState = review.finalState
        } catch {
            omitted += 1
            finalState = HumanSceneFinding(sequence: 0, kind: .failed, reason: .compression)
        }
        return Prepared(findings: findings, finalState: finalState, strings: strings, omitted: omitted)
    }

    @concurrent
    private static func persist(
        _ prepared: Prepared,
        embeddingModel: String?,
        replacements: [String: String],
        to directory: URL,
        processing: @Sendable () -> Void
    ) async throws {
        processing()
        let classifier = SensitivityClassifier()
        func safe(_ text: String) -> String {
            let text = replacements[text] ?? text
            let findings = classifier.findings(in: text, field: .init())
            var result = text
            for finding in findings.reversed()
            where SensitivityTable.arrival(finding.verdict.sensitivity, at: .debugReplay) != .value {
                result.replaceSubrange(finding.range, with: "[withheld]")
            }
            return result
        }
        var findings: [HumanSceneFinding] = []
        var omitted = prepared.omitted
        for finding in prepared.findings {
            do { findings.append(try finding.withholding(safe)) }
            catch { omitted += 1 }
        }
        let finalState: HumanSceneFinding
        do { finalState = try prepared.finalState.withholding(safe) }
        catch {
            omitted += 1
            finalState = HumanSceneFinding(sequence: 0, kind: .failed, reason: .compression)
        }
        let manifest = Manifest(
            version: 3,
            actions: findings.map(\.recordedAction),
            findingCount: findings.count,
            embeddingModel: embeddingModel.map(safe),
            omittedFindingCount: omitted
        )
        let saved = findings + [finalState]
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        for (index, finding) in saved.enumerated() {
            let bytes = try encoder.encode(finding)
            let compressed = try (bytes as NSData).compressed(using: .lzfse) as Data
            let file = directory.appendingPathComponent("finding-\(index).lzfse")
            try compressed.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let file = directory.appendingPathComponent("review.json")
        try encoder.encode(manifest).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    struct Archive: Sendable {
        let version: Int
        let findings: [HumanSceneFinding]
        let finalState: HumanSceneFinding
        var embeddingModel: String? = nil
    }

    @concurrent
    static func read(_ directory: URL) async throws -> Archive {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("review.json")))
        guard manifest.version == 3, (0...4096).contains(manifest.findingCount) else {
            throw Failure.unsupportedArchive
        }
        var findings: [HumanSceneFinding] = []
        for index in 0...manifest.findingCount {
            let compressed = try Data(contentsOf: directory.appendingPathComponent("finding-\(index).lzfse"))
            let bytes = try (compressed as NSData).decompressed(using: .lzfse) as Data
            findings.append(try decoder.decode(HumanSceneFinding.self, from: bytes))
        }
        guard let final = findings.popLast() else { throw Failure.unsupportedArchive }
        return Archive(version: manifest.version, findings: findings, finalState: final, embeddingModel: manifest.embeddingModel)
    }

    @concurrent
    static func replay(_ directory: URL) async throws -> HumanInterventionSummary.Digest {
        let archive = try await read(directory)
        return HumanInterventionSummary.digest(HumanInterventionEvidence(findings: archive.findings, finalState: archive.finalState))
    }
}
#endif
