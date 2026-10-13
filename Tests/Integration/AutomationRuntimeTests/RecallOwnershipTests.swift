//
//  RecallOwnershipTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// RecallOwnershipTests prove who decides the index of an archive two processes share: the product's configuration owns
/// it; a configuration chosen for one process by `MECUM_RECALL` is a guest that keeps the owner's generations in line
/// with the catalogue, never starts, abandons or promotes one, and says it answered over the owner's index. Without that
/// rule, two owners of different configurations retire each other's generations, which the control case shows.
@MainActor
@Suite("The Recall's index has one owner per archive; another configuration is a guest", .serialized)
struct RecallOwnershipTests {

    typealias P = ProcedureLearningTests
    typealias G = RecallScaleTests

    static func contextual(owns: Bool) -> RecallConfiguration {
        var configuration = RecallCycleTests.configuration(.lexical)
        configuration.format = .contextual
        configuration.ownsIndex = owns
        return configuration
    }

    @Test("an override is a guest: the owner's generation stays current while both workers run and the catalogue grows")
    func guestNeverReplacesTheOwnersGeneration() async throws {
        let directory = try W.directory()
        let memory = MemoryService.shared(for: directory)
        let owner = RecallService(memory: memory, configuration: RecallCycleTests.configuration(.lexical))
        let guest = RecallService(memory: memory, configuration: Self.contextual(owns: false))
        RecallService.install(owner)
        for index in 0..<6 {
            try await G.learnGenerated(index, verb: "Export", object: "invoice", qualifier: "for the team", app: "com.example.App\(index)",
                                       directory: directory)
            await owner.schedule()
            await guest.schedule()
        }
        let ownerIdle = await owner.waitUntilIdle(within: .seconds(60))
        let guestIdle = await guest.waitUntilIdle(within: .seconds(60))
        #expect(ownerIdle && guestIdle)
        let file = directory.appendingPathComponent("memory.sqlite")
        let generations = try rawRows("SELECT document_format || ':' || status || ':' || ifnull(reason, '-') FROM memory_recall_generations "
                                      + "ORDER BY generation_id", at: file)
        #expect(generations.filter { $0.contains(":ready:") } == ["\(RecallDocument.Format.labelled.rawValue):ready:-"], "\(generations)")
        #expect(!generations.contains { $0.hasSuffix("configuration changed") }, "nothing was abandoned: \(generations)")
        #expect(generations.allSatisfy { $0.hasPrefix(RecallDocument.Format.labelled.rawValue + ":") }, "the guest started none: \(generations)")
        let status = try await memory.perform { try await $0.recall.status() }
        #expect(status.pendingWork == 0, "the owner applied every change")
        let request = try RecallRequest(taskID: "t", attemptID: "a", revision: 1, reason: .initial,
                                        remainingWork: "Export the invoice for the team as fattura_9",
                                        values: [try TaskValue(name: "output_name", kind: .text, content: .text("fattura_9"), source: .request)])
        let answered = try await guest.prepare(request)
        #expect(answered.searchStatus == .limited && answered.notes.contains { $0.contains("archive's own configuration") }, "\(answered.notes)")
        #expect(!answered.sources.isEmpty, "the guest still answers over the owner's index")
        await memory.close()
        RecallService.forget(memory)
        MemoryService.forget(directory)
    }

    @Test("an override equal to the product's configuration owns the index; a different one is a guest")
    func ownershipFromTheEnvironment() {
        #expect(RecallConfiguration.resolved(environment: [:]).ownsIndex)
        #expect(RecallConfiguration.resolved(environment: ["MECUM_RECALL": RecallConfiguration.chosen.channel.rawValue]).ownsIndex)
        let other: RecallConfiguration.Channel = RecallConfiguration.chosen.channel == .lexical ? .hybrid : .lexical
        #expect(!RecallConfiguration.resolved(environment: ["MECUM_RECALL": "\(other.rawValue):e5-small"]).ownsIndex)
    }

    @Test("the control: two owners of different configurations on one archive abandon or retire each other's generations")
    func twoOwnersFight() async throws {
        let directory = try W.directory()
        let memory = MemoryService.shared(for: directory)
        let first = RecallService(memory: memory, configuration: RecallCycleTests.configuration(.lexical))
        let second = RecallService(memory: memory, configuration: Self.contextual(owns: true))
        RecallService.install(first)
        try await G.learnGenerated(0, verb: "Export", object: "invoice", qualifier: "for the team", app: "com.example.App0", directory: directory)
        _ = await first.waitUntilIdle(within: .seconds(60))
        await second.schedule()
        _ = await second.waitUntilIdle(within: .seconds(60))
        await first.schedule()
        _ = await first.waitUntilIdle(within: .seconds(60))
        let generations = try rawRows("SELECT document_format || ':' || status FROM memory_recall_generations ORDER BY generation_id",
                                      at: directory.appendingPathComponent("memory.sqlite"))
        #expect(generations.filter { $0.hasSuffix(":retired") }.count >= 2, "each owner retired the other's ready generation: \(generations)")
        await memory.close()
        RecallService.forget(memory)
        MemoryService.forget(directory)
    }
}
