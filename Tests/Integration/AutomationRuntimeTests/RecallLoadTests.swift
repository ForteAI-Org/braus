//
//  RecallLoadTests.swift
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
import PerceptionCore
@testable import SQLiteMemory
import Synchronization
import Testing

/// RecallLoadTests measure the Recall on a catalogue grown in stages to hundreds of thousands of queryable parts, gated
/// by `BRAUS_RECALL_SCALE=load:N1,N2,…` (procedures at each stage) and written to `BRAUS_RECALL_EVAL_OUT`. The load is
/// generated and learned through the real producers (the tools over the session double: D1's facts, D2's candidates,
/// interpretations, qualification and states), each procedure with its own words so its documents and vectors are its
/// own; it is load data, never quality data. `BRAUS_RECALL_LOAD_CONFIG` names the configuration measured
/// (`lexical:uniform`, `hybrid:granite-107m:uniform:0.2`, …), the product's when absent.
///
/// At each stage: the entities (procedures, versions, parts, offered entries, documents, vectors, part states and
/// evaluations, Brain scenes and relations), the archive's bytes, the learning throughput and the act calls of a task
/// (the whole tool call on the session double, split into its essential writes' wait and transactions), the index's settling, the process's footprint; warm searches through the service by phase and
/// whole queries through `memory_task begin` (search, selection, record, delivery) with p50/p95/p99; a selective search
/// bound to one application among two hundred; searches while another producer learns; the linking of a delivered
/// selection's calls (Brain lookups); the first search after reopening. At the last stage, a whole rebuild while the
/// ready generation answers.
@MainActor
@Suite("Recall under a staged load of hundreds of thousands of parts", .serialized)
struct RecallLoadTests {

    typealias G = RecallScaleTests
    typealias P = ProcedureLearningTests

    nonisolated static var stages: [Int]? {
        guard let value = G.scale, value.hasPrefix("load:") else { return nil }
        return value.dropFirst(5).split(separator: ",").compactMap { Int($0) }
    }

    /// An archive a staged load left, measured again without learning it (`BRAUS_RECALL_SCALE=reuse`).
    nonisolated static var reused: URL? {
        guard G.scale == "reuse", let path = G.environment["BRAUS_RECALL_LOAD_ARCHIVE"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The arms and rounds of the refresh comparison (`BRAUS_RECALL_SCALE=refresh:whole|changed:R[:scan|tracked]`): how the
    /// index in memory follows a moved revision, and how the worker finds documents without a vector.
    nonisolated static var refresh: (incremental: Bool, rounds: Int, tracked: Bool)? {
        guard let value = G.scale, value.hasPrefix("refresh:"), G.environment["BRAUS_RECALL_LOAD_ARCHIVE"] != nil else { return nil }
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count >= 3, ["whole", "changed"].contains(parts[1]), let rounds = Int(parts[2]) else { return nil }
        let tracked = parts.count < 4 || parts[3] == "tracked"
        return (parts[1] == "changed", rounds, tracked)
    }

    /// The rounds of the isolated contention (`BRAUS_RECALL_SCALE=contention:R`): another producer learning with the index
    /// worker held or working, alternated paused, active, active, paused, and so on.
    nonisolated static var contention: Int? {
        guard let value = G.scale, value.hasPrefix("contention:"), G.environment["BRAUS_RECALL_LOAD_ARCHIVE"] != nil else { return nil }
        return Int(value.dropFirst("contention:".count))
    }

    /// The procedures of each arm of the ablation (`BRAUS_RECALL_SCALE=ablation:N`).
    nonisolated static var ablation: Int? {
        guard let value = G.scale, value.hasPrefix("ablation:") else { return nil }
        return Int(value.dropFirst(9))
    }

    /// The lexical channel the product answers with when its model's files are missing: its configuration without a
    /// model. `RecallConfiguration.chosen` itself was lexical until the agent's choice became the product's path.
    static func lexical(owning: Bool) -> RecallConfiguration {
        var configuration = RecallConfiguration.chosen
        configuration.channel = .lexical
        configuration.model = nil
        configuration.ownsIndex = owning
        return configuration
    }

    /// The configuration measured: the product's, or the one `BRAUS_RECALL_LOAD_CONFIG` names.
    static func configuration() -> RecallConfiguration {
        var configuration = RecallConfiguration.chosen
        configuration.modelsDirectory = RecallCycleTests.models
        guard let word = G.environment["BRAUS_RECALL_LOAD_CONFIG"] else { return configuration }
        let parts = word.split(separator: ":").map(String.init)
        configuration.channel = RecallConfiguration.Channel(rawValue: parts[0]) ?? .lexical
        switch configuration.channel {
            case .lexical:
                configuration.model = nil
                configuration.lexicalWeighting = LexicalIndex.Weighting(rawValue: parts.dropFirst().first ?? "") ?? configuration.lexicalWeighting
            default:
                configuration.model = parts.count > 1 ? EmbeddingModelManifest.known[parts[1]] : configuration.model
                if parts.count > 2 { configuration.lexicalWeighting = LexicalIndex.Weighting(rawValue: parts[2]) ?? configuration.lexicalWeighting }
                if parts.count > 3 { configuration.hybridWeight = Double(parts[3]) ?? configuration.hybridWeight }
        }
        return configuration
    }

    /// The words of load procedure `index`: a verb, an object of an account of its own and a qualifier, so its procedure
    /// and three of its four steps have documents no other procedure shares (the step that opens the dialog names the
    /// verb only); its application among two hundred.
    static func words(_ index: Int) -> (verb: String, object: String, qualifier: String, app: String) {
        let (verb, object, qualifier, _) = G.words(index)
        return (verb, "\(object) of account \(index)", qualifier, "com.example.App\(index % 200)")
    }

    static func learn(_ index: Int, directory: URL) async throws -> [Double] {
        let (verb, object, qualifier, app) = Self.words(index)
        let started = ContinuousClock.now
        try await G.learnGenerated(index, verb: verb, object: object, qualifier: qualifier, app: app, directory: directory)
        return [G.milliseconds(started.duration(to: .now))]
    }

    /// ActCall is one `act` tool call of a sampled task on the session double: the whole call as the agent waits for it,
    /// and of that the essential writes it made, each as the caller waited for it and as its transactions took inside the
    /// store: the call's start, committed before the gesture (`call act start`), its end (`call act end`), and the samples
    /// and events between; what waited and inside differ by is the wait for the store (another write holding it) and the
    /// hops between tasks. The rest is the gesture on the double, perception and the tool's own work. It is not a COMMIT
    /// alone.
    struct ActCall {
        let total: Double
        let startWaited: Double
        let startInside: Double
        let endWaited: Double
        let endInside: Double
        let otherWaited: Double
        let otherInside: Double
        /// Each essential write's label with its wait and its time inside the store.
        let writes: [(label: String, waited: Double, inside: Double)]
        var rest: Double { total - startWaited - endWaited - otherWaited }
    }

    /// `count` act calls of one task begun apart, each tagged, with the essential writes the memory's probe reports for it.
    static func actCalls(_ index: Int, directory: URL, memory: MemoryService, count: Int = 5, tag: String = "act") async throws -> [ActCall] {
        let (verb, object, qualifier, app) = Self.words(index)
        let session = LearningSession(directory: directory)
        session.windows[app] = LearningSession.Window(elements: [LearningSession.button("Library", x: 0.1, container: "toolbar"),
                                                               LearningSession.row("Item \(index)", y: 0.3, in: "items")], title: "App")
        let tools = P.tools(session, stream: "act-sample-\(tag)-\(index)")
        let id = session.id!.uuidString
        _ = try await P.task(tools, #"{"operation":"begin","goal":"\#(verb) the \#(object) \#(qualifier)","recall":false}"#)
        _ = try await P.call(tools, "open_session", #"{"app":"\#(app)"}"#)
        let reported = Mutex<[MemoryService.EssentialTiming]>([])
        await memory.probeEssentials { timing in reported.withLock { $0.append(timing) } }
        var calls: [ActCall] = []
        for position in 0..<count {
            let label = "\(tag)-\(index)-\(position)"
            let started = ContinuousClock.now
            _ = try await MemoryService.$probeTag.withValue(label) {
                try await P.call(tools, "act", #"{"session":"\#(id)","target":"Item \#(index)"}"#)
            }
            let total = G.milliseconds(started.duration(to: .now))
            let mine = reported.withLock { $0.filter { $0.tag == label } }
            let start = mine.filter { $0.label.hasSuffix(" start") }, end = mine.filter { $0.label.hasSuffix(" end") }
            let other = mine.filter { !$0.label.hasSuffix(" start") && !$0.label.hasSuffix(" end") }
            func waited(_ timings: [MemoryService.EssentialTiming]) -> Double { timings.map { G.milliseconds($0.total) }.reduce(0, +) }
            func inside(_ timings: [MemoryService.EssentialTiming]) -> Double { timings.map { G.milliseconds($0.inside) }.reduce(0, +) }
            calls.append(ActCall(total: total, startWaited: waited(start), startInside: inside(start), endWaited: waited(end),
                                 endInside: inside(end), otherWaited: waited(other), otherInside: inside(other),
                                 writes: mine.map { ($0.label, G.milliseconds($0.total), G.milliseconds($0.inside)) }))
        }
        await memory.probeEssentials(nil)
        _ = try await P.task(tools, #"{"operation":"end","outcome":"abandoned"}"#)
        return calls
    }

    /// The act calls' measures, each with its distribution, and the essential writes by label.
    static func summary(_ calls: [ActCall]) -> [String: [String: Double]] {
        var report = ["act call ms (whole call on the double)": G.summary(calls.map(\.total)),
                      "start essential write waited ms": G.summary(calls.map(\.startWaited)),
                      "start essential write inside the store ms": G.summary(calls.map(\.startInside)),
                      "end essential write waited ms": G.summary(calls.map(\.endWaited)),
                      "end essential write inside the store ms": G.summary(calls.map(\.endInside)),
                      "samples and events essential writes waited ms": G.summary(calls.map(\.otherWaited)),
                      "samples and events essential writes inside the store ms": G.summary(calls.map(\.otherInside)),
                      "rest of the call ms (gesture, perception, tool, hops)": G.summary(calls.map(\.rest))]
        let labels = Set(calls.flatMap { $0.writes.map(\.label) })
        for label in labels {
            report["essential '\(label)' waited ms"] = G.summary(calls.flatMap { $0.writes.filter { $0.label == label }.map(\.waited) })
            report["essential '\(label)' inside the store ms"] = G.summary(calls.flatMap { $0.writes.filter { $0.label == label }.map(\.inside) })
        }
        return report
    }

    static func count(_ sql: String, _ memory: MemoryService) throws -> Int {
        Int(try rawRows(sql, at: memory.url).first ?? "0") ?? 0
    }

    static func entities(_ memory: MemoryService) throws -> [String: Int] {
        [
            "procedure versions": try count("SELECT count(*) FROM memory_procedure_versions", memory),
            "parts": try count("SELECT count(*) FROM memory_procedure_parts", memory),
            "steps": try count("SELECT count(*) FROM memory_procedure_parts WHERE part_kind = 'step'", memory),
            "offered entries (ready generation)": try count(
                "SELECT count(*) FROM memory_recall_entries e JOIN memory_recall_generations g ON g.generation_id = e.generation_id WHERE g.status = 'ready'",
                memory),
            "distinct documents": try count("SELECT count(*) FROM memory_recall_documents", memory),
            "vectors": try count("SELECT count(*) FROM memory_recall_vectors", memory),
            "part evaluations": try count("SELECT count(*) FROM memory_part_qualifications", memory),
            "part states": try count("SELECT count(*) FROM memory_part_states", memory),
            "Brain scenes": try count("SELECT count(*) FROM brain_scenes", memory),
            "Brain relations": try count("SELECT count(*) FROM brain_relations", memory),
            "events": try count("SELECT count(*) FROM memory_events", memory),
            "recall queries": try count("SELECT count(*) FROM memory_recall_queries", memory),
        ]
    }

    static func bytes(_ memory: MemoryService) -> [String: Int] {
        func size(_ suffix: String) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: memory.url.path + suffix))?[.size] as? NSNumber)?.intValue ?? 0
        }
        return ["archive": size(""), "wal": size("-wal")]
    }

    static func queries(_ count: Int, among learned: Int) -> [(text: String, app: String)] {
        (0..<count).map { position in
            let index = (position * 7919 + 13) % learned
            let (verb, object, qualifier, app) = Self.words(index)
            return ("\(verb) the \(object) \(qualifier) with a new name", app)
        }
    }

    /// When each search of the last `searches` began, since `timelineOrigin`, for a measure that correlates them.
    static var timeline: [Double] = []
    static var timelineOrigin = ContinuousClock.now

    /// Warm searches through the service, by phase, and with a need bound to one application.
    static func searches(_ service: RecallService, queries: [(text: String, app: String)], bound: Bool) async throws -> [String: [Double]] {
        timeline = []
        var phases: [String: [Double]] = ["index": [], "embedding": [], "scoring": [], "reading": [], "selection": [], "total": []]
        var found = 0
        for query in queries {
            let need = try RecallNeed(text: query.text, bundleID: bound ? query.app : nil)
            let request = try RecallRequest(taskID: "t", attemptID: "a", revision: 1, reason: .initial, remainingWork: query.text, needs: [need],
                                            values: [try TaskValue(name: "output_name", kind: .text, content: .text("x_1"), source: .request)])
            let started = ContinuousClock.now
            timeline.append(G.milliseconds(timelineOrigin.duration(to: started)) / 1000)
            let prepared = try await service.prepare(request)
            let selecting = ContinuousClock.now
            let outcome = service.outcomes(prepared).first
            phases["selection"]!.append(G.milliseconds(selecting.duration(to: .now)))
            phases["index"]!.append(G.milliseconds(prepared.phases.index))
            phases["embedding"]!.append(G.milliseconds(prepared.phases.embedding))
            phases["scoring"]!.append(G.milliseconds(prepared.phases.scoring))
            phases["reading"]!.append(G.milliseconds(prepared.phases.reading))
            phases["total"]!.append(G.milliseconds(started.duration(to: .now)))
            if let route = outcome?.selected?.routeID, prepared.sources.first(where: { $0.routeID == route })?.steps.first?.bundleID == query.app {
                found += 1
            }
        }
        phases["selected in the query's application"] = [Double(found)]
        return phases
    }

    /// Whole queries through `memory_task begin`: the task's revision, the search, the shortlist, the proposal's record and
    /// its text (the product's one path, the agent's choice), as an agent waits for them.
    static func toolQueries(_ directory: URL, queries: [(text: String, app: String)], stage: Int) async throws -> [Double] {
        var durations: [Double] = []
        for (position, query) in queries.enumerated() {
            let tools = P.tools(LearningSession(directory: directory), stream: "load-query-\(stage)-\(position)")
            let started = ContinuousClock.now
            let answer = try await P.task(tools, #"""
                {"operation":"begin","goal":"\#(query.text)","inputs":[{"name":"output_name","value":"x_1"}]}
                """#)
            durations.append(G.milliseconds(started.duration(to: .now)))
            #expect(answer["recall_proposal"] != .null, "\(answer)")
        }
        return durations
    }

    /// The measures of an archive of `learned` load procedures, its index settled: entities, bytes, warm searches by
    /// phase (unbound, bound to one application, by a lexical guest), whole queries through the tool, the Brain lookups
    /// the Recall makes, searches while 50 more procedures are learned and the index catching up, then the archive
    /// closed and opened again with its first search. Answers the measures, the memory and service reopened, and the
    /// procedures learned.
    static func measure(_ memory: MemoryService, _ service: RecallService, configuration: RecallConfiguration, directory: URL,
                        learned: Int, stage: Int) async throws -> ([String: Any], MemoryService, RecallService, Int) {
        var memory = memory, service = service, learned = learned
        var stage: [String: Any] = ["procedures": learned, "stage": stage]
        stage["entities"] = try Self.entities(memory)
        stage["bytes"] = Self.bytes(memory)
        stage["footprint MB"] = G.footprintMB()
        let queries = Self.queries(100, among: learned)
        _ = try await Self.searches(service, queries: Array(queries.prefix(5)), bound: false)
        stage["warm search ms"] = try await Self.searches(service, queries: queries, bound: false).mapValues { G.summary($0) }
        stage["warm search bound to one application ms"] = try await Self.searches(service, queries: queries, bound: true).mapValues { G.summary($0) }
        if configuration.channel != .lexical {
            let guest = RecallService(memory: memory, configuration: Self.lexical(owning: false))
            _ = try await Self.searches(guest, queries: Array(queries.prefix(5)), bound: false)
            stage["warm search, lexical guest ms"] = try await Self.searches(guest, queries: queries, bound: false).mapValues { G.summary($0) }
        }
        stage["memory_task begin with search ms"] = G.summary(try await Self.toolQueries(directory, queries: Array(queries.prefix(40)),
                                                                                         stage: learned))
        let attempt = try rawRows("SELECT task_occurrence_id FROM memory_task_events WHERE role = 'action' ORDER BY rowid DESC LIMIT 1 OFFSET 10",
                                  at: memory.url).first ?? ""
        var linking: [Double] = [], observing: [Double] = []
        for _ in 0..<20 {
            var started = ContinuousClock.now
            let calls = try await memory.perform { try await $0.recall.calls(ofAttempt: attempt, after: 0) }
            linking.append(G.milliseconds(started.duration(to: .now)))
            #expect(!calls.isEmpty, "the learned attempt's calls")
            started = ContinuousClock.now
            _ = try await memory.perform { try await $0.recall.observedState(of: .app, stream: "load-0", since: 0) }
            observing.append(G.milliseconds(started.duration(to: .now)))
        }
        stage["calls of an attempt with states and elements ms"] = G.summary(linking)
        stage["latest observed state of a stream ms"] = G.summary(observing)
        let concurrentStart = learned
        let writer = Task { @MainActor in
            for index in concurrentStart..<(concurrentStart + 50) { _ = try await Self.learn(index, directory: directory) }
        }
        let during = try await Self.searches(service, queries: Array(queries.prefix(50)), bound: false)
        try await writer.value
        learned += 50
        stage["warm search during learning ms"] = during.mapValues { G.summary($0) }
        let catchUp = ContinuousClock.now
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(600)))
        stage["index catch-up after 50 concurrent procedures s"] = G.milliseconds(catchUp.duration(to: .now)) / 1000
        stage["pending work after catch-up"] = try await memory.perform { try await $0.recall.status() }.pendingWork
        await memory.close()
        RecallService.forget(memory)
        MemoryService.forget(directory)
        let opening = ContinuousClock.now
        memory = MemoryService.shared(for: directory)
        service = RecallService(memory: memory, configuration: configuration)
        RecallService.install(service)
        _ = try await memory.perform { try await $0.recall.status() }
        stage["reopen ms"] = G.milliseconds(opening.duration(to: .now))
        let cold = ContinuousClock.now
        _ = try await Self.searches(service, queries: [queries[0]], bound: false)
        stage["first search after reopening ms"] = G.milliseconds(cold.duration(to: .now))
        stage["footprint after first search MB"] = G.footprintMB()
        return (stage, memory, service, learned)
    }

    /// A whole rebuild, the ready generation answering searches while the new one is built.
    static func rebuild(_ memory: MemoryService, _ service: RecallService, learned: Int) async throws -> [String: Any] {
        var report: [String: Any] = [:]
        let at = memory.clock.calendarMS()
        try await memory.perform { try await $0.recall.queueRebuild(at: at) }
        let started = ContinuousClock.now
        await service.schedule()
        let during = try await Self.searches(service, queries: Self.queries(30, among: learned), bound: false)
        #expect(await service.waitUntilIdle(within: .seconds(14_400)))
        report["rebuild s"] = G.milliseconds(started.duration(to: .now)) / 1000
        report["warm search during rebuild ms"] = during.mapValues { G.summary($0) }
        report["generations after rebuild"] = try rawRows("SELECT status || ':' || count(*) FROM memory_recall_generations GROUP BY status", at: memory.url)
        report["bytes after rebuild"] = Self.bytes(memory)
        return report
    }

    @Test("an archive a staged load left, measured again without learning it: searches, filters, concurrency, reopening, rebuild",
          .enabled(if: reused != nil, "BRAUS_RECALL_SCALE=reuse and BRAUS_RECALL_LOAD_ARCHIVE ask for it"))
    func reuse() async throws {
        let directory = try #require(Self.reused)
        let memory = MemoryService.shared(for: directory)
        let configuration = Self.configuration()
        let service = RecallService(memory: memory, configuration: configuration)
        RecallService.install(service)
        let settle = ContinuousClock.now
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(14_400)))
        let learned = try Self.count("SELECT count(*) FROM memory_procedure_versions", memory)
        var report: [String: Any] = ["hardware": G.hardware(), "archive": directory.path, "configuration": "\(configuration.channel.rawValue) "
                                     + "\(configuration.model?.modelID ?? "-") \(configuration.lexicalWeighting.rawValue) w=\(configuration.hybridWeight)",
                                     "index settle s": G.milliseconds(settle.duration(to: .now)) / 1000]
        let (stage, reopened, fresh, total) = try await Self.measure(memory, service, configuration: configuration, directory: directory,
                                                                      learned: learned, stage: learned)
        report["measures"] = stage
        report["rebuild"] = try await Self.rebuild(reopened, fresh, learned: total)
        print("RECALL-LOAD reuse: \(report)")
        try G.write(report, name: "recall-load-reuse")
        await reopened.close()
        RecallService.forget(reopened)
        MemoryService.forget(directory)
    }

    /// A copy of the archive a staged load left, in a directory of its own: a clone of the file on APFS, the original never
    /// opened by the measure.
    static func copy(of archive: URL) throws -> URL {
        let directory = try W.directory()
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["memory.sqlite", "memory.sqlite-wal"] {
            let file = archive.appendingPathComponent(name)
            guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 0 else { continue }
            try FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(name))
        }
        return directory
    }

    @Test("the index worker's contention apart from another producer's, on a copy of the staged load: act calls while a producer learns, the worker held or working, in alternated rounds",
          .enabled(if: contention != nil, "BRAUS_RECALL_SCALE=contention:R and BRAUS_RECALL_LOAD_ARCHIVE ask for it"))
    func isolatedContention() async throws {
        let rounds = try #require(Self.contention)
        let original = URL(fileURLWithPath: try #require(G.environment["BRAUS_RECALL_LOAD_ARCHIVE"]), isDirectory: true)
        let directory = try Self.copy(of: original)
        // Named at once, so the runner removes this run's copy even when the run stops before its report.
        print("RECALL-LOAD contention copy: \(directory.path)")
        let memory = MemoryService.shared(for: directory)
        let configuration = Self.configuration()
        let service = RecallService(memory: memory, configuration: configuration)
        RecallService.install(service)
        let opened = ContinuousClock.now
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(3600)))
        var learned = try Self.count("SELECT count(*) FROM memory_procedure_versions", memory)
        var report: [String: Any] = ["hardware": G.hardware(), "rounds": rounds, "original archive": original.path, "copy": directory.path,
                                     "open, migration and index settle s": G.milliseconds(opened.duration(to: .now)) / 1000,
                                     "configuration": "\(configuration.channel.rawValue) \(configuration.model?.modelID ?? "-") w=\(configuration.hybridWeight)",
                                     "entities before": try Self.entities(memory)]
        report["act calls, nothing else running"] = Self.summary(try await Self.actCalls(4_000_000, directory: directory, memory: memory,
                                                                                         count: 30, tag: "idle"))
        let operations = Mutex<[(arm: String, label: String, ms: Double)]>([])
        let arm = Mutex<String>("idle")
        try await memory.observeSlowStoreOperations(threshold: .milliseconds(1)) { operation in
            let current = arm.withLock { $0 }
            operations.withLock { $0.append((current, operation.label ?? "-", G.milliseconds(operation.duration))) }
        }
        var calls: [String: [ActCall]] = [:], learning: [String: [Double]] = [:], order: [String] = []
        for round in 0..<rounds {
            let held = [0, 3].contains(round % 4)
            let name = held ? "paused" : "active"
            order.append(name)
            await service.holdWork(held)
            arm.withLock { $0 = name }
            let start = learned
            let writer = Task { @MainActor in
                var times: [Double] = []
                for index in start..<(start + 30) { times += try await Self.learn(index, directory: directory) }
                return times
            }
            let sampler = Task { @MainActor in
                try await Self.actCalls(4_100_000 + round, directory: directory, memory: memory, count: 10, tag: name)
            }
            learning[name, default: []] += try await writer.value
            calls[name, default: []] += try await sampler.value
            learned += 30
            arm.withLock { $0 = "drain" }
            await service.holdWork(false)
            await service.schedule()
            #expect(await service.waitUntilIdle(within: .seconds(900)))
        }
        try await memory.observeSlowStoreOperations(threshold: .milliseconds(1), nil)
        report["order"] = order
        for name in ["paused", "active"] {
            report["act calls, producer learning, index \(name)"] = Self.summary(calls[name] ?? [])
            report["learning ms per procedure, index \(name)"] = G.summary(learning[name] ?? [])
            let mine = operations.withLock { $0.filter { $0.arm == name } }
            var byLabel: [String: [Double]] = [:]
            for operation in mine { byLabel[operation.label, default: []].append(operation.ms) }
            report["store operations of at least 1 ms inside the store, index \(name), by label"] = byLabel.mapValues { values -> [String: Double] in
                var summary = G.summary(values)
                summary["total"] = values.reduce(0, +)
                return summary
            }
            let queue = (calls[name] ?? []).map { ($0.startWaited - $0.startInside) + ($0.endWaited - $0.endInside) }
            report["essential writes' queue (waited minus inside) ms, index \(name)"] = G.summary(queue)
        }
        report["entities after"] = try Self.entities(memory)
        print("RECALL-LOAD contention: \(report)")
        try G.write(report, name: "recall-load-contention")
        await memory.close()
        RecallService.forget(memory)
        MemoryService.forget(directory)
    }

    @Test("keeping the index in memory current, by its whole or by what changed, on a copy of the staged load: searches while another producer learns, the refreshes, and act calls while the index works and while it is idle",
          .enabled(if: refresh != nil, "BRAUS_RECALL_SCALE=refresh:whole|changed:R and BRAUS_RECALL_LOAD_ARCHIVE ask for it"))
    func refreshComparison() async throws {
        let (incremental, rounds, tracked) = try #require(Self.refresh)
        let original = URL(fileURLWithPath: try #require(G.environment["BRAUS_RECALL_LOAD_ARCHIVE"]), isDirectory: true)
        let directory = try Self.copy(of: original)
        let memory = MemoryService.shared(for: directory)
        let configuration = Self.configuration()
        let service = RecallService(memory: memory, configuration: configuration)
        RecallService.install(service)
        await service.refreshIncrementally(incremental)
        await service.trackVectorWork(tracked)
        let origin = ContinuousClock.now
        Self.timelineOrigin = origin
        var searchTimeline: [[String: Double]] = []
        let slow = Mutex<[SQLiteMemoryStore.SlowOperation]>([])
        try await memory.observeSlowStoreOperations(threshold: .milliseconds(300)) { operation in slow.withLock { $0.append(operation) } }
        let settle = ContinuousClock.now
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(3600)))
        var learned = try Self.count("SELECT count(*) FROM memory_procedure_versions", memory)
        var report: [String: Any] = ["hardware": G.hardware(), "arm": incremental ? "changed" : "whole", "vector arm": tracked ? "tracked" : "scan",
                                     "rounds": rounds,
                                     "original archive": original.path, "copy": directory.path,
                                     "configuration": "\(configuration.channel.rawValue) \(configuration.model?.modelID ?? "-") "
                                         + "\(configuration.lexicalWeighting.rawValue) w=\(configuration.hybridWeight)",
                                     "index settle s": G.milliseconds(settle.duration(to: .now)) / 1000, "procedures": learned,
                                     "entries": try Self.count("SELECT count(*) FROM memory_recall_entries e JOIN memory_recall_generations g "
                                                               + "ON g.generation_id = e.generation_id AND g.status = 'ready'", memory)]
        let queries = Self.queries(30, among: learned)
        _ = try await Self.searches(service, queries: Array(queries.prefix(5)), bound: false)
        report["act calls, index idle"] = Self.summary(try await Self.actCalls(3_000_000, directory: directory, memory: memory, count: 30, tag: "idle"))
        var during: [String: [Double]] = [:], busy: [ActCall] = [], perRound: [[String: Double]] = [], catchUp: [Double] = []
        let before = await service.refreshCounts()
        for round in 0..<rounds {
            let start = learned
            let writer = Task { @MainActor in
                for index in start..<(start + 30) { _ = try await Self.learn(index, directory: directory) }
            }
            let sampler = Task { @MainActor in
                try await Self.actCalls(3_100_000 + round, directory: directory, memory: memory, count: 10, tag: "busy")
            }
            let searched = try await Self.searches(service, queries: queries, bound: false)
            try await writer.value
            busy += try await sampler.value
            learned += 30
            for (phase, values) in searched where phase != "selected in the query's application" { during[phase, default: []] += values }
            for (position, at) in Self.timeline.enumerated() {
                var point = ["at s": at]
                for (phase, values) in searched where values.indices.contains(position) && phase != "selected in the query's application" {
                    point[phase] = values[position]
                }
                searchTimeline.append(point)
            }
            perRound.append(G.summary(searched["total"] ?? []))
            let caught = ContinuousClock.now
            await service.schedule()
            #expect(await service.waitUntilIdle(within: .seconds(600)))
            catchUp.append(G.milliseconds(caught.duration(to: .now)) / 1000)
        }
        let after = await service.refreshCounts()
        report["search ms while another producer learns, all rounds, by phase"] = during.mapValues { G.summary($0) }
        if let slowest = during["total"]?.indices.max(by: { during["total"]![$0] < during["total"]![$1] }) {
            report["slowest search's phases ms"] = during.mapValues { $0.indices.contains(slowest) ? $0[slowest] : -1 }
        }
        report["search ms while another producer learns, by round"] = perRound
        report["act calls, index working"] = Self.summary(busy)
        report["index catch-up s by round"] = catchUp
        report["refreshes"] = [
            "whole reads": after.whole.count - before.whole.count, "whole read ms": G.summary(Array(after.whole.dropFirst(before.whole.count))),
            "reads of changed versions": after.changed.count - before.changed.count,
            "read of changed versions ms": G.summary(Array(after.changed.dropFirst(before.changed.count))),
            "versions per changed read": G.summary(Array(after.changedVersions.dropFirst(before.changedVersions.count)).map(Double.init)),
            "vector reads": after.vectors.count - before.vectors.count,
            "vector read ms": G.summary(Array(after.vectors.dropFirst(before.vectors.count))),
        ] as [String: Any]
        report["footprint MB"] = G.footprintMB()
        report["searches while another producer learns, in order"] = searchTimeline
        report["slow store operations (at least 300 ms inside the store)"] = slow.withLock { $0 }.map { operation -> [String: Any] in
            ["at s": G.milliseconds(origin.duration(to: operation.endedAt)) / 1000, "kind": operation.kind, "label": operation.label ?? "-",
             "ms": G.milliseconds(operation.duration)]
        }
        try await memory.observeSlowStoreOperations(threshold: .milliseconds(300), nil)
        print("RECALL-LOAD refresh: \(report)")
        try G.write(report, name: "recall-load-refresh-\(incremental ? "changed" : "whole")-\(tracked ? "tracked" : "scan")")
        await memory.close()
        RecallService.forget(memory)
        MemoryService.forget(directory)
    }

    @Test("the index's cost on learning: the same procedures learned with no index, with the lexical owner and with the semantic owner",
          .enabled(if: ablation != nil, "BRAUS_RECALL_SCALE=ablation:N asks for it"))
    func indexAblation() async throws {
        let count = try #require(Self.ablation)
        var report: [String: Any] = ["hardware": G.hardware(), "procedures per arm": count]
        for arm in ["no index", "lexical owner", "hybrid granite owner"] {
            let directory = try W.directory()
            let memory = MemoryService.shared(for: directory)
            var configuration = arm == "hybrid granite owner" ? Self.configuration() : Self.lexical(owning: true)
            if arm == "hybrid granite owner" {
                configuration.channel = .hybrid
                configuration.model = .graniteEmbedding107MMultilingual
                configuration.modelsDirectory = RecallCycleTests.models
            }
            // No index: a guest of an archive no owner indexes keeps nothing, so the writes carry no index work.
            configuration.ownsIndex = arm != "no index"
            RecallService.install(RecallService(memory: memory, configuration: configuration))
            var learning: [Double] = [], commits: [ActCall] = [], brain: [Double] = []
            for index in 0..<count {
                learning += try await Self.learn(index, directory: directory)
                if index % 500 == 499 {
                    commits += try await Self.actCalls(2_000_000 + index, directory: directory, memory: memory)
                    let started = ContinuousClock.now
                    _ = try await memory.perform { try await $0.recall.calls(ofAttempt: try rawRows(
                        "SELECT task_occurrence_id FROM memory_task_events WHERE role = 'action' ORDER BY rowid DESC LIMIT 1 OFFSET 10",
                        at: memory.url).first ?? "", after: 0) }
                    brain.append(G.milliseconds(started.duration(to: .now)))
                }
            }
            _ = await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(3600))
            report[arm] = ["learning ms per procedure": G.summary(learning), "act calls": Self.summary(commits),
                           "calls of an attempt with states and elements ms": G.summary(brain),
                           "entries": try Self.count("SELECT count(*) FROM memory_recall_entries", memory), "bytes": Self.bytes(memory)]
            print("RECALL-LOAD ablation \(arm): \(report[arm]!)")
            try G.write(report, name: "recall-load-ablation")
            await memory.close()
            RecallService.forget(memory)
            MemoryService.forget(directory)
        }
    }

    @Test("a staged load learned through the producers: entities, bytes, learning, index, searches, filters, concurrency, reopening, rebuild",
          .enabled(if: stages != nil, "BRAUS_RECALL_SCALE=load:N1,N2,… asks for it"))
    func load() async throws {
        let stages = try #require(Self.stages)
        let directory = try W.directory()
        var memory = MemoryService.shared(for: directory)
        let configuration = Self.configuration()
        var service = RecallService(memory: memory, configuration: configuration)
        RecallService.install(service)
        var report: [String: Any] = ["hardware": G.hardware(), "configuration": "\(configuration.channel.rawValue) "
                                     + "\(configuration.model?.modelID ?? "-") \(configuration.lexicalWeighting.rawValue) w=\(configuration.hybridWeight)",
                                     "stages": stages, "applications": 200, "steps per procedure": 4]
        var stageReports: [[String: Any]] = []
        var learned = 0
        for (number, target) in stages.enumerated() {
            var stage: [String: Any] = ["procedures": target]
            let learning = ContinuousClock.now
            var learningDurations: [Double] = []
            while learned < target {
                learningDurations += try await Self.learn(learned, directory: directory)
                learned += 1
                if learned % 1000 == 0 { print("RECALL-LOAD learned \(learned) footprint \(Int(G.footprintMB())) MB") }
            }
            stage["learning s"] = G.milliseconds(learning.duration(to: .now)) / 1000
            stage["learning ms per procedure"] = G.summary(learningDurations)
            stage["act calls"] = Self.summary(try await Self.actCalls(target + 1_000_000, directory: directory, memory: memory))
            let settle = ContinuousClock.now
            await service.schedule()
            #expect(await service.waitUntilIdle(within: .seconds(14_400)))
            stage["index settle s"] = G.milliseconds(settle.duration(to: .now)) / 1000
            stage["entities"] = try Self.entities(memory)
            stage["bytes"] = Self.bytes(memory)
            stage["footprint MB"] = G.footprintMB()
            let queries = Self.queries(100, among: learned)
            _ = try await Self.searches(service, queries: Array(queries.prefix(5)), bound: false)
            stage["warm search ms"] = try await Self.searches(service, queries: queries, bound: false).mapValues { G.summary($0) }
            stage["warm search bound to one application ms"] = try await Self.searches(service, queries: queries, bound: true).mapValues { G.summary($0) }
            if configuration.channel != .lexical {
                // The product's lexical channel over the same generation, as a guest of its index.
                let guest = RecallService(memory: memory, configuration: Self.lexical(owning: false))
                _ = try await Self.searches(guest, queries: Array(queries.prefix(5)), bound: false)
                stage["warm search, lexical guest ms"] = try await Self.searches(guest, queries: queries, bound: false).mapValues { G.summary($0) }
            }
            stage["memory_task begin with search ms"] = G.summary(try await Self.toolQueries(directory, queries: Array(queries.prefix(40)), stage: number))

            // Brain lookups the Recall makes: the calls of a learned attempt with their states and the elements the Brain
            // identified (what linking reads), and the latest state a producer's stream showed.
            let attempt = try rawRows("SELECT task_occurrence_id FROM memory_task_events WHERE role = 'action' ORDER BY rowid DESC LIMIT 1 OFFSET 10",
                                      at: memory.url).first ?? ""
            var linking: [Double] = [], observing: [Double] = []
            for _ in 0..<20 {
                var started = ContinuousClock.now
                let calls = try await memory.perform { try await $0.recall.calls(ofAttempt: attempt, after: 0) }
                linking.append(G.milliseconds(started.duration(to: .now)))
                #expect(!calls.isEmpty, "the learned attempt's calls")
                started = ContinuousClock.now
                _ = try await memory.perform { try await $0.recall.observedState(of: .app, stream: "load-0", since: 0) }
                observing.append(G.milliseconds(started.duration(to: .now)))
            }
            stage["calls of an attempt with states and elements ms"] = G.summary(linking)
            stage["latest observed state of a stream ms"] = G.summary(observing)

            // Searches while another producer learns: the writes and the index work go on, the searches answer.
            let concurrentStart = learned
            let writer = Task { @MainActor in
                for index in concurrentStart..<(concurrentStart + 50) {
                    _ = try await Self.learn(index, directory: directory)
                }
            }
            let during = try await Self.searches(service, queries: Array(queries.prefix(50)), bound: false)
            try await writer.value
            learned += 50
            stage["warm search during learning ms"] = during.mapValues { G.summary($0) }
            let catchUp = ContinuousClock.now
            await service.schedule()
            #expect(await service.waitUntilIdle(within: .seconds(600)))
            stage["index catch-up after 50 concurrent procedures s"] = G.milliseconds(catchUp.duration(to: .now)) / 1000
            stage["pending work after catch-up"] = try await memory.perform { try await $0.recall.status() }.pendingWork

            // The first search after reopening: the index read into memory, the model loaded.
            await memory.close()
            RecallService.forget(memory)
            MemoryService.forget(directory)
            let opening = ContinuousClock.now
            memory = MemoryService.shared(for: directory)
            service = RecallService(memory: memory, configuration: configuration)
            RecallService.install(service)
            _ = try await memory.perform { try await $0.recall.status() }
            stage["reopen ms"] = G.milliseconds(opening.duration(to: .now))
            let cold = ContinuousClock.now
            _ = try await Self.searches(service, queries: [queries[0]], bound: false)
            stage["first search after reopening ms"] = G.milliseconds(cold.duration(to: .now))
            stage["footprint after first search MB"] = G.footprintMB()
            stageReports.append(stage)
            report["stage reports"] = stageReports
            print("RECALL-LOAD stage \(target): \(stage)")
            try G.write(report, name: "recall-load")
        }

        // A whole rebuild at the last stage, the ready generation answering while the new one is built.
        let at = memory.clock.calendarMS()
        try await memory.perform { try await $0.recall.queueRebuild(at: at) }
        let rebuild = ContinuousClock.now
        await service.schedule()
        let queries = Self.queries(30, among: learned)
        let during = try await Self.searches(service, queries: queries, bound: false)
        #expect(await service.waitUntilIdle(within: .seconds(14_400)))
        report["rebuild s"] = G.milliseconds(rebuild.duration(to: .now)) / 1000
        report["warm search during rebuild ms"] = during.mapValues { G.summary($0) }
        report["generations after rebuild"] = try rawRows("SELECT status || ':' || count(*) FROM memory_recall_generations GROUP BY status", at: memory.url)
        report["bytes after rebuild"] = Self.bytes(memory)
        try G.write(report, name: "recall-load")
        await memory.close()
        RecallService.forget(memory)
        MemoryService.forget(directory)
    }
}
