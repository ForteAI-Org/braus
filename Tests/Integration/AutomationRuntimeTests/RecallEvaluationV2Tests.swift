//
//  RecallEvaluationV2Tests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 12/10/2026.
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

/// RecallEvaluationV2Tests run the second comparison (review F05) on `recall-corpus-v2`, gated by `BRAUS_RECALL_EVAL`,
/// with the reports written to `BRAUS_RECALL_EVAL_OUT`. The first comparison, its corpus and its calibration stay as they
/// were, as history.
///
/// - `dev2`: every configuration is calibrated on the development and regression splits (all seen), in two conditions:
///   the archive holding all the corpus's knowledge, and, for the queries that name one, an archive holding only the
///   knowledge of their family, so the same thresholds must hold on a first learned procedure and among many others.
///   The objective is fewest unsafe answers on critical needs, then fewest unsafe answers, then most correct queries, then
///   the point inside a plateau, both conditions summed.
/// - `diagnose2`: a diagnosis of the phases on every split, for development (the second final is development since its
///   result), never a measure.
/// - `final2`: the frozen calibration (`Fixtures/recall-calibration-v2.json`) must name this corpus's digest; every
///   configuration is measured once on the final split, in both conditions, through the service and through
///   `memory_task begin`, and judged by the criteria frozen with it. Each phase is reported with its denominator:
///   candidates, threshold, final tract, binding, compatibility, coverage. The operational outcome of a delivery carried
///   out is measured by the cycle and sharing suites, not here.
@MainActor
@Suite("Recall comparison on the second quality corpus", .serialized, .automaticSelection)
struct RecallEvaluationV2Tests {

    typealias E = RecallEvaluationTests

    nonisolated static var mode: String? { E.environment["BRAUS_RECALL_EVAL"] }
    /// Whether the mode is the third comparison's (second review: selector 3 on `recall-corpus-v3`).
    nonisolated static var third: Bool { mode?.hasSuffix("3") == true }
    nonisolated static var corpusName: String { third ? "recall-corpus-v3" : "recall-corpus-v2" }
    nonisolated static var calibrationName: String { third ? "recall-calibration-v3" : "recall-calibration-v2" }
    nonisolated static var suffix: String { third ? "3" : "2" }

    /// The third comparison's configurations, fixed before it: the lexical channel the product answers with today (no model),
    /// and Granite, the semantic model the second comparison's development preferred, alone and in the hybrid it was best in.
    /// E5 is left out (it answered absent almost always in the second final) and so is the contextual format (worse in its
    /// development); the other weightings and weights change the relevance, which no longer delimits.
    nonisolated static let thirdConfigurations = ["lexical/recall-document-1/uniform", "semantic/granite-107m/recall-document-1",
                                                  "hybrid0.2/granite-107m/recall-document-1/uniform"]

    // MARK: Configurations

    /// The compared configurations: the first comparison's, the lexical and hybrid ones under each lexical weighting.
    /// `BRAUS_RECALL_EVAL_ONLY` keeps those whose name contains it, for a smoke run; a measure runs them all.
    nonisolated static var configurations: [E.EvalConfiguration] {
        let pool = third ? allConfigurations.filter { thirdConfigurations.contains($0.name) } : allConfigurations
        guard let only = E.environment["BRAUS_RECALL_EVAL_ONLY"] else { return pool }
        return pool.filter { $0.name.contains(only) }
    }

    nonisolated static let allConfigurations: [E.EvalConfiguration] = {
        var all: [E.EvalConfiguration] = []
        for format in RecallDocument.Format.allCases.map(\.rawValue) {
            for weighting in ["uniform", "version", "collection"] {
                all.append(E.EvalConfiguration(channel: "lexical", model: nil, format: format, weight: 0, weighting: weighting))
            }
            for model in ["e5-small", "granite-107m"] {
                all.append(E.EvalConfiguration(channel: "semantic", model: model, format: format, weight: 0))
                for weighting in ["uniform", "version", "collection"] {
                    for weight in [0.2, 0.35, 0.5, 0.65] {
                        all.append(E.EvalConfiguration(channel: "hybrid", model: model, format: format, weight: weight, weighting: weighting))
                    }
                }
            }
        }
        return all
    }()

    // MARK: Grid

    /// The second calibration's grid: the first one's absolute thresholds, coarser margins, so forty configurations over
    /// both conditions are swept in the time twenty-two took over one.
    nonisolated enum Grid {
        /// Selector 3 reads neither margin: the third calibration holds them at 0.
        static var stepMargin: [Double] { third ? [0] : [0, 0.01, 0.02, 0.05, 0.1] }
        static var partMargin: [Double] { third ? [0] : [-0.4, -0.3, -0.2, -0.1, -0.05, 0] }
        static let adequacy: [Double] = [0, 0.02, 0.05]
        static let tie: [Double] = [0, 0.02, 0.04]

        static func points(_ absolute: [Double]) -> [E.GridPoint] {
            var points: [E.GridPoint] = []
            for (a, absolute) in absolute.enumerated() {
                for (s, step) in stepMargin.enumerated() {
                    for (p, part) in partMargin.enumerated() {
                        for (q, adequacy) in adequacy.enumerated() {
                            for (t, tie) in tie.enumerated() {
                                points.append(E.GridPoint(thresholds: SelectionThresholds(absolute: absolute, stepMargin: step, partMargin: part,
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
            "absolute by 0.01 from 0.1 below the lowest best score of a need to the highest, per configuration; "
                + "stepMargin \(stepMargin); partMargin \(partMargin); adequacy \(adequacy); tie \(tie)"
        }
    }

    // MARK: Conditions

    /// Condition is one archive the queries are judged on: the full one, or a minimal one holding only some knowledge.
    struct Condition {
        let name: String
        let corpus: RecallCorpus
        let base: URL
        let learned: [String: RecallCorpus.Learned]
        let queries: [JSONValue]
    }

    /// The conditions of a split: the full archive with every query given, and one minimal archive per knowledge set the
    /// split's queries name in `bootstrap`, with those queries.
    static func conditions(_ corpus: RecallCorpus, queries: [JSONValue], bootstrapFrom: [JSONValue]) async throws -> [Condition] {
        let (base, learned) = try await E.learnBase(corpus)
        var conditions = [Condition(name: "full", corpus: corpus, base: base, learned: learned, queries: queries)]
        var sets: [[String]: [JSONValue]] = [:]
        for query in bootstrapFrom {
            guard let names = query["bootstrap"].array?.compactMap(\.string), !names.isEmpty else { continue }
            sets[names.sorted(), default: []].append(query)
        }
        for (names, members) in sets.sorted(by: { $0.key.joined() < $1.key.joined() }) {
            let minimal = corpus.restricted(to: Set(names))
            let (base, learned) = try await E.learnBase(minimal)
            conditions.append(Condition(name: "minimal:" + names.joined(separator: "+"), corpus: minimal, base: base, learned: learned,
                                        queries: members))
        }
        return conditions
    }

    // MARK: Searching

    /// The state a query says the session showed: the entry state of the source step it names, as the learned archive
    /// holds it.
    static func observed(_ query: JSONValue, learned: [String: RecallCorpus.Learned], service: RecallService) async throws -> Set<ObservedState> {
        guard let knowledge = query["observed"]["knowledge"].string, let step = RecallJudge.number(query["observed"]["step"]),
              let route = learned[knowledge]?.current else { return [] }
        let sources = try await service.memory.perform { try await $0.recall.sources([route]) }
        guard let source = sources.first?.step(step - 1), case .state(let scene) = source.entry, let bundle = source.bundleID else {
            Issue.record("\(query["id"].string ?? ""): the observed step has no known entry state")
            return []
        }
        return [ObservedState(bundleID: bundle, sceneID: scene)]
    }

    /// Searches every query of a condition `repetitions` times (the first result kept), with its observed state.
    static func prepare(_ queries: [JSONValue], service: RecallService, learned: [String: RecallCorpus.Learned],
                        repetitions: Int = 3) async throws -> [E.PreparedQuery] {
        _ = try await service.prepare(try RecallRequest(taskID: "warm", attemptID: "warm", revision: 1, reason: .initial,
                                                        remainingWork: "Warm the model before the measures"))
        var prepared: [E.PreparedQuery] = []
        for query in queries {
            let request = try RecallCorpus.request(query)
            let observed = try await Self.observed(query, learned: learned, service: service)
            var first: RecallService.Prepared?
            var searches: [Duration] = []
            for _ in 0..<repetitions {
                let started = ContinuousClock.now
                let answer = try await service.prepare(request, observed: observed)
                searches.append(started.duration(to: .now))
                if first == nil { first = answer }
            }
            guard let first else { continue }
            prepared.append(E.PreparedQuery(query: query, prepared: first, values: request.values,
                                            sources: Dictionary(uniqueKeysWithValues: first.sources.map { ($0.routeID, $0) }),
                                            searches: searches, scored: service.scored(first)))
        }
        return prepared
    }

    /// Searched is one condition's queries searched under one configuration.
    struct Searched {
        let condition: Condition
        let archive: E.Archive
        let service: RecallService
        let prepared: [E.PreparedQuery]
    }

    /// The score of every grid point, both conditions summed, in parallel over the points.
    nonisolated static func sweep(_ searched: [(prepared: [E.PreparedQuery], service: RecallService, learned: [String: RecallCorpus.Learned])],
                                  points: [E.GridPoint]) async -> [RecallJudge.Score] {
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let size = (points.count + workers - 1) / workers
        return await withTaskGroup(of: (Int, [RecallJudge.Score]).self) { group in
            for start in stride(from: 0, to: points.count, by: size) {
                let slice = Array(points[start..<min(points.count, start + size)])
                group.addTask {
                    (start, slice.map { point in
                        // Foundation's autoreleased strings are drained per point: a task thread has no pool of its own.
                        autoreleasepool {
                            searched.reduce(RecallJudge.Score()) { sum, item in
                                sum + E.score(item.prepared, thresholds: point.thresholds, service: item.service, learned: item.learned)
                            }
                        }
                    })
                }
            }
            var scores = [RecallJudge.Score](repeating: RecallJudge.Score(), count: points.count)
            for await (start, part) in group { for (offset, score) in part.enumerated() { scores[start + offset] = score } }
            return scores
        }
    }

    /// The objective of the second calibration, the inviolable criteria first: fewest incompatible deliveries and false
    /// complete coverages of critical needs, then most correct queries, then fewest false complete coverages.
    nonisolated static func precedes(_ a: RecallJudge.Score, _ b: RecallJudge.Score) -> Bool {
        let x = a.criticalFalseComplete + a.incompatible, y = b.criticalFalseComplete + b.incompatible
        if x != y { return x < y }
        if a.correct != b.correct { return a.correct > b.correct }
        return a.falseComplete < b.falseComplete
    }

    nonisolated static let objective = "minimize incompatible deliveries + false complete coverages of critical needs; then maximize "
        + "correct queries; then minimize false complete coverages; then the mean correct of the point's grid neighbours (unsafe "
        + "neighbours count 0); then higher absolute, smaller stepMargin, smaller adequacy, larger tie, smaller partMargin; the full "
        + "and the minimal archives summed"

    /// The optimal points under this objective, and among them the one inside the widest plateau (as the first calibration).
    nonisolated static func choose(_ points: [E.GridPoint], _ scores: [RecallJudge.Score]) -> (best: Int, optimal: Int, neighbourhood: Double) {
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

    // MARK: Phases

    /// Phases are one condition's measures at one point, each with its denominator: the positive needs (an accepted
    /// selection exists) found among the first 10 and 48 entries, kept by the absolute threshold, and selected exactly;
    /// the negative needs (absence expected) whose every entry stays under the threshold, and those answered absent; the
    /// bindings, exclusions and coverages as the judge counts them; the positives in Italian or mixed requests.
    nonisolated struct Phases: Sendable, Codable {
        /// Adds another set of queries' phases, for a sum over conditions.
        mutating func add(_ other: Phases) {
            positives += other.positives; candidates10 += other.candidates10; candidates48 += other.candidates48
            thresholdKept += other.thresholdKept; selectionRight += other.selectionRight; negatives += other.negatives
            thresholdRejected += other.thresholdRejected; absenceRight += other.absenceRight
            itMixedPositives += other.itMixedPositives; itMixedSelectionRight += other.itMixedSelectionRight
            score = score + other.score
        }

        var positives = 0
        var candidates10 = 0
        var candidates48 = 0
        var thresholdKept = 0
        var selectionRight = 0
        var negatives = 0
        var thresholdRejected = 0
        var absenceRight = 0
        var itMixedPositives = 0
        var itMixedSelectionRight = 0
        var score = RecallJudge.Score()
    }

    static func phases(_ queries: [E.PreparedQuery], thresholds: SelectionThresholds, service: RecallService,
                       learned: [String: RecallCorpus.Learned]) -> Phases {
        var phases = Phases()
        for query in queries {
            let outcomes = E.selections(query, thresholds: thresholds, service: service)
            let (verdict, needs) = RecallJudge.judge(query.query, outcomes: outcomes, sources: query.sources, values: query.values,
                                                     learned: learned)
            phases.score.add(query: verdict, needs: needs)
            let expectations = query.query["expect"]["needs"].array ?? [query.query["expect"]]
            for (index, expect) in expectations.enumerated() where index < needs.count {
                let routes = Set((expect["accept"].array ?? []).compactMap { RecallCorpus.Learned.route($0["knowledge"].string ?? "", in: learned) })
                let ranked = service.ranked(query.prepared, need: index, limit: 1_000_000)
                if !routes.isEmpty {
                    phases.positives += 1
                    if ranked.prefix(10).contains(where: { routes.contains($0.routeID) }) { phases.candidates10 += 1 }
                    if ranked.prefix(48).contains(where: { routes.contains($0.routeID) }) { phases.candidates48 += 1 }
                    if ranked.contains(where: { routes.contains($0.routeID) && $0.score >= thresholds.absolute }) { phases.thresholdKept += 1 }
                    if needs[index].selectionRight { phases.selectionRight += 1 }
                    if query.query["language"].string != "en" {
                        phases.itMixedPositives += 1
                        if needs[index].selectionRight { phases.itMixedSelectionRight += 1 }
                    }
                } else if RecallJudge.strings(expect["coverage"]) == ["absent"] {
                    phases.negatives += 1
                    if (ranked.first?.score ?? 0) < thresholds.absolute { phases.thresholdRejected += 1 }
                    if needs[index].absenceRight { phases.absenceRight += 1 }
                }
            }
        }
        return phases
    }

    // MARK: Reports

    nonisolated struct ConditionReport: Sendable, Codable {
        let condition: String
        let queries: Int
        let phases: Phases
        let searchP50MS: Double
        let searchP95MS: Double
        let details: [E.QueryDetail]
        var toolAgreement: String?
    }

    nonisolated struct ConfigurationReport: Sendable, Codable {
        let configuration: E.EvalConfiguration
        let name: String
        var skipped: String?
        var thresholds: SelectionThresholds?
        var absoluteRange: [Double]?
        var optimalPoints: Int?
        var neighbourhoodCorrect: Double?
        var score: RecallJudge.Score?
        var conditions: [ConditionReport] = []
        var failures: [String]?
    }

    nonisolated struct Report: Sendable, Codable {
        let mode: String
        let corpus: String
        let corpusDigest: String
        let grid: String
        let objective: String
        var configurations: [ConfigurationReport]
        var criteria: [String]?
        var chosen: String?
        /// The corpus check: by condition, the versions with steps whose entry state is unknown.
        var unknownEntryStates: [String: [String]]?
    }

    static func write(_ report: Report, name: String) throws {
        guard let output = E.output else { return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output.appendingPathComponent("\(name).json"))
        func ratio(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : "\(a)/\(b)" }
        var lines = ["# Recall \(report.mode)", "", "corpus \(report.corpus) sha256 \(report.corpusDigest)", "grid: \(report.grid)",
                     "objective: \(report.objective)", ""]
        if let criteria = report.criteria { lines += ["criteria:"] + criteria.map { "- \($0)" } + [""] }
        lines += ["| configuration | condition | correct | positives R@10 / R@48 | kept by threshold | exact selection | it+mixed selection | negatives under threshold | absent right | bindings | excluded right | incompatible | false complete | critical unsafe | p50/p95 ms | thresholds |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for item in report.configurations {
            guard let thresholds = item.thresholds else {
                lines.append("| \(item.name) | skipped: \(item.skipped ?? "-") ||||||||||||||")
                continue
            }
            for condition in item.conditions {
                let p = condition.phases, s = p.score
                lines.append("| \(item.name) | \(condition.condition) | \(s.correct)/\(s.queries) | \(ratio(p.candidates10, p.positives)) / \(ratio(p.candidates48, p.positives)) | "
                    + "\(ratio(p.thresholdKept, p.positives)) | \(ratio(p.selectionRight, p.positives)) | \(ratio(p.itMixedSelectionRight, p.itMixedPositives)) | "
                    + "\(ratio(p.thresholdRejected, p.negatives)) | \(ratio(p.absenceRight, p.negatives)) | \(ratio(s.bindingsRight, s.bindingsExpected)) | "
                    + "\(ratio(s.excludedRight, s.excludedExpected)) | \(s.incompatible) | \(s.falseComplete) | \(s.criticalUnsafe) | "
                    + String(format: "%.1f/%.1f", condition.searchP50MS, condition.searchP95MS)
                    + " | a=\(thresholds.absolute) s=\(thresholds.stepMargin) p=\(thresholds.partMargin) q=\(thresholds.adequacy) t=\(thresholds.tie) |")
            }
            if let failures = item.failures { lines.append("| \(item.name) | verdict: \(failures.isEmpty ? "meets K1–K6" : failures.joined(separator: "; ")) ||||||||||||||") }
        }
        if let chosen = report.chosen { lines += ["", "chosen: \(chosen)"] }
        for item in report.configurations {
            for condition in item.conditions {
                lines += ["", "## \(item.name) — \(condition.condition)" + (condition.toolAgreement.map { " — tool agreement \($0)" } ?? ""), ""]
                for detail in condition.details {
                    lines.append("- \(detail.correct ? "ok  " : (detail.unsafe ? "UNSAFE" : "wrong")) \(detail.id) (\(detail.kind), \(detail.language)): \(detail.answer)")
                }
            }
        }
        try lines.joined(separator: "\n").write(to: output.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
    }

    // MARK: One configuration

    /// One configuration over the conditions: each condition's archive (kept open across the configurations that share
    /// it), its service with `frozen` thresholds when given, and the searches.
    static func search(_ configuration: E.EvalConfiguration, conditions: [Condition], archives: inout [String: E.Archive],
                       frozen: SelectionThresholds? = nil) async throws -> [Searched] {
        var recall = configuration.configuration(models: E.models)
        if let frozen {
            switch recall.channel {
                case .lexical : recall.lexicalThresholds = frozen
                case .semantic: recall.semanticThresholds = frozen
                case .hybrid  : recall.hybridThresholds = frozen
            }
        }
        if !archives.keys.contains(where: { $0.hasPrefix(configuration.archive + "#") }) {
            for (_, open) in archives { await E.close(open) }
            archives = [:]
        }
        var searched: [Searched] = []
        for condition in conditions {
            let key = configuration.archive + "#" + condition.name
            if archives[key] == nil {
                archives[key] = try await E.archive(from: condition.base, learned: condition.learned, corpus: condition.corpus, configuration: recall)
            }
            let archive = archives[key]!
            let service = RecallService(memory: archive.memory, configuration: recall)
            RecallService.install(service)
            let prepared = try await Self.prepare(condition.queries, service: service, learned: archive.learned)
            let channels = Set(prepared.map(\.prepared.channel.rawValue))
            #expect(channels == [configuration.channel], "\(configuration.name) \(condition.name) answered on \(channels)")
            searched.append(Searched(condition: condition, archive: archive, service: service, prepared: prepared))
        }
        return searched
    }

    static func report(_ searched: [Searched], thresholds: SelectionThresholds) -> [ConditionReport] {
        searched.map { item in
            let searches = item.prepared.flatMap(\.searches).map(E.milliseconds)
            return ConditionReport(condition: item.condition.name, queries: item.prepared.count,
                                   phases: phases(item.prepared, thresholds: thresholds, service: item.service, learned: item.archive.learned),
                                   searchP50MS: E.percentile(searches, 0.5), searchP95MS: E.percentile(searches, 0.95),
                                   details: E.details(item.prepared, thresholds: thresholds, service: item.service, learned: item.archive.learned))
        }
    }

    // MARK: Corpus check

    /// By condition, every version the archive holds with the steps whose entry state is unknown: scenes the corpus's
    /// windows did not let the learning recognize. Such a step cannot be checked against an observed state, so its
    /// expected answers are partial at best; a corpus lists none before its holdout is frozen, or says why.
    static func unknownEntries(_ searched: [Searched]) async throws -> [String: [String]] {
        var found: [String: [String]] = [:]
        for item in searched {
            let routes = item.archive.learned.sorted { $0.key < $1.key }.flatMap { known in
                known.value.revisions.enumerated().map { (name: "\(known.key)@\($0.offset + 1)", route: $0.element) }
            }
            let sources = Dictionary(try await item.service.memory.perform { try await $0.recall.sources(routes.map(\.route)) }
                .map { ($0.routeID, $0) }, uniquingKeysWith: { first, _ in first })
            let lines = routes.compactMap { known -> String? in
                let unknown = sources[known.route]?.steps.filter { if case .unknown = $0.entry { true } else { false } } ?? []
                return unknown.isEmpty ? nil : "\(known.name): steps " + unknown.map { String($0.position + 1) }.joined(separator: ", ")
            }
            if !lines.isEmpty { found[item.condition.name] = lines }
        }
        return found
    }

    // MARK: Development

    @Test("second corpus, development: calibrate every configuration on development and regression, full and minimal archives",
          .enabled(if: mode == "dev2" || mode == "dev3", "BRAUS_RECALL_EVAL=dev2 or dev3 asks for the calibration"))
    func development() async throws {
        let corpus = try RecallCorpus.load(Self.corpusName)
        let development = corpus.queries(split: "dev")
        let conditions = try await Self.conditions(corpus, queries: development + corpus.queries(split: "regression"), bootstrapFrom: development)
        print("RECALL-EVAL dev\(Self.suffix) conditions: " + conditions.map { "\($0.name) \($0.queries.count)" }.joined(separator: ", ")
              + " footprint \(Int(RecallScaleTests.footprintMB())) MB")
        var report = Report(mode: Self.third ? "development (third corpus, selector 3)" : "development (second corpus)", corpus: corpus.version,
                            corpusDigest: corpus.digest,
                            grid: Grid.description, objective: Self.objective, configurations: [])
        var archives: [String: E.Archive] = [:]
        for configuration in Self.configurations {
            var item = ConfigurationReport(configuration: configuration, name: configuration.name)
            if configuration.model != nil, E.models == nil {
                item.skipped = "BRAUS_RECALL_MODELS names no folder of the pinned models"
                report.configurations.append(item)
                continue
            }
            let searched = try await Self.search(configuration, conditions: conditions, archives: &archives)
            if report.unknownEntryStates == nil { report.unknownEntryStates = try await Self.unknownEntries(searched) }
            let absolute = E.Grid.absolute(searched.flatMap(\.prepared))
            let points = Grid.points(absolute)
            print("RECALL-EVAL dev\(Self.suffix) \(configuration.name): searched, \(points.count) points, footprint \(Int(RecallScaleTests.footprintMB())) MB")
            let started = ContinuousClock.now
            let scores = await Self.sweep(searched.map { ($0.prepared, $0.service, $0.archive.learned) }, points: points)
            let sweep = E.milliseconds(started.duration(to: .now))
            let (best, optimal, neighbourhood) = Self.choose(points, scores)
            let thresholds = points[best].thresholds
            item.thresholds = thresholds
            item.absoluteRange = [absolute.first ?? 0, absolute.last ?? 0]
            item.optimalPoints = optimal
            item.neighbourhoodCorrect = neighbourhood
            item.score = scores[best]
            item.conditions = Self.report(searched, thresholds: thresholds)
            // A diagnosis of development only: the details at another point, given as absolute,step,part,adequacy,tie.
            if let point = E.environment["BRAUS_RECALL_EVAL_POINT"]?.split(separator: ",").compactMap({ Double($0) }), point.count == 5 {
                let other = SelectionThresholds(absolute: point[0], stepMargin: point[1], partMargin: point[2], adequacy: point[3], tie: point[4])
                var diagnosis = ConfigurationReport(configuration: configuration, name: configuration.name + " at " + point.map { String($0) }.joined(separator: ","))
                diagnosis.thresholds = other
                diagnosis.conditions = Self.report(searched, thresholds: other)
                var extra = report
                extra.configurations = [diagnosis]
                try Self.write(extra, name: "recall-eval-dev\(Self.suffix)-point")
            }
            print("RECALL-EVAL dev\(Self.suffix) \(configuration.name): correct \(scores[best].correct)/\(scores[best].queries) critical unsafe "
                  + "\(scores[best].criticalUnsafe) unsafe \(scores[best].unsafe) optimal \(optimal) sweep \(Int(sweep)) ms thresholds \(thresholds)")
            report.configurations.append(item)
            try Self.write(report, name: "recall-eval-dev\(Self.suffix)")
        }
        for (_, open) in archives { await E.close(open) }
    }

    // MARK: Diagnosis

    /// A diagnosis of the selector's phases, never a measure: for the configurations `BRAUS_RECALL_EVAL_ONLY` names, at
    /// their frozen thresholds (or `BRAUS_RECALL_EVAL_POINT`), every query of every split on the full and the minimal
    /// archives, with the candidates, each step's and part's relevance in the versions concerned, the episodes, the
    /// selection and its requirements. The second final is development since its result: reading it here is allowed.
    @Test("second corpus, diagnosis: every split's queries with their candidates, relevances, episodes and requirements",
          .enabled(if: mode == "diagnose2" || mode == "diagnose3", "BRAUS_RECALL_EVAL=diagnose2 or diagnose3 asks for it"))
    func diagnosis() async throws {
        let corpus = try RecallCorpus.load(Self.corpusName)
        let url = try #require(Bundle.module.url(forResource: Self.calibrationName, withExtension: "json"))
        let calibration = try JSONDecoder().decode(Calibration.self, from: try Data(contentsOf: url))
        let all = corpus.queries(split: "regression") + corpus.queries(split: "dev") + corpus.queries(split: "final")
        let conditions = try await Self.conditions(corpus, queries: all, bootstrapFrom: all)
        var archives: [String: E.Archive] = [:]
        for configuration in Self.configurations {
            guard configuration.model == nil || E.models != nil else { continue }
            var thresholds = try #require(calibration.thresholds[configuration.name])
            if let point = E.environment["BRAUS_RECALL_EVAL_POINT"]?.split(separator: ",").compactMap({ Double($0) }), point.count == 5 {
                thresholds = SelectionThresholds(absolute: point[0], stepMargin: point[1], partMargin: point[2], adequacy: point[3], tie: point[4])
            }
            let searched = try await Self.search(configuration, conditions: conditions, archives: &archives, frozen: thresholds)
            var lines = ["# Diagnosis \(configuration.name) at \(thresholds)", "", "## Corpus check: versions with unknown entry states", ""]
            let unknown = try await Self.unknownEntries(searched)
            lines += unknown.isEmpty ? ["none"] : unknown.sorted { $0.key < $1.key }.flatMap { ["- \($0.key)"] + $0.value.map { "  - \($0)" } }
            for item in searched {
                lines += ["", "## \(item.condition.name)", ""]
                for query in item.prepared {
                    let outcomes = E.selections(query, thresholds: thresholds, service: item.service)
                    let (verdict, needs) = RecallJudge.judge(query.query, outcomes: outcomes, sources: query.sources, values: query.values,
                                                             learned: item.archive.learned)
                    let unsafe = needs.contains { $0.incompatible || $0.falseComplete }
                    lines.append("### \(verdict.correct ? "ok" : (unsafe ? "UNSAFE" : "wrong")) \(query.query["id"].string ?? "") "
                                 + "[\(query.query["split"].string ?? "")] (\(query.query["kind"].string ?? ""))")
                    lines.append("- request: \(query.query["remaining"].string ?? "") | constraints \(query.query["constraints"]) | inputs \(query.query["inputs"])")
                    lines.append("- expect: \(query.query["expect"])")
                    lines.append("- answer: \(RecallJudge.describe(outcomes, learned: item.archive.learned))")
                    for (index, outcome) in outcomes.enumerated() {
                        let ranked = item.service.ranked(query.prepared, need: index, limit: 6)
                        lines.append("- need \(index + 1) candidates: " + ranked.map { "\($0.partID.split(separator: "/").suffix(2).joined(separator: "/"))=\(String(format: "%.3f", $0.score))" }.joined(separator: ", "))
                        let accepted = Set(((query.query["expect"]["needs"].array?[index] ?? query.query["expect"])["accept"].array ?? [])
                            .compactMap { RecallCorpus.Learned.route($0["knowledge"].string ?? "", in: item.archive.learned) })
                        let concerned = accepted.union([outcome.selected?.routeID].compactMap { $0 })
                        for scored in query.scored?[index] ?? [] where concerned.contains(scored.source.routeID) {
                            let source = scored.source
                            let steps = source.steps.map { step in
                                "\(step.position + 1):" + (scored.stepRelevance[step.position].map { String(format: "%.2f", $0) } ?? "-")
                            }.joined(separator: " ")
                            let parts = source.parts.filter { $0.kind != .step }.map { part in
                                "\(part.kind.rawValue)[\(part.firstPosition + 1)-\(part.lastPosition + 1)]="
                                    + (scored.partRelevance[part.partID].map { String(format: "%.2f", $0) } ?? "-")
                            }.joined(separator: " ")
                            let units = source.units.map { "\($0.positions.lowerBound + 1)-\($0.positions.upperBound + 1)\($0.isUncertain ? "?" : "")" }
                            lines.append("  - \(source.routeID.prefix(18))… \(source.procedureLabel): steps \(steps) | parts \(parts) | episodes \(units)")
                        }
                        if let selected = outcome.selected {
                            lines.append("  - selected \(selected.firstPosition + 1)-\(selected.lastPosition + 1) \(outcome.coverage.rawValue): "
                                         + selected.requirements.map { "\($0.kind.rawValue)" + ($0.stepPosition.map { "@\($0 + 1)" } ?? "")
                                            + ($0.parameterID.map { "{\($0.split(separator: "/").last ?? "")}" } ?? "") }.joined(separator: ", "))
                        }
                    }
                }
            }
            // The phases of each condition by split, as the comparisons count them.
            var summary: [String: Phases] = [:]
            for item in searched {
                for split in ["regression", "dev", "final"] {
                    let queries = item.prepared.filter { $0.query["split"].string == split }
                    guard !queries.isEmpty else { continue }
                    summary["\(item.condition.name.hasPrefix("minimal") ? "minimal" : "full")/\(split)", default: Phases()]
                        .add(Self.phases(queries, thresholds: thresholds, service: item.service, learned: item.archive.learned))
                }
            }
            if let output = E.output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let name = configuration.name.replacingOccurrences(of: "/", with: "_")
                try lines.joined(separator: "\n").write(to: output.appendingPathComponent("diagnosis-\(name).md"), atomically: true, encoding: .utf8)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(summary).write(to: output.appendingPathComponent("phases-\(name).json"))
            }
        }
        for (_, open) in archives { await E.close(open) }
    }

    // MARK: Final

    /// Calibration is the frozen second calibration: the corpus it was frozen on, the thresholds of every configuration,
    /// the criteria and their numbers, the objective.
    nonisolated struct Calibration: Sendable, Codable {
        let corpus: String
        let corpusDigest: String
        let objective: String
        let criteria: [String]
        let thresholds: [String: SelectionThresholds]
        let minimumPositiveSelection: Int
        let minimumItalianMixedSelection: Int
        let minimumMinimalPositiveSelection: Int
        let minimumNegativesFull: Int
        let minimumNegativesMinimal: Int
        let latencyBudgetMS: Double
    }

    /// The criteria a measured configuration fails, by the frozen numbers.
    nonisolated static func failures(_ item: ConfigurationReport, _ calibration: Calibration) -> [String] {
        var failed: [String] = []
        let full = item.conditions.first { $0.condition == "full" }?.phases
        let minimal = item.conditions.filter { $0.condition != "full" }.map(\.phases)
        let all = item.conditions.map(\.phases)
        let incompatible = all.reduce(0) { $0 + $1.score.incompatible }
        let criticalFalse = all.reduce(0) { $0 + $1.score.criticalFalseComplete }
        if incompatible > 0 { failed.append("K1 incompatible deliveries \(incompatible)") }
        if criticalFalse > 0 { failed.append("K2 false complete on critical needs \(criticalFalse)") }
        if let full {
            if full.selectionRight < calibration.minimumPositiveSelection { failed.append("K3 positives \(full.selectionRight)/\(full.positives)") }
            if full.itMixedSelectionRight < calibration.minimumItalianMixedSelection {
                failed.append("K4 Italian and mixed positives \(full.itMixedSelectionRight)/\(full.itMixedPositives)")
            }
            if full.absenceRight < calibration.minimumNegativesFull { failed.append("K6 negatives \(full.absenceRight)/\(full.negatives) (full)") }
        } else {
            failed.append("no full condition")
        }
        let minimalSelection = minimal.reduce(0) { $0 + $1.selectionRight }, minimalPositives = minimal.reduce(0) { $0 + $1.positives }
        let minimalAbsence = minimal.reduce(0) { $0 + $1.absenceRight }, minimalNegatives = minimal.reduce(0) { $0 + $1.negatives }
        if minimalSelection < calibration.minimumMinimalPositiveSelection {
            failed.append("K5 positives on minimal archives \(minimalSelection)/\(minimalPositives)")
        }
        if minimalAbsence < calibration.minimumNegativesMinimal { failed.append("K6 negatives \(minimalAbsence)/\(minimalNegatives) (minimal)") }
        return failed
    }

    @Test("second corpus, final: every configuration with its frozen thresholds, full and minimal archives, service and tool",
          .enabled(if: mode == "final2" || mode == "final3", "BRAUS_RECALL_EVAL=final2 or final3 asks for the final measure"))
    func final() async throws {
        let corpus = try RecallCorpus.load(Self.corpusName)
        let url = try #require(Bundle.module.url(forResource: Self.calibrationName, withExtension: "json"),
                               "the frozen calibration is not among the test resources")
        let data = try Data(contentsOf: url)
        let calibration = try JSONDecoder().decode(Calibration.self, from: data)
        try #require(calibration.corpusDigest == corpus.digest, "the calibration was frozen on another corpus")
        let finals = corpus.queries(split: "final")
        let conditions = try await Self.conditions(corpus, queries: finals, bootstrapFrom: finals)
        var report = Report(mode: Self.third ? "final (third corpus, selector 3)" : "final (second corpus)", corpus: corpus.version,
                            corpusDigest: corpus.digest,
                            grid: "frozen thresholds of \(Self.calibrationName).json (sha256 \(RecallCorpus.sha256(data)))",
                            objective: calibration.objective, configurations: [], criteria: calibration.criteria)
        var archives: [String: E.Archive] = [:]
        for configuration in Self.configurations {
            var item = ConfigurationReport(configuration: configuration, name: configuration.name)
            guard let thresholds = calibration.thresholds[configuration.name] else {
                item.skipped = "no frozen thresholds"
                report.configurations.append(item)
                continue
            }
            if configuration.model != nil, E.models == nil {
                item.skipped = "BRAUS_RECALL_MODELS names no folder of the pinned models"
                report.configurations.append(item)
                continue
            }
            let searched = try await Self.search(configuration, conditions: conditions, archives: &archives, frozen: thresholds)
            item.thresholds = thresholds
            item.conditions = Self.report(searched, thresholds: thresholds)
            // The same queries through the product's entry, on the full archive: the delivery must agree with the service.
            if let full = searched.first(where: { $0.condition.name == "full" }) {
                var agreeing = 0
                for query in full.prepared {
                    let tools = ProcedureLearningTests.tools(LearningSession(directory: full.archive.directory), stream: "final2-\(query.query["id"].string ?? "")")
                    let answer = try await tools.call("memory_task", RecallCorpus.begin(query.query)).payload["recall"]
                    let outcomes = full.service.outcomes(query.prepared)
                    let same = answer["coverage"].string == NeedOutcome.overall(outcomes).rawValue
                        && zip(answer["needs"].array ?? [], outcomes).allSatisfy { need, outcome in
                            let steps = need["selection"]["steps"].array?.compactMap { RecallJudge.number($0["step"]) } ?? []
                            return need["coverage"].string == outcome.coverage.rawValue
                                && need["selection"]["version"].string == outcome.selected?.routeID
                                && steps.first == outcome.selected.map { $0.firstPosition + 1 }
                                && steps.last == outcome.selected.map { $0.lastPosition + 1 }
                        }
                    if same { agreeing += 1 } else { Issue.record("\(configuration.name) \(query.query["id"].string ?? ""): the tool delivered \(answer)") }
                }
                if let index = item.conditions.firstIndex(where: { $0.condition == "full" }) {
                    item.conditions[index].toolAgreement = "\(agreeing)/\(full.prepared.count)"
                }
            }
            item.failures = Self.failures(item, calibration)
            let summary = item.conditions.map { "\($0.condition) \($0.phases.score.correct)/\($0.phases.score.queries)" }.joined(separator: ", ")
            print("RECALL-EVAL final\(Self.suffix) \(configuration.name): \(summary); \(item.failures!.isEmpty ? "meets K1–K6" : item.failures!.joined(separator: "; "))")
            report.configurations.append(item)
            try Self.write(report, name: "recall-eval-final\(Self.suffix)")
        }
        for (_, open) in archives { await E.close(open) }
        // The frozen choice: among the configurations meeting K1–K6, fewest unsafe answers (all conditions), then most
        // correct queries, then the simpler channel (lexical, semantic, hybrid), then the smaller lexical weight, then the
        // name. If none meets them, the failure is reported and no configuration is declared validated.
        let order = ["lexical": 0, "semantic": 1, "hybrid": 2]
        func total(_ item: ConfigurationReport) -> RecallJudge.Score { item.conditions.reduce(RecallJudge.Score()) { $0 + $1.phases.score } }
        let chosen = report.configurations.filter { $0.failures?.isEmpty == true }.min { a, b in
            let x = total(a), y = total(b)
            if x.unsafe != y.unsafe { return x.unsafe < y.unsafe }
            if x.correct != y.correct { return x.correct > y.correct }
            let p = order[a.configuration.channel] ?? 3, q = order[b.configuration.channel] ?? 3
            if p != q { return p < q }
            if a.configuration.weight != b.configuration.weight { return a.configuration.weight < b.configuration.weight }
            return a.name < b.name
        }
        report.chosen = chosen?.name ?? "none: no configuration meets the frozen criteria K1–K6"
        try Self.write(report, name: "recall-eval-final\(Self.suffix)")
    }
}
