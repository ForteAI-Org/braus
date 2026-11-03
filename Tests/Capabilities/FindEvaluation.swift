import AutomationMCP
@testable import Capabilities
import CryptoKit
import Foundation
import LocalEmbedding
import Memory
import Testing

/// FindEvaluation evaluates a representative catalogue until the facade supplies its catalogue.
/// The tuning split is used only for selecting settings; verification never influences that selection.
enum FindEvaluation {
    struct Fixture: Decodable {
        struct Entry: Decodable {
            let id: String
            let group: String
            let description: String
            let examples: [String]
        }
        struct Question: Decodable {
            let id: String
            let language: String
            let split: String
            let query: String
            let expected: String
        }
        let entries: [Entry]
        let questions: [Question]
    }

    struct Report: Encodable, Sendable {
        let schema = "capability-evaluation/1"
        let commit: String
        let worktree_dirty: Bool
        let fixture_sha256: String
        let model_id: String
        let verification_count: Int
        let top3_hits: Int
        let none_count: Int
        let none_hits: Int
        let warm_query_count: Int
        let latency_ms: [Double]
        let hardware: String
        let tests_skipped: [String]
        let semantic_weight: Double
        let minimum_score: Double
        let minimum_cosine: Double
        let tuning_count = 75
        let tuning_none_count = 15
        let settings_applied_to_production: Bool
        let tuning_top3_hits: Int
        let tuning_none_hits: Int
        let tuning_failures: [Failure]
        let verification_failures: [Failure]
        let catalogue_source = "representative_fixture_pending_catalogue_composition"
        let integration_pending = ["Facade search injection and both dispatcher transports"]
        let lexical_top3_hits: Int
        let lexical_none_hits: Int
    }

    struct Failure: Encodable, Sendable {
        let id: String
        let expected: String
        let returned: [String]
    }

    static let hasModels = ProcessInfo.processInfo.environment["BRAUS_RECALL_MODELS"] != nil
    static let verifies = ProcessInfo.processInfo.environment["BRAUS_FIND_TUNING_ONLY"] != "1"
    static let result = Task { try await evaluate() }

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/find-questions.json")
    }

    static func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
    }

    static func permitsVerification(
        tuningOnly: Bool = false,
        tuningPasses: Bool,
        usesProductionSettings: Bool
    ) -> Bool {
        !tuningOnly && tuningPasses && usesProductionSettings
    }

    static func evaluate() async throws -> Report {
        let fixture = try fixture()
        let entries = fixture.entries.map {
            searchEntry($0.id, group: $0.group, description: $0.description, examples: $0.examples)
        }
        let directory = try #require(ProcessInfo.processInfo.environment["BRAUS_RECALL_MODELS"])
        let manifest = EmbeddingModelManifest.graniteEmbedding107MMultilingual
        let source = EmbeddingService.Source(manifest: manifest,
            directory: URL(fileURLWithPath: directory).appendingPathComponent(manifest.directoryName))
        let service = EmbeddingService.shared
        if let failure = await service.ready(source) { throw failure }
        let documents = CatalogueEmbedding(source: source, role: .document)
        let queries = CatalogueEmbedding(source: source, role: .query)
        let vectors = try await CatalogueVectors.prepare(entries: entries, embedding: documents)
        let tuning = fixture.questions.filter { $0.split == "tuning" }
        let queryVectors = try await queries.vectors(for: tuning.map(\.query))
        let recorded = RecordedQueryEmbedding(modelID: queries.modelID,
            values: Dictionary(uniqueKeysWithValues: zip(tuning.map(\.query), queryVectors)))
        var selected = CapabilitySearch.Settings()
        var best = -1
        var trials: [[String: Double]] = []
        for weight in [0.8, 0.7, 0.6, 0.9, 0.5] {
            for threshold in [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9] {
                for cosine in [0.3, 0.35, 0.4, 0.45, 0.5, 0.525, 0.55, 0.575, 0.58, 0.585,
                               0.59, 0.595, 0.6, 0.625, 0.65] {
                    let settings = CapabilitySearch.Settings(semanticWeight: weight,
                        minimumScore: threshold, minimumCosine: cosine)
                    let search = CapabilitySearch(entries: entries, vectors: vectors, embedding: recorded, settings: settings)
                    let scores = await quality(tuning, search: search)
                    trials.append(["semantic_weight": weight, "minimum_score": threshold,
                                   "minimum_cosine": cosine, "top3_hits": Double(scores.0),
                                   "none_hits": Double(scores.1)])
                    let satisfies = scores.0 >= 57 && scores.1 >= 14
                    let objective = (satisfies ? 10_000 : 0) + scores.0 + scores.1
                    if objective > best || (objective == best && settings == CapabilitySearch.Settings()) {
                        best = objective
                        selected = settings
                    }
                }
            }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".scratch/find")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let selectedSearch = CapabilitySearch(entries: entries, vectors: vectors, embedding: recorded, settings: selected)
        let tuned = await quality(tuning, search: selectedSearch)
        let tuningData = try JSONSerialization.data(withJSONObject: [
            "semantic_weight": selected.semanticWeight, "minimum_score": selected.minimumScore,
            "minimum_cosine": selected.minimumCosine, "objective": Double(best),
            "top3_hits": tuned.0, "positive_count": 60, "none_hits": tuned.1, "none_count": 15,
            "trials": trials, "failures": tuned.2.map {
                ["id": $0.id, "expected": $0.expected, "returned": $0.returned] as [String: Any]
            }
        ], options: [.prettyPrinted, .sortedKeys])
        try tuningData.write(to: root.appendingPathComponent("tuning.json"), options: .atomic)
        // Tuning runs can keep verification sealed while catalogue text and settings are still changing.
        let canVerify = permitsVerification(tuningOnly: !verifies, tuningPasses: best >= 10_000,
            usesProductionSettings: selected == CapabilitySearch.Settings())
        let search = CapabilitySearch(entries: entries, vectors: vectors, embedding: queries, settings: selected)
        let verification = canVerify ? fixture.questions.filter { $0.split == "verification" } : []
        let scores = await quality(verification, search: search)
        let lexical = await quality(verification, search: CapabilitySearch(entries: entries))
        let timedQuestions = canVerify ? verification : tuning
        _ = await search.search("Scroll down the page", limit: 5)
        var latency: [Double] = []
        let clock = ContinuousClock()
        for index in 0..<200 {
            let start = clock.now
            _ = await search.search(timedQuestions[index % timedQuestions.count].query, limit: 5)
            let duration = start.duration(to: clock.now).components
            latency.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        }
        let hardware: String
        if let supplied = ProcessInfo.processInfo.environment["BRAUS_FIND_HARDWARE"] {
            hardware = supplied
        } else {
            hardware = try command("/usr/sbin/sysctl", ["-n", "hw.model"])
        }
        let report = Report(commit: try command("/usr/bin/git", ["rev-parse", "HEAD"]),
            worktree_dirty: !(try command("/usr/bin/git", ["status", "--porcelain"])).isEmpty,
            fixture_sha256: SHA256.hash(data: try Data(contentsOf: fixtureURL)).map { String(format: "%02x", $0) }.joined(),
            model_id: queries.modelID, verification_count: verification.count,
            top3_hits: scores.0, none_count: verification.filter { $0.expected == "none" }.count,
            none_hits: scores.1, warm_query_count: latency.count, latency_ms: latency,
            hardware: hardware + "; " + ProcessInfo.processInfo.operatingSystemVersionString,
            tests_skipped: canVerify ? [] : [verifies
                ? "verification: tuning thresholds or production settings are not satisfied"
                : "verification: BRAUS_FIND_TUNING_ONLY=1"],
            semantic_weight: selected.semanticWeight, minimum_score: selected.minimumScore,
            minimum_cosine: selected.minimumCosine, settings_applied_to_production: selected == CapabilitySearch.Settings(),
            tuning_top3_hits: tuned.0, tuning_none_hits: tuned.1,
            tuning_failures: tuned.2, verification_failures: scores.2,
            lexical_top3_hits: lexical.0, lexical_none_hits: lexical.1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: root.appendingPathComponent("capability-evaluation.json"), options: .atomic)
        print("Find evaluation: tuning top3=\(tuned.0)/60 none=\(tuned.1)/15; verification count=\(verification.count) top3=\(scores.0) none=\(scores.1); p95=\(latency.sorted()[189]) ms; \(root.path)")
        return report
    }

    static func quality(_ questions: [Fixture.Question], search: CapabilitySearch) async -> (Int, Int, [Failure]) {
        var top3 = 0
        var none = 0
        var failures: [Failure] = []
        for question in questions {
            let hits = await search.search(question.query, limit: 5)
            if question.expected == "none" {
                if hits.isEmpty { none += 1 }
            } else if hits.prefix(3).contains(where: { $0.id.rawValue == question.expected }) {
                top3 += 1
            }
            if question.expected == "none" ? !hits.isEmpty
                : !hits.prefix(3).contains(where: { $0.id.rawValue == question.expected }) {
                failures.append(Failure(id: question.id, expected: question.expected, returned: hits.map(\.id.rawValue)))
            }
        }
        return (top3, none, failures)
    }

    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw EvaluationFailure.commandFailed }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum EvaluationFailure: Error { case commandFailed, missingQuery }
}

struct RecordedQueryEmbedding: Capabilities.TextEmbedding {
    let modelID: String
    let values: [String: [Float]]
    func vectors(for texts: [String]) async throws -> [[Float]] {
        try texts.map {
            guard let vector = values[$0] else { throw FindEvaluation.EvaluationFailure.missingQuery }
            return vector
        }
    }
}
