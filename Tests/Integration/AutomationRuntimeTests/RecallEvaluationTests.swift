//
//  RecallEvaluationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalEmbedding
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// RecallEvaluationTests run the D3 comparison on the quality corpus, gated by `MECUM_RECALL_EVAL`, and write their
/// reports to `MECUM_RECALL_EVAL_OUT`; the semantic configurations need `MECUM_RECALL_MODELS`, and are reported as
/// skipped without it.
///
/// - `dev`: the corpus is learned once through the tools; each configuration's index is built on its own copy of
///   that archive, the corpus's later changes are applied through the index's work queue, every development query
///   is searched once (`RecallService.prepare`, the product's path) and selected under every point of the threshold
///   grid (`RecallService.outcomes`). The preregistered objective picks each configuration's thresholds: fewest
///   unsafe answers (incompatible deliveries and false complete coverages), then most correct queries, then the
///   point whose grid neighbours are most often correct, so a threshold on the edge of a cliff loses to one inside
///   a plateau.
/// - `final`: the frozen calibration (`Fixtures/recall-calibration-v1.json`) must name this corpus's digest; every
///   configuration is measured on the final split with its frozen thresholds, through the service and through
///   `memory_task begin`, whose deliveries must agree with the service's selections.
@MainActor
@Suite("Recall comparison on the quality corpus", .serialized)
struct RecallEvaluationTests {

    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static var mode: String? { environment["MECUM_RECALL_EVAL"] }
    nonisolated static var models: URL? { environment["MECUM_RECALL_MODELS"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    nonisolated static var output: URL? { environment["MECUM_RECALL_EVAL_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    // MARK: Configurations

    /// EvalConfiguration is one compared configuration: channel, model, document format and lexical weight.
    nonisolated struct EvalConfiguration: Sendable, Codable, Hashable {
        let channel: String
        let model: String?
        let format: String
        let weight: Double
        /// The lexical weighting (`LexicalIndex.Weighting`) of a lexical or hybrid configuration of the second corpus; nil
        /// in the first comparison, which used the collection's.
        var weighting: String? = nil

        var name: String {
            let base = switch channel {
                case "lexical": "lexical/\(format)"
                case "hybrid" : "hybrid\(weight)/\(model ?? "")/\(format)"
                default       : "\(channel)/\(model ?? "")/\(format)"
            }
            return weighting.map { "\(base)/\($0)" } ?? base
        }

        /// The archive copy the configuration's index lives in: one per embedding space and format.
        var archive: String { "\(model ?? "lexical")|\(format)" }

        func configuration(models: URL?) -> RecallConfiguration {
            var configuration = RecallConfiguration.chosen
            configuration.channel = RecallConfiguration.Channel(rawValue: channel) ?? .lexical
            configuration.model = model.flatMap { EmbeddingModelManifest.known[$0] }
            configuration.modelsDirectory = models
            configuration.format = RecallDocument.Format(rawValue: format) ?? .labelled
            configuration.hybridWeight = weight
            configuration.lexicalWeighting = LexicalIndex.Weighting(rawValue: weighting ?? "collection") ?? .collection
            return configuration
        }
    }

    nonisolated static let configurations: [EvalConfiguration] = {
        var all: [EvalConfiguration] = []
        for format in RecallDocument.Format.allCases.map(\.rawValue) {
            all.append(EvalConfiguration(channel: "lexical", model: nil, format: format, weight: 0))
            for model in ["e5-small", "granite-107m"] {
                all.append(EvalConfiguration(channel: "semantic", model: model, format: format, weight: 0))
                for weight in [0.2, 0.35, 0.5, 0.65] {
                    all.append(EvalConfiguration(channel: "hybrid", model: model, format: format, weight: weight))
                }
            }
        }
        return all
    }()

    // MARK: Threshold grid

    /// GridPoint is one point of the threshold grid with its index along each dimension.
    nonisolated struct GridPoint: Sendable {
        let thresholds: SelectionThresholds
        let index: [Int]
    }

    nonisolated enum Grid {
        static let stepMargin: [Double] = [0, 0.01, 0.02, 0.03, 0.05, 0.08, 0.12, 0.2]
        static let partMargin: [Double] = [-0.4, -0.3, -0.2, -0.15, -0.12, -0.1, -0.08, -0.06, -0.04, -0.02, 0]
        static let adequacy: [Double] = [0, 0.01, 0.02, 0.05, 0.1]
        static let tie: [Double] = [0, 0.01, 0.02, 0.04]

        /// The absolute thresholds tried for a configuration: by 0.01 from 0.1 below the lowest best score of a
        /// development need to the highest, so each channel's scale is covered where its decisions are made.
        static func absolute(_ queries: [PreparedQuery]) -> [Double] {
            let tops = queries.flatMap { $0.prepared.scores.map { $0.max() ?? 0 } }
            let low = max(0, (((tops.min() ?? 0) - 0.1) * 100).rounded(.down)) / 100
            let high = min(100, ((tops.max() ?? 1) * 100).rounded(.up)) / 100
            return stride(from: low, through: high + 0.0001, by: 0.01).map { ($0 * 100).rounded() / 100 }
        }

        static func points(_ absolute: [Double]) -> [GridPoint] {
            var points: [GridPoint] = []
            for (a, absolute) in absolute.enumerated() {
                for (s, step) in stepMargin.enumerated() {
                    for (p, part) in partMargin.enumerated() {
                        for (q, adequacy) in adequacy.enumerated() {
                            for (t, tie) in tie.enumerated() {
                                points.append(GridPoint(thresholds: SelectionThresholds(absolute: absolute, stepMargin: step, partMargin: part,
                                                                                        adequacy: adequacy, tie: tie),
                                                        index: [a, s, p, q, t]))
                            }
                        }
                    }
                }
            }
            return points
        }

        static var description: String {
            "absolute by 0.01 from 0.1 below the lowest best score of a development need to the highest, per configuration; "
                + "stepMargin \(stepMargin); partMargin \(partMargin); adequacy \(adequacy); tie \(tie)"
        }
    }

    // MARK: Archives

    /// Learns the corpus once into a closed archive, with a lexical index, and answers where it is.
    static func learnBase(_ corpus: RecallCorpus) async throws -> (URL, [String: RecallCorpus.Learned]) {
        let directory = try W.directory()
        let memory = MemoryService.shared(for: directory)
        RecallService.install(RecallService(memory: memory, configuration: EvalConfiguration(channel: "lexical", model: nil,
                                                                                             format: RecallDocument.Format.labelled.rawValue,
                                                                                             weight: 0).configuration(models: nil)))
        let learned = try await corpus.learn(into: directory)
        _ = await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(120))
        RecallService.forget(memory)
        await memory.close()
        MemoryService.forget(directory)
        return (directory, learned)
    }

    /// Archive is one configuration family's copy of the learned archive, its index built and the corpus's changes
    /// applied through the work queue.
    struct Archive {
        let directory: URL
        let memory: MemoryService
        var learned: [String: RecallCorpus.Learned]
        let build: Duration
    }

    static func archive(from base: URL, learned: [String: RecallCorpus.Learned], corpus: RecallCorpus,
                        configuration: RecallConfiguration) async throws -> Archive {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recall-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: base, to: directory)
        let memory = MemoryService.shared(for: directory)
        let service = RecallService(memory: memory, configuration: configuration)
        RecallService.install(service)
        let started = ContinuousClock.now
        await service.schedule()
        guard await service.waitUntilIdle(within: .seconds(900)) else { throw RecallCorpus.Failure("the index was not built in time") }
        let build = started.duration(to: .now)
        var learned = learned
        try await corpus.applyChanges(to: &learned, in: directory)
        guard await service.waitUntilIdle(within: .seconds(300)) else { throw RecallCorpus.Failure("the changes were not indexed in time") }
        let status = try await service.status()
        guard status.index.pendingWork == 0, status.workerFailure == nil else {
            throw RecallCorpus.Failure("index not settled: pending \(status.index.pendingWork), \(status.workerFailure ?? "-")")
        }
        return Archive(directory: directory, memory: memory, learned: learned, build: build)
    }

    static func close(_ archive: Archive) async {
        RecallService.forget(archive.memory)
        await archive.memory.close()
        MemoryService.forget(archive.directory)
    }

    // MARK: Searching

    /// PreparedQuery is one query searched once, with what judging it needs and how long its searches took.
    nonisolated struct PreparedQuery: Sendable {
        let query: JSONValue
        let prepared: RecallService.Prepared
        let values: [TaskValue]
        let sources: [String: RecallSource]
        let searches: [Duration]
        /// Each need's versions with their parts' relevance, computed once: what every grid point selects from.
        let scored: [[ScoredSource]]?
    }

    /// Searches every query `repetitions` times after one search that loads the model; the first search's result
    /// is kept, every search is timed.
    static func prepare(_ queries: [JSONValue], service: RecallService, repetitions: Int = 3) async throws -> [PreparedQuery] {
        _ = try await service.prepare(try RecallRequest(taskID: "warm", attemptID: "warm", revision: 1, reason: .initial,
                                                        remainingWork: "Warm the model before the measures"))
        var prepared: [PreparedQuery] = []
        for query in queries {
            let request = try RecallCorpus.request(query)
            var first: RecallService.Prepared?
            var searches: [Duration] = []
            for _ in 0..<repetitions {
                let started = ContinuousClock.now
                let answer = try await service.prepare(request)
                searches.append(started.duration(to: .now))
                if first == nil { first = answer }
            }
            guard let first else { continue }
            prepared.append(PreparedQuery(query: query, prepared: first, values: request.values,
                                          sources: Dictionary(uniqueKeysWithValues: first.sources.map { ($0.routeID, $0) }),
                                          searches: searches, scored: service.scored(first)))
        }
        return prepared
    }

    /// The score of a set of prepared queries under one point of the grid.
    nonisolated static func score(_ queries: [PreparedQuery], thresholds: SelectionThresholds, service: RecallService,
                                  learned: [String: RecallCorpus.Learned]) -> RecallJudge.Score {
        var score = RecallJudge.Score()
        for query in queries {
            let outcomes = selections(query, thresholds: thresholds, service: service)
            let (verdict, needs) = RecallJudge.judge(query.query, outcomes: outcomes, sources: query.sources, values: query.values,
                                                     learned: learned)
            score.add(query: verdict, needs: needs)
        }
        return score
    }

    /// A prepared query's selections under one point, from its scored versions: what `RecallService.outcomes` does.
    nonisolated static func selections(_ query: PreparedQuery, thresholds: SelectionThresholds, service: RecallService) -> [NeedOutcome] {
        guard let scored = query.scored else { return service.outcomes(query.prepared, thresholds: thresholds) }
        return query.prepared.needs.enumerated().map { index, need in
            RecallSelector.select(position: index, need: need, sources: scored[index], context: query.prepared.context, thresholds: thresholds)
        }
    }

    /// The score of every grid point, in parallel over the points.
    nonisolated static func sweep(_ queries: [PreparedQuery], service: RecallService, learned: [String: RecallCorpus.Learned],
                                  points: [GridPoint]) async -> [RecallJudge.Score] {
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let size = (points.count + workers - 1) / workers
        return await withTaskGroup(of: (Int, [RecallJudge.Score]).self) { group in
            for start in stride(from: 0, to: points.count, by: size) {
                let slice = Array(points[start..<min(points.count, start + size)])
                group.addTask {
                    (start, slice.map { score(queries, thresholds: $0.thresholds, service: service, learned: learned) })
                }
            }
            var scores = [RecallJudge.Score](repeating: RecallJudge.Score(), count: points.count)
            for await (start, part) in group { for (offset, score) in part.enumerated() { scores[start + offset] = score } }
            return scores
        }
    }

    /// The preregistered objective: fewest unsafe answers, then most correct queries.
    nonisolated static func precedes(_ a: RecallJudge.Score, _ b: RecallJudge.Score) -> Bool {
        if a.unsafe != b.unsafe { return a.unsafe < b.unsafe }
        return a.correct > b.correct
    }

    /// The optimal points of a sweep, and among them the one whose neighbours along each dimension are most often
    /// correct; ties go to the higher absolute threshold, then to the smaller margins, so the choice is conservative.
    nonisolated static func choose(_ points: [GridPoint], _ scores: [RecallJudge.Score]) -> (best: Int, optimal: Int, neighbourhood: Double) {
        let best = scores.indices.min { precedes(scores[$0], scores[$1]) }!
        let optimal = scores.indices.filter { !precedes(scores[best], scores[$0]) }
        var byIndex: [[Int]: Int] = [:]
        for (offset, point) in points.enumerated() { byIndex[point.index] = offset }
        func neighbourhood(_ offset: Int) -> Double {
            var sum = 0, count = 0
            for dimension in 0..<points[offset].index.count {
                for step in [-1, 1] {
                    var index = points[offset].index
                    index[dimension] += step
                    guard let neighbour = byIndex[index] else { continue }
                    sum += scores[neighbour].unsafe == 0 ? scores[neighbour].correct : 0
                    count += 1
                }
            }
            return count == 0 ? 0 : Double(sum) / Double(count)
        }
        let ranked = optimal.map { ($0, neighbourhood($0)) }.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let x = points[a.0].thresholds, y = points[b.0].thresholds
            if x.absolute != y.absolute { return x.absolute > y.absolute }
            if x.stepMargin != y.stepMargin { return x.stepMargin < y.stepMargin }
            if x.adequacy != y.adequacy { return x.adequacy < y.adequacy }
            if x.tie != y.tie { return x.tie > y.tie }
            return x.partMargin < y.partMargin
        }
        return (ranked[0].0, optimal.count, ranked[0].1)
    }

    /// The share of needs with an accepted selection whose accepted version is among the first `limit` entries.
    nonisolated static func candidateRecall(_ queries: [PreparedQuery], service: RecallService, learned: [String: RecallCorpus.Learned],
                                            limit: Int) -> Double {
        var wanted = 0, found = 0
        for query in queries {
            let expectations = query.query["expect"]["needs"].array ?? [query.query["expect"]]
            for (index, expect) in expectations.enumerated() {
                let routes = Set((expect["accept"].array ?? []).compactMap { RecallCorpus.Learned.route($0["knowledge"].string ?? "", in: learned) })
                guard !routes.isEmpty else { continue }
                wanted += 1
                if service.ranked(query.prepared, need: index, limit: limit).contains(where: { routes.contains($0.routeID) }) { found += 1 }
            }
        }
        return wanted == 0 ? 1 : Double(found) / Double(wanted)
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    nonisolated static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[min(sorted.count - 1, max(0, rank))]
    }

    // MARK: Reports

    nonisolated struct QueryDetail: Sendable, Codable {
        let id: String
        let family: String
        let kind: String
        let language: String
        let correct: Bool
        let unsafe: Bool
        let answer: String
        let verdict: RecallJudge.Verdict
    }

    nonisolated struct ConfigurationReport: Sendable, Codable {
        let configuration: EvalConfiguration
        let name: String
        var skipped: String?
        var indexBuildMS: Double?
        var absoluteRange: [Double]?
        var thresholds: SelectionThresholds?
        var score: RecallJudge.Score?
        var optimalPoints: Int?
        var neighbourhoodCorrect: Double?
        var candidateRecall: [String: Double]?
        var searchP50MS: Double?
        var searchP95MS: Double?
        var selectionMeanUS: Double?
        var details: [QueryDetail]?
        var toolAgreement: String?

        /// Correct queries over all, for the requests in Italian or mixed, and for those in English.
        var byLanguage: [String: String] {
            guard let details else { return [:] }
            func ratio(_ subset: [QueryDetail]) -> String { "\(subset.filter(\.correct).count)/\(subset.count)" }
            return ["it+mixed": ratio(details.filter { $0.language != "en" }), "en": ratio(details.filter { $0.language == "en" })]
        }
    }

    nonisolated struct Report: Sendable, Codable {
        let mode: String
        let corpus: String
        let corpusDigest: String
        let queries: Int
        let grid: String
        let objective: String
        var configurations: [ConfigurationReport]
        var chosen: String?
        var rationale: String?
    }

    nonisolated static let objective = "minimize unsafe = incompatible deliveries + false complete coverages; then maximize correct queries; "
        + "then maximize the mean correct of the point's grid neighbours (unsafe neighbours count 0); then higher absolute, smaller "
        + "stepMargin, smaller adequacy, larger tie, smaller partMargin"

    static func details(_ queries: [PreparedQuery], thresholds: SelectionThresholds, service: RecallService,
                        learned: [String: RecallCorpus.Learned]) -> [QueryDetail] {
        queries.map { query in
            let outcomes = selections(query, thresholds: thresholds, service: service)
            let (verdict, needs) = RecallJudge.judge(query.query, outcomes: outcomes, sources: query.sources, values: query.values,
                                                     learned: learned)
            return QueryDetail(id: query.query["id"].string ?? "", family: query.query["family"].string ?? "",
                               kind: query.query["kind"].string ?? "", language: query.query["language"].string ?? "",
                               correct: verdict.correct,
                               unsafe: needs.contains { $0.incompatible || $0.falseComplete },
                               answer: RecallJudge.describe(outcomes, learned: learned), verdict: verdict)
        }
    }

    static func write(_ report: Report, name: String) throws {
        guard let output else { return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output.appendingPathComponent("\(name).json"))
        var lines = ["# Recall \(report.mode)", "", "corpus \(report.corpus) sha256 \(report.corpusDigest), \(report.queries) queries",
                     "grid: \(report.grid)", "objective: \(report.objective)", "",
                     "| configuration | correct | it+mixed | en | unsafe | incompatible | false complete | exact selection | absence | bindings | R@10 | R@48 | search p50/p95 ms | thresholds |",
                     "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for item in report.configurations {
            guard let score = item.score, let thresholds = item.thresholds else {
                lines.append("| \(item.name) | skipped: \(item.skipped ?? "-") |||||||||||||")
                continue
            }
            func ratio(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : "\(a)/\(b)" }
            lines.append("| \(item.name) | \(score.correct)/\(score.queries) | \(item.byLanguage["it+mixed"] ?? "-") | \(item.byLanguage["en"] ?? "-") | \(score.unsafe) | \(score.incompatible) | \(score.falseComplete) | "
                + "\(ratio(score.selectionRight, score.selectionExpected)) | \(ratio(score.absenceRight, score.absenceExpected)) | "
                + "\(ratio(score.bindingsRight, score.bindingsExpected)) | "
                + String(format: "%.2f | %.2f | %.1f/%.1f", item.candidateRecall?["10"] ?? 0, item.candidateRecall?["48"] ?? 0,
                         item.searchP50MS ?? 0, item.searchP95MS ?? 0)
                + " | a=\(thresholds.absolute) s=\(thresholds.stepMargin) p=\(thresholds.partMargin) q=\(thresholds.adequacy) t=\(thresholds.tie) |")
        }
        if let chosen = report.chosen { lines += ["", "chosen: \(chosen)", report.rationale ?? ""] }
        for item in report.configurations {
            guard let details = item.details else { continue }
            lines += ["", "## \(item.name)" + (item.toolAgreement.map { " — tool agreement \($0)" } ?? ""), ""]
            for detail in details {
                lines.append("- \(detail.correct ? "ok  " : (detail.unsafe ? "UNSAFE" : "wrong")) \(detail.id) (\(detail.kind)): \(detail.answer)")
            }
        }
        try lines.joined(separator: "\n").write(to: output.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }

    // MARK: Development

    @Test("development split: calibrate each configuration's thresholds on the grid",
          .enabled(if: mode == "dev", "MECUM_RECALL_EVAL=dev asks for the calibration"))
    func development() async throws {
        let corpus = try RecallCorpus.load()
        let queries = corpus.queries(split: "dev")
        let (base, learned) = try await Self.learnBase(corpus)
        var report = Report(mode: "development", corpus: corpus.version, corpusDigest: corpus.digest, queries: queries.count,
                            grid: Grid.description, objective: Self.objective, configurations: [])
        var archives: [String: Archive] = [:]
        for configuration in Self.configurations {
            var item = ConfigurationReport(configuration: configuration, name: configuration.name)
            if configuration.model != nil, Self.models == nil {
                item.skipped = "MECUM_RECALL_MODELS names no folder of the pinned models"
                report.configurations.append(item)
                continue
            }
            let recall = configuration.configuration(models: Self.models)
            if archives[configuration.archive] == nil {
                for (_, open) in archives { await Self.close(open) }
                archives = [configuration.archive: try await Self.archive(from: base, learned: learned, corpus: corpus, configuration: recall)]
            }
            let archive = archives[configuration.archive]!
            let service = RecallService(memory: archive.memory, configuration: recall)
            RecallService.install(service)
            let prepared = try await Self.prepare(queries, service: service)
            let channels = Set(prepared.map(\.prepared.channel.rawValue))
            #expect(channels == [configuration.channel], "\(configuration.name) answered on \(channels)")
            let absolute = Grid.absolute(prepared)
            #expect(absolute.count > 5, "the absolute grid of \(configuration.name) is \(absolute)")
            let points = Grid.points(absolute)
            item.absoluteRange = [absolute.first ?? 0, absolute.last ?? 0]
            let started = ContinuousClock.now
            let scores = await Self.sweep(prepared, service: service, learned: archive.learned, points: points)
            let sweep = Self.milliseconds(started.duration(to: .now))
            let (best, optimal, neighbourhood) = Self.choose(points, scores)
            let thresholds = points[best].thresholds
            let searches = prepared.flatMap(\.searches).map(Self.milliseconds)
            item.indexBuildMS = Self.milliseconds(archive.build)
            item.thresholds = thresholds
            item.score = scores[best]
            item.optimalPoints = optimal
            item.neighbourhoodCorrect = neighbourhood
            item.candidateRecall = Dictionary(uniqueKeysWithValues: [1, 5, 10, 48].map {
                ("\($0)", Self.candidateRecall(prepared, service: service, learned: archive.learned, limit: $0))
            })
            item.searchP50MS = Self.percentile(searches, 0.5)
            item.searchP95MS = Self.percentile(searches, 0.95)
            item.selectionMeanUS = sweep * 1000 / Double(points.count * max(1, prepared.count))
            item.details = Self.details(prepared, thresholds: thresholds, service: service, learned: archive.learned)
            print("RECALL-EVAL dev \(configuration.name): correct \(scores[best].correct)/\(scores[best].queries) unsafe \(scores[best].unsafe) "
                  + "optimal \(optimal) sweep \(Int(sweep)) ms thresholds \(thresholds)")
            report.configurations.append(item)
            try Self.write(report, name: "recall-eval-dev")
        }
        for (_, open) in archives { await Self.close(open) }
        try Self.write(report, name: "recall-eval-dev")
    }

    // MARK: Diagnosis of the scales

    /// Prints, for every development query and each embedding space, the raw semantic score of the best entry, its
    /// standard score against every entry of the generation, the lexical score of the best entry, and the best score
    /// of an accepted version's parts, to compare how each scale separates present needs from absent ones. A
    /// diagnosis of the development split only: it asserts nothing.
    @Test("development split: the scales of the channels, printed", .enabled(if: mode == "scales", "MECUM_RECALL_EVAL=scales asks for it"))
    func scales() async throws {
        let corpus = try RecallCorpus.load()
        let queries = corpus.queries(split: "dev")
        let (base, learned) = try await Self.learnBase(corpus)
        for model in ["e5-small", "granite-107m"] {
            let configuration = EvalConfiguration(channel: "semantic", model: model, format: RecallDocument.Format.labelled.rawValue, weight: 0)
            let recall = configuration.configuration(models: Self.models)
            let archive = try await Self.archive(from: base, learned: learned, corpus: corpus, configuration: recall)
            let service = RecallService(memory: archive.memory, configuration: recall)
            RecallService.install(service)
            let prepared = try await Self.prepare(queries, service: service, repetitions: 1)
            for query in prepared {
                let expectations = query.query["expect"]["needs"].array ?? [query.query["expect"]]
                for (index, expect) in expectations.enumerated() {
                    let cache = query.prepared.cache!
                    let all = query.prepared.scores[index]
                    let scores = cache.live.map { all[$0] }
                    let mean = scores.reduce(0, +) / Double(scores.count)
                    let deviation = (scores.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(scores.count)).squareRoot()
                    let routes = Set((expect["accept"].array ?? []).compactMap { RecallCorpus.Learned.route($0["knowledge"].string ?? "", in: archive.learned) })
                    let accepted = cache.live.filter { routes.contains(cache.slots[$0]?.routeID ?? "") }.map { all[$0] }.max()
                    let top = scores.max() ?? 0
                    print(String(format: "SCALE %@ %-12@ need %d absent=%@ top %.3f z %.2f mean %.3f sd %.3f accepted %@",
                                 model, query.query["id"].string ?? "", index, RecallJudge.strings(expect["coverage"]) == ["absent"] ? "yes" : "no ",
                                 top, deviation > 0 ? (top - mean) / deviation : 0, mean, deviation,
                                 accepted.map { String(format: "%.3f z %.2f", $0, deviation > 0 ? ($0 - mean) / deviation : 0) } ?? "-"))
                }
            }
            await Self.close(archive)
        }
    }

    /// Prints, for the configurations `MECUM_RECALL_EVAL_CONFIGS` names (comma separated, all when absent), each
    /// development query's selection under the thresholds `MECUM_RECALL_EVAL_POINT` gives (`absolute,step,part,
    /// adequacy,tie`), with the relevance of every step and whole part of the accepted versions. A diagnosis of the
    /// development split only: it asserts nothing.
    @Test("development split: selections at one point, printed", .enabled(if: mode == "point", "MECUM_RECALL_EVAL=point asks for it"))
    func point() async throws {
        let values = (Self.environment["MECUM_RECALL_EVAL_POINT"] ?? "0.5,0.05,-0.15,0.05,0.01").split(separator: ",").compactMap { Double($0) }
        let thresholds = SelectionThresholds(absolute: values[0], stepMargin: values[1], partMargin: values[2], adequacy: values[3], tie: values[4])
        let wanted = Self.environment["MECUM_RECALL_EVAL_CONFIGS"].map { Set($0.split(separator: ",").map(String.init)) }
        let corpus = try RecallCorpus.load()
        let queries = corpus.queries(split: "dev")
        let (base, learned) = try await Self.learnBase(corpus)
        var archives: [String: Archive] = [:]
        for configuration in Self.configurations where wanted?.contains(configuration.name) ?? true {
            let recall = configuration.configuration(models: Self.models)
            if archives[configuration.archive] == nil {
                for (_, open) in archives { await Self.close(open) }
                archives = [configuration.archive: try await Self.archive(from: base, learned: learned, corpus: corpus, configuration: recall)]
            }
            let archive = archives[configuration.archive]!
            let service = RecallService(memory: archive.memory, configuration: recall)
            RecallService.install(service)
            let prepared = try await Self.prepare(queries, service: service, repetitions: 1)
            let score = Self.score(prepared, thresholds: thresholds, service: service, learned: archive.learned)
            print("POINT \(configuration.name) \(thresholds): correct \(score.correct)/\(score.queries) unsafe \(score.unsafe)")
            for detail in Self.details(prepared, thresholds: thresholds, service: service, learned: archive.learned) {
                print("POINT   \(detail.correct ? "ok    " : (detail.unsafe ? "UNSAFE" : "wrong ")) \(detail.id): \(detail.answer)")
                guard let query = prepared.first(where: { $0.query["id"].string == detail.id }), let cache = query.prepared.cache else { continue }
                let expect = query.query["expect"]["needs"].array?.first ?? query.query["expect"]
                for item in expect["accept"].array ?? [] {
                    guard let route = RecallCorpus.Learned.route(item["knowledge"].string ?? "", in: archive.learned),
                          let source = query.sources[route] else { continue }
                    let steps = source.steps.map { step in
                        cache.byPart[step.partID].map { String(format: "%d:%.3f", step.position + 1, query.prepared.scores[0][$0]) } ?? "\(step.position + 1):-"
                    }.joined(separator: " ")
                    let parts = source.parts.filter { $0.kind != .step }.map { part in
                        cache.byPart[part.partID].map { String(format: "%@%d-%d:%.3f", part.kind == .procedure ? "P" : "S", part.firstPosition + 1,
                                                               part.lastPosition + 1, query.prepared.scores[0][$0]) } ?? "-"
                    }.joined(separator: " ")
                    print("POINT       \(item["knowledge"].string ?? "") steps \(steps) | \(parts) | units \(source.units.map { "\($0.positions.lowerBound + 1)-\($0.positions.upperBound + 1)\($0.isUncertain ? "?" : "")" }.joined(separator: ","))")
                }
            }
        }
        for (_, open) in archives { await Self.close(open) }
    }

    // MARK: Final

    /// Calibration is the frozen outcome of the development split with the preregistered acceptance, written before
    /// the final split runs: the thresholds of each configuration, the inviolable criteria and their bounds, the
    /// latency budget, and the rule that chooses among the configurations that meet the criteria.
    nonisolated struct Calibration: Sendable, Codable {
        let corpus: String
        let corpusDigest: String
        let objective: String
        let criteria: [String]
        let latencyBudgetMS: Double
        let maximumIncompatible: Int
        let maximumFalseComplete: Int
        let minimumAbsenceRight: Int
        let minimumItalianCorrect: Int
        let minimumCorrect: Int
        let thresholds: [String: SelectionThresholds]
    }

    /// The criteria a configuration's final measure fails, by name; empty when it meets them all.
    nonisolated static func failures(_ item: ConfigurationReport, _ calibration: Calibration) -> [String] {
        guard let score = item.score else { return ["not measured"] }
        var failed: [String] = []
        if score.incompatible > calibration.maximumIncompatible { failed.append("C1 incompatible \(score.incompatible)") }
        if score.falseComplete > calibration.maximumFalseComplete { failed.append("C2 false complete \(score.falseComplete)") }
        if score.absenceRight < calibration.minimumAbsenceRight { failed.append("C3 absence \(score.absenceRight)/\(score.absenceExpected)") }
        let italian = (item.details ?? []).filter { $0.language != "en" }
        if italian.filter(\.correct).count < calibration.minimumItalianCorrect {
            failed.append("C4 Italian \(italian.filter(\.correct).count)/\(italian.count)")
        }
        if score.correct < calibration.minimumCorrect { failed.append("C5 correct \(score.correct)/\(score.queries)") }
        return failed
    }

    @Test("final split: every configuration with its frozen thresholds, through the service and through the tool",
          .enabled(if: mode == "final", "MECUM_RECALL_EVAL=final asks for the final measure"))
    func final() async throws {
        let corpus = try RecallCorpus.load()
        let url = try #require(Bundle.module.url(forResource: "recall-calibration-v1", withExtension: "json"),
                               "the frozen calibration is not among the test resources")
        let calibration = try JSONDecoder().decode(Calibration.self, from: try Data(contentsOf: url))
        try #require(calibration.corpusDigest == corpus.digest, "the calibration was frozen on another corpus")
        let queries = corpus.queries(split: "final")
        let (base, learned) = try await Self.learnBase(corpus)
        var report = Report(mode: "final", corpus: corpus.version, corpusDigest: corpus.digest, queries: queries.count,
                            grid: "frozen thresholds of recall-calibration-v1.json (sha256 \(RecallCorpus.sha256(try Data(contentsOf: url))))",
                            objective: calibration.objective, configurations: [])
        var archives: [String: Archive] = [:]
        for configuration in Self.configurations {
            var item = ConfigurationReport(configuration: configuration, name: configuration.name)
            guard let thresholds = calibration.thresholds[configuration.name] else {
                item.skipped = "no frozen thresholds"
                report.configurations.append(item)
                continue
            }
            if configuration.model != nil, Self.models == nil {
                item.skipped = "MECUM_RECALL_MODELS names no folder of the pinned models"
                report.configurations.append(item)
                continue
            }
            let recall = configuration.configuration(models: Self.models)
            if archives[configuration.archive] == nil {
                for (_, open) in archives { await Self.close(open) }
                archives = [configuration.archive: try await Self.archive(from: base, learned: learned, corpus: corpus, configuration: recall)]
            }
            let archive = archives[configuration.archive]!
            var frozen = recall
            switch frozen.channel {
                case .lexical : frozen.lexicalThresholds = thresholds
                case .semantic: frozen.semanticThresholds = thresholds
                case .hybrid  : frozen.hybridThresholds = thresholds
            }
            let service = RecallService(memory: archive.memory, configuration: frozen)
            RecallService.install(service)
            let prepared = try await Self.prepare(queries, service: service)
            let score = Self.score(prepared, thresholds: thresholds, service: service, learned: archive.learned)
            let searches = prepared.flatMap(\.searches).map(Self.milliseconds)
            item.indexBuildMS = Self.milliseconds(archive.build)
            item.thresholds = thresholds
            item.score = score
            item.candidateRecall = Dictionary(uniqueKeysWithValues: [1, 5, 10, 48].map {
                ("\($0)", Self.candidateRecall(prepared, service: service, learned: archive.learned, limit: $0))
            })
            item.searchP50MS = Self.percentile(searches, 0.5)
            item.searchP95MS = Self.percentile(searches, 0.95)
            item.details = Self.details(prepared, thresholds: thresholds, service: service, learned: archive.learned)

            // The same queries through the product's entry: the delivery must agree with the service's selection.
            var agreeing = 0
            for query in prepared {
                let tools = ProcedureLearningTests.tools(LearningSession(directory: archive.directory), stream: "final-\(query.query["id"].string ?? "")")
                let answer = try await tools.call("memory_task", RecallCorpus.begin(query.query)).payload["recall"]
                let outcomes = service.outcomes(query.prepared)
                let same = answer["coverage"].string == NeedOutcome.overall(outcomes).rawValue
                    && (answer["needs"].array ?? []).count == outcomes.count
                    && zip(answer["needs"].array ?? [], outcomes).allSatisfy { need, outcome in
                        let steps = need["selection"]["steps"].array?.compactMap { RecallJudge.number($0["step"]) } ?? []
                        return need["coverage"].string == outcome.coverage.rawValue
                            && need["selection"]["version"].string == outcome.selected?.routeID
                            && steps.first == outcome.selected.map { $0.firstPosition + 1 }
                            && steps.last == outcome.selected.map { $0.lastPosition + 1 }
                    }
                if same { agreeing += 1 } else { Issue.record("\(configuration.name) \(query.query["id"].string ?? ""): the tool delivered \(answer)") }
            }
            item.toolAgreement = "\(agreeing)/\(prepared.count)"
            print("RECALL-EVAL final \(configuration.name): correct \(score.correct)/\(score.queries) unsafe \(score.unsafe) tool \(agreeing)/\(prepared.count)")
            report.configurations.append(item)
            try Self.write(report, name: "recall-eval-final")
        }
        for (_, open) in archives { await Self.close(open) }

        // The preregistered choice: among the configurations that meet every inviolable criterion, fewest unsafe
        // answers, then most correct, then the simpler channel (lexical, semantic, hybrid), then the smaller lexical
        // weight, then the name. The latency budget is measured and reported, not a criterion of correctness.
        var verdicts: [String] = []
        for item in report.configurations where item.score != nil {
            let failed = Self.failures(item, calibration)
            let latency = (item.searchP95MS ?? .infinity) <= calibration.latencyBudgetMS ? "within" : "over"
            verdicts.append("\(item.name): " + (failed.isEmpty ? "meets C1–C5" : "fails " + failed.joined(separator: ", "))
                            + "; warm search p95 \(latency) the budget")
        }
        let measured = report.configurations.filter { $0.score != nil && Self.failures($0, calibration).isEmpty }
        let order = ["lexical": 0, "semantic": 1, "hybrid": 2]
        let chosen = measured.min { a, b in
            let x = a.score!, y = b.score!
            if x.unsafe != y.unsafe { return x.unsafe < y.unsafe }
            if x.correct != y.correct { return x.correct > y.correct }
            let p = order[a.configuration.channel] ?? 3, q = order[b.configuration.channel] ?? 3
            if p != q { return p < q }
            if a.configuration.weight != b.configuration.weight { return a.configuration.weight < b.configuration.weight }
            return a.name < b.name
        }
        report.chosen = chosen?.name ?? "none: no configuration meets the preregistered criteria"
        report.rationale = "criteria: " + calibration.criteria.joined(separator: " ") + "\n\n" + verdicts.joined(separator: "\n")
        try Self.write(report, name: "recall-eval-final")
    }
}
