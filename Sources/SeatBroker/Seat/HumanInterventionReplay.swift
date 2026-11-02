//
//  HumanInterventionReplay.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

#if DEBUG
import Foundation
import Engine

/// HumanInterventionReplay retains minimized findings and action metadata, never event payloads or pictures.
/// Archives are version 3 (findings with structural reads); earlier versions are not read. Blobs contain LZFSE-compressed Codable findings, including their original compressed evidence.
nonisolated enum HumanInterventionReplay {
    private struct Manifest: Codable {
        let version: Int
        let actions: [HumanRecordedInteraction.SummaryAction?]
        let findingCount: Int
        /// The model whose vectors ranked the report's causes, "id@revision"; absent in older archives.
        var embeddingModel: String? = nil
    }

    private enum Failure: Error {
        case unsupportedArchive
    }

    @concurrent
    static func write(
        _ review: HumanInterventionConsumer.Intervention.Review,
        embeddingModel: String? = nil,
        to directory: URL
    ) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        for (index, finding) in (review.findings + [review.finalState]).enumerated() {
            let bytes = try encoder.encode(finding)
            let compressed = try (bytes as NSData).compressed(using: .lzfse) as Data
            try compressed.write(to: directory.appendingPathComponent("finding-\(index).lzfse"), options: .atomic)
        }
        let manifest = Manifest(
            version: 3,
            actions: review.findings.map(\.recordedAction),
            findingCount: review.findings.count,
            embeddingModel: embeddingModel
        )
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("review.json"), options: .atomic)
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
