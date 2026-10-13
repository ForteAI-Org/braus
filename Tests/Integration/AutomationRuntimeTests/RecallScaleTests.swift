//
//  RecallScaleTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import Accelerate
import AutomationMCP
@testable import AutomationRuntime
import Darwin
import EngineCore
import Foundation
import LocalEmbedding
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// RecallScaleTests measure the Recall's cost with sizes stated, gated by `MECUM_RECALL_SCALE` and written to
/// `MECUM_RECALL_EVAL_OUT`. They are measures, not proofs of quality: the procedures are load data, generated and
/// learned through the tools (D2's producers, qualification and index work), never the quality corpus.
///
/// - `MECUM_RECALL_SCALE=catalogue:N` learns N generated procedures of four steps over forty applications, builds
///   the lexical index and, with `MECUM_RECALL_MODELS`, the E5 one, and measures: the learning and the index build,
///   the archive's size, the first search after opening (cold: the index read into memory) and repeated searches
///   (warm) by phase, and the process's resident memory. With `MECUM_RECALL_EXPORT=1` it writes the E5 vectors and
///   the queries' vectors for the comparison of an approximate index with the exact search (usearch, in the
///   evaluation environment only).
/// - `MECUM_RECALL_SCALE=kernel` measures the exact scoring alone over 10 000 to 1 000 000 random normalized vectors of
///   384 dimensions: the per-entry dot products the service runs, and one matrix-vector product over the same
///   vectors stored contiguously, with the memory each needs.
@MainActor
@Suite("Recall cost at stated sizes", .serialized)
struct RecallScaleTests {

    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static var scale: String? { environment["MECUM_RECALL_SCALE"] }

    nonisolated static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The process's physical footprint, as the system counts it against the app, in mebibytes.
    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    nonisolated static func summary(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func at(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))] }
        let mean = sorted.reduce(0, +) / Double(max(1, sorted.count))
        let deviation = (sorted.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, sorted.count))).squareRoot()
        return ["n": Double(sorted.count), "p50": at(0.5), "p95": at(0.95), "p99": at(0.99), "max": sorted.last ?? 0, "mean": mean,
                "sd": deviation]
    }

    static func write(_ object: [String: Any], name: String) throws {
        guard let path = environment["MECUM_RECALL_EVAL_OUT"] else { return }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("\(name).json"))
    }

    // MARK: Generated catalogue

    static let verbs = ["Export", "Archive", "Rename", "Duplicate", "Share", "Print", "Sort", "Filter", "Compress", "Publish",
                        "Translate", "Sign", "Merge", "Split", "Rotate", "Resize", "Encrypt", "Upload", "Tag", "Convert"]
    static let objects = ["invoice", "photo", "report", "contract", "slide deck", "spreadsheet", "note", "recording", "folder",
                          "message", "playlist", "calendar event", "receipt", "drawing", "chart", "ticket", "order", "label",
                          "template", "backup"]
    static let qualifiers = ["as PDF", "by date", "for the team", "with a password", "to the archive", "in black and white",
                             "with comments", "for printing", "as a copy", "in Italian", "by customer", "to the shared drive"]

    /// The words of generated procedure `index`: a verb, an object, a qualifier, an application among forty.
    static func words(_ index: Int) -> (verb: String, object: String, qualifier: String, app: String) {
        (verbs[index % verbs.count], objects[(index / verbs.count) % objects.count],
         qualifiers[(index / (verbs.count * objects.count)) % qualifiers.count], "com.example.App\(index % 40)")
    }

    /// Learns generated procedure `index` through the tools: a button, a menu command opening a dialog, a name typed
    /// in it, its confirmation; interpreted with labels and one parameter.
    static func learnGenerated(_ index: Int, directory: URL) async throws {
        let (verb, object, qualifier, app) = words(index)
        try await learnGenerated(index, verb: verb, object: object, qualifier: qualifier, app: app, directory: directory)
    }

    /// Learns one generated procedure of the words given, in `app`.
    static func learnGenerated(_ index: Int, verb: String, object: String, qualifier: String, app: String, directory: URL) async throws {
        let session = LearningSession(directory: directory)
        let main = LearningSession.Window(elements: [
            LearningSession.button("Library", x: 0.1, container: "toolbar"), LearningSession.button("Details", x: 0.2, container: "toolbar"),
            LearningSession.row("Item \(index)", y: 0.3, in: "items"),
        ], title: "App \(index % 40)")
        let dialog = LearningSession.Window(elements: [
            LearningSession.field("Untitled", x: 0.3), LearningSession.popup("Options", value: "Default"),
            LearningSession.button("OK", x: 0.8), LearningSession.button("Cancel", x: 0.7),
        ], surface: .dialog, title: "\(verb) \(object)")
        session.windows[app] = main
        session.script["menu|File > \(verb)…"] = LearningSession.Outcome(next: dialog)
        session.script["press|OK"] = LearningSession.Outcome(next: main)
        let tools = ProcedureLearningTests.tools(session, stream: "load-\(index % 8)")
        let id = session.id!.uuidString
        let begun = try await ProcedureLearningTests.task(tools, #"""
            {"operation":"begin","goal":"\#(verb) the \#(object) \#(qualifier)","recall":false,
             "inputs":[{"name":"output_name","value":"item_\#(index)"}]}
            """#)
        guard begun["status"].string == "begun" else { throw RecallCorpus.Failure("begin \(index): \(begun)") }
        _ = try await ProcedureLearningTests.call(tools, "open_session", #"{"app":"\#(app)"}"#)
        _ = try await ProcedureLearningTests.call(tools, "act", #"{"session":"\#(id)","target":"Item \#(index)"}"#)
        _ = try await ProcedureLearningTests.call(tools, "menu", #"{"session":"\#(id)","path":"File > \#(verb)…"}"#)
        _ = try await ProcedureLearningTests.call(tools, "type_text", #"{"session":"\#(id)","target":"Untitled","text":"item_\#(index)"}"#)
        _ = try await ProcedureLearningTests.call(tools, "press", #"{"session":"\#(id)","button":"OK"}"#)
        let ended = try await ProcedureLearningTests.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        guard let candidate = ended["candidate"]["id"].string else { throw RecallCorpus.Failure("end \(index): \(ended)") }
        let interpreted = try await ProcedureLearningTests.task(tools, #"""
            {"operation":"interpret","candidate":"\#(candidate)",
             "procedure":{"label":"\#(verb) the \#(object) \#(qualifier) as <output_name>"},
             "steps":[{"step":1,"label":"Select the \#(object) in the list"},{"step":2,"label":"Open the \#(verb) dialog"},
                      {"step":3,"label":"Type <output_name> as the new \#(object)'s name"},{"step":4,"label":"Confirm: \#(verb.lowercased()) the \#(object) \#(qualifier)"}],
             "parameters":[{"name":"output_name","role":"name of the \#(object) produced","kind":"text"}],
             "uses":[{"step":3,"argument":"text","template":"{output_name}"}]}
            """#)
        guard interpreted["status"].string == "interpreted" else { throw RecallCorpus.Failure("interpret \(index): \(interpreted)") }
    }

    static func queries(_ count: Int) -> [String] {
        (0..<count).map { index in
            let (verb, object, qualifier, _) = words(index * 37 + 11)
            return "\(verb) the \(object) \(qualifier) with a new name"
        }
    }

    /// Searches every query `repetitions` times and returns each search's phases, in milliseconds.
    static func measure(_ service: RecallService, queries: [String], repetitions: Int) async throws -> [String: [Double]] {
        var phases: [String: [Double]] = ["embedding": [], "scoring": [], "reading": [], "selection": [], "total": []]
        for _ in 0..<repetitions {
            for text in queries {
                let request = try RecallRequest(taskID: "t", attemptID: "a", revision: 1, reason: .initial, remainingWork: text,
                                                values: [try TaskValue(name: "output_name", kind: .text, content: .text("x_1"), source: .request)])
                let started = ContinuousClock.now
                let prepared = try await service.prepare(request)
                let selecting = ContinuousClock.now
                _ = service.outcomes(prepared)
                let selection = selecting.duration(to: .now)
                phases["embedding"]!.append(milliseconds(prepared.phases.embedding))
                phases["scoring"]!.append(milliseconds(prepared.phases.scoring))
                phases["reading"]!.append(milliseconds(prepared.phases.reading))
                phases["selection"]!.append(milliseconds(selection))
                phases["total"]!.append(milliseconds(started.duration(to: .now)))
            }
        }
        return phases
    }

    @Test("a generated catalogue learned through the tools: learning, index build, size, cold and warm searches, memory",
          .enabled(if: scale?.hasPrefix("catalogue:") == true, "MECUM_RECALL_SCALE=catalogue:N asks for it"))
    func catalogue() async throws {
        let count = Int(Self.scale?.split(separator: ":").last ?? "") ?? 200
        let directory = try W.directory()
        let memory = MemoryService.shared(for: directory)
        var lexical = RecallCycleTests.configuration(.lexical)
        lexical.format = .labelled
        RecallService.install(RecallService(memory: memory, configuration: lexical))
        var report: [String: Any] = ["procedures": count, "applications": 40, "steps per procedure": 4,
                                     "hardware": Self.hardware(),
                                     "footprint start MB": Self.footprintMB()]
        let learning = ContinuousClock.now
        for index in 0..<count {
            try await Self.learnGenerated(index, directory: directory)
            if index % 500 == 499 { print("RECALL-SCALE learned \(index + 1)") }
        }
        report["learning s"] = Self.milliseconds(learning.duration(to: .now)) / 1000
        let lexicalBuild = ContinuousClock.now
        await RecallService.shared(for: memory).schedule()
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(3600)))
        report["lexical index settle s"] = Self.milliseconds(lexicalBuild.duration(to: .now)) / 1000
        let status = try await memory.perform { try await $0.recall.status() }
        report["entries"] = status.entries
        report["parts per procedure"] = Double(status.entries) / Double(count)
        let queries = Self.queries(40)
        var service = RecallService.shared(for: memory)
        _ = try await Self.measure(service, queries: queries, repetitions: 1)
        report["lexical warm ms"] = try await Self.measure(service, queries: queries, repetitions: 5).mapValues { Self.summary($0) }

        if let models = RecallCycleTests.models {
            var semantic = RecallCycleTests.configuration(.hybrid)
            semantic.modelsDirectory = models
            semantic.model = .multilingualE5Small
            service = RecallService(memory: memory, configuration: semantic)
            RecallService.install(service)
            let build = ContinuousClock.now
            await service.schedule()
            #expect(await service.waitUntilIdle(within: .seconds(7200)))
            report["e5 index build s"] = Self.milliseconds(build.duration(to: .now)) / 1000
            let settled = try await memory.perform { try await $0.recall.status() }
            report["e5 vectors backlog"] = settled.vectorBacklog
            report["distinct documents"] = Int(try rawRows("SELECT count(*) FROM memory_recall_documents", at: memory.url).first ?? "0") ?? 0
            report["vectors"] = Int(try rawRows("SELECT count(*) FROM memory_recall_vectors", at: memory.url).first ?? "0") ?? 0
            report["vector bytes"] = Int(try rawRows("SELECT sum(length(vector)) FROM memory_recall_vectors", at: memory.url).first ?? "0") ?? 0
            report["truncated documents"] = Int(try rawRows("SELECT count(*) FROM memory_recall_vectors WHERE truncated = 1", at: memory.url).first ?? "0") ?? 0
            _ = try await Self.measure(service, queries: queries, repetitions: 1)
            report["hybrid warm ms"] = try await Self.measure(service, queries: queries, repetitions: 5).mapValues { Self.summary($0) }
            report["footprint after e5 MB"] = Self.footprintMB()
            if Self.environment["MECUM_RECALL_EXPORT"] == "1", let out = Self.environment["MECUM_RECALL_EVAL_OUT"] {
                try await Self.export(service, queries: queries, to: URL(fileURLWithPath: out, isDirectory: true))
            }
        }
        await memory.close()
        MemoryService.forget(directory)
        let attributes = try FileManager.default.attributesOfItem(atPath: memory.url.path)
        report["archive bytes"] = (attributes[.size] as? NSNumber)?.intValue ?? 0

        // Cold: a new process's first search reads the index into memory.
        let reopened = MemoryService.shared(for: directory)
        var cold: [String: Any] = [:]
        var configurations: [(String, RecallConfiguration)] = [("lexical", lexical)]
        if let models = RecallCycleTests.models {
            var hybrid = RecallCycleTests.configuration(.hybrid)
            hybrid.modelsDirectory = models
            hybrid.model = .multilingualE5Small
            configurations.append(("hybrid", hybrid))
        }
        for (name, configuration) in configurations {
            let fresh = RecallService(memory: reopened, configuration: configuration)
            RecallService.install(fresh)
            let started = ContinuousClock.now
            _ = try await Self.measure(fresh, queries: [queries[0]], repetitions: 1)
            cold[name + " first search ms (index read, model load)"] = Self.milliseconds(started.duration(to: .now))
        }
        report["cold"] = cold
        report["footprint end MB"] = Self.footprintMB()
        await reopened.close()
        MemoryService.forget(directory)
        print("RECALL-SCALE \(report)")
        try Self.write(report, name: "recall-scale-catalogue-\(count)")
    }

    /// Writes the current generation's vectors and the queries' vectors as little-endian float32 files.
    static func export(_ service: RecallService, queries: [String], to folder: URL) async throws {
        let prepared = try await service.prepare(try RecallRequest(taskID: "t", attemptID: "a", revision: 1, reason: .initial,
                                                                   remainingWork: queries[0]))
        guard let cache = prepared.cache else { return }
        var unique: [String: [Float]] = [:]
        for entry in cache.slots.compactMap({ $0 }) { if let vector = entry.vector { unique[entry.digest] = vector } }
        let vectors = unique.keys.sorted().compactMap { unique[$0] }
        let model = try LocalEmbeddingModel(manifest: .multilingualE5Small,
                                            directory: RecallCycleTests.models!.appendingPathComponent(EmbeddingModelManifest.multilingualE5Small.directoryName))
        let queryVectors = try model.embed(queries.map { RecallText.masked($0, values: []) }, as: .query).map(\.vector)
        func data(_ rows: [[Float]]) -> Data { rows.flatMap { $0 }.withUnsafeBufferPointer { Data(buffer: $0) } }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data(vectors).write(to: folder.appendingPathComponent("recall-vectors-\(vectors.count)x384.f32"))
        try data(queryVectors).write(to: folder.appendingPathComponent("recall-queries-\(queryVectors.count)x384.f32"))
    }

    nonisolated static func hardware() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let memory = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        let name = String(decoding: brand.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "\(name), \(ProcessInfo.processInfo.activeProcessorCount) cores, \(memory) GiB, "
            + ProcessInfo.processInfo.operatingSystemVersionString
    }

    // MARK: Models

    @Test("each pinned model: load with and without hashing its weights, memory, a query's embedding, documents' throughput, truncation",
          .enabled(if: scale == "models" && RecallCycleTests.models != nil, "MECUM_RECALL_SCALE=models and MECUM_RECALL_MODELS ask for it"))
    func models() throws {
        let folder = try #require(RecallCycleTests.models)
        let corpus = try RecallCorpus.load()
        let texts = (corpus.json["queries"].array ?? []).compactMap { $0["remaining"].string }
        var report: [String: Any] = ["hardware": Self.hardware()]
        for (name, manifest) in EmbeddingModelManifest.known.sorted(by: { $0.key < $1.key }) {
            let directory = folder.appendingPathComponent(manifest.directoryName)
            let before = Self.footprintMB()
            let verified = try LocalEmbeddingModel(manifest: manifest, directory: directory, verifyWeights: true)
            let loaded = Self.footprintMB()
            let unverified = try LocalEmbeddingModel(manifest: manifest, directory: directory, verifyWeights: false)
            _ = try verified.embed(["warm"], as: .query)
            var single: [Double] = []
            for _ in 0..<3 {
                for text in texts {
                    let started = ContinuousClock.now
                    _ = try verified.embed([text], as: .query)
                    single.append(Self.milliseconds(started.duration(to: .now)))
                }
            }
            let documents = (0..<256).map { "Step \($0): open the export dialog of the document and confirm it. In Preview. Needs: name of the exported file." }
            let started = ContinuousClock.now
            let embedded = try verified.embed(documents, as: .document)
            let batch = Self.milliseconds(started.duration(to: .now))
            let long = try verified.embed([String(repeating: "export the report and confirm ", count: 200)], as: .document)[0]
            report[name] = [
                "model": "\(manifest.modelID)@\(manifest.revision)", "license": manifest.license, "weights bytes": manifest.weightsBytes,
                "load with weights hash ms": Self.milliseconds(verified.loadDuration),
                "load without weights hash ms": Self.milliseconds(unverified.loadDuration),
                "footprint growth after one load MB": loaded - before, "footprint after both MB": Self.footprintMB(),
                "query embedding ms": Self.summary(single), "documents per second (batch of 256)": 256_000 / batch,
                "document tokens": embedded[0].tokenCount, "maximum tokens": manifest.maximumTokens,
                "long text tokens": long.tokenCount, "long text truncated": long.isTruncated,
            ] as [String: Any]
            print("RECALL-MODELS \(name): \(report[name]!)")
        }
        try Self.write(report, name: "recall-scale-models")
    }

    // MARK: Kernel

    @Test("the exact scoring alone, from ten thousand to a million vectors of 384 dimensions",
          .enabled(if: scale == "kernel", "MECUM_RECALL_SCALE=kernel asks for it"))
    func kernel() throws {
        let dimensions = 384
        var report: [String: Any] = ["hardware": Self.hardware(), "dimensions": dimensions]
        var generator = SystemRandomNumberGenerator()
        let query: [Float] = {
            var vector = (0..<dimensions).map { _ in Float.random(in: -1...1, using: &generator) }
            let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            vector = vector.map { $0 / norm }
            return vector
        }()
        for count in [10_000, 100_000, 1_000_000] {
            let before = Self.footprintMB()
            var contiguous = [Float](repeating: 0, count: count * dimensions)
            for index in contiguous.indices { contiguous[index] = Float.random(in: -1...1, using: &generator) }
            let rows: [[Float]] = (0..<count).map { Array(contiguous[($0 * dimensions)..<(($0 + 1) * dimensions)]) }
            let after = Self.footprintMB()
            var perEntry: [Double] = []
            var matrix: [Double] = []
            var scores = [Float](repeating: 0, count: count)
            for _ in 0..<7 {
                var started = ContinuousClock.now
                query.withUnsafeBufferPointer { q in
                    for (index, row) in rows.enumerated() {
                        var dot: Float = 0
                        row.withUnsafeBufferPointer { vDSP_dotpr(q.baseAddress!, 1, $0.baseAddress!, 1, &dot, vDSP_Length(dimensions)) }
                        scores[index] = dot
                    }
                }
                perEntry.append(Self.milliseconds(started.duration(to: .now)))
                started = ContinuousClock.now
                contiguous.withUnsafeBufferPointer { m in
                    query.withUnsafeBufferPointer { q in
                        scores.withUnsafeMutableBufferPointer { s in
                            vDSP_mmul(m.baseAddress!, 1, q.baseAddress!, 1, s.baseAddress!, 1, vDSP_Length(count), 1, vDSP_Length(dimensions))
                        }
                    }
                }
                matrix.append(Self.milliseconds(started.duration(to: .now)))
            }
            report["\(count)"] = ["per-entry dot ms": Self.summary(perEntry), "contiguous matrix-vector ms": Self.summary(matrix),
                                  "vector bytes": count * dimensions * 4, "footprint growth MB (both layouts)": after - before]
            print("RECALL-KERNEL \(count): per-entry p50 \(Self.summary(perEntry)["p50"]!) ms, matrix p50 \(Self.summary(matrix)["p50"]!) ms")
        }
        try Self.write(report, name: "recall-scale-kernel")
    }
}
