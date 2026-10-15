//
//  LearningCostProbeTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import Foundation
import Memory
import Testing

/// LearningCostProbeTests learn `BRAUS_LEARNING_PROBE` generated procedures one after another into one archive through the
/// real producers (`RecallScaleTests.learnGenerated`), the index owned by the lexical configuration so no embedding cost is
/// counted, or by the product's (`BRAUS_LEARNING_PROBE_CONFIG=product`), and write each procedure's learning time to `BRAUS_RECALL_EVAL_OUT/learning-probe.csv`: how the cost of
/// learning grows with the archive, for the scale campaign. `BRAUS_LEARNING_PROBE_WORDS=load` learns the staged load's
/// procedures instead (`RecallLoadTests.words`: documents of their own, two hundred applications), the generator D3's
/// staged figures were measured with. Load data, never quality data. Gated; nothing runs without it.
@MainActor
@Suite("Learning cost as the archive grows", .serialized)
struct LearningCostProbeTests {
    nonisolated static var count: Int? { ProcessInfo.processInfo.environment["BRAUS_LEARNING_PROBE"].flatMap(Int.init) }

    @Test("the time to learn each procedure, from an empty archive to the probe's size",
          .enabled(if: count != nil, "BRAUS_LEARNING_PROBE names no number of procedures"))
    func probe() async throws {
        let total = try #require(Self.count)
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BRAUS_RECALL_EVAL_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let named = ProcessInfo.processInfo.environment["BRAUS_LEARNING_PROBE_ARCHIVE"]
        let directory = try named.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? W.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let memory = MemoryService.shared(for: directory)
        // The lexical owner by default; `BRAUS_LEARNING_PROBE_CONFIG=product` measures the product's configuration (hybrid
        // Granite, its models from `BRAUS_RECALL_MODELS`), whose worker embeds every new document beside the learning.
        var configuration = RecallCycleTests.configuration(.lexical)
        configuration.lexicalWeighting = .uniform
        if ProcessInfo.processInfo.environment["BRAUS_LEARNING_PROBE_CONFIG"] == "product" {
            configuration = RecallConfiguration.chosen
            configuration.modelsDirectory = RecallCycleTests.models
        }
        RecallService.install(RecallService(memory: memory, configuration: configuration))
        let file = out.appendingPathComponent("learning-probe.csv")
        FileManager.default.createFile(atPath: file.path, contents: Data("index,ms\n".utf8))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        // An archive the probe left is continued, not learned again from the start.
        let first = FileManager.default.fileExists(atPath: memory.url.path)
            ? Int(try rawRows("SELECT count(*) FROM memory_procedure_versions", at: memory.url).first ?? "0") ?? 0 : 0
        for index in first..<total {
            let started = ContinuousClock.now
            if ProcessInfo.processInfo.environment["BRAUS_LEARNING_PROBE_WORDS"] == "load" {
                let (verb, object, qualifier, app) = RecallLoadTests.words(index)
                try await RecallScaleTests.learnGenerated(index, verb: verb, object: object, qualifier: qualifier, app: app, directory: directory)
            } else {
                try await RecallScaleTests.learnGenerated(index, directory: directory)
            }
            let elapsed = started.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            handle.write(Data("\(index),\(String(format: "%.2f", ms))\n".utf8))
        }
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(600)))
        #expect(await memory.flush(within: .seconds(60)))
        print("LEARNING-PROBE archive \(directory.path)")
    }
}
