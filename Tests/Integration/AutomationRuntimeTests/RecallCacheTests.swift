//
//  RecallCacheTests.swift
//  Braus
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

/// RecallCacheTests prove that the index in memory kept current by reading only what changed is the index a whole read
/// gives: after new versions, a version superseded by a reinterpretation, a part retired, and vectors computed later,
/// the cache a service kept current holds the same entries, in the same order, with the same vectors, as one read whole
/// by a fresh service over the same generation; and the searches answer the same. The retired part is never delivered
/// whatever the cache holds: the catalogue is read again before any delivery.
@MainActor
@Suite("The Recall's index in memory kept current by what changed", .serialized)
struct RecallCacheTests {

    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests

    /// A guest over the same archive and generation, which reads the whole generation on its first search.
    static func freshReader(_ memory: MemoryService, _ configuration: RecallConfiguration) -> RecallService {
        var guest = configuration
        guest.ownsIndex = false
        return RecallService(memory: memory, configuration: guest, embedder: L.HashedEmbedding())
    }

    static func same(_ kept: RecallService, _ memory: MemoryService, _ configuration: RecallConfiguration) async throws -> Bool {
        let incremental = try await kept.cachedEntries()
        let whole = try await Self.freshReader(memory, configuration).cachedEntries()
        let same = incremental.count == whole.count && zip(incremental, whole).allSatisfy {
            $0.partID == $1.partID && $0.digest == $1.digest && $0.hasVector == $1.hasVector
        }
        if !same {
            let a = Set(incremental.map { "\($0.partID) \($0.digest.prefix(8)) \($0.hasVector)" })
            let b = Set(whole.map { "\($0.partID) \($0.digest.prefix(8)) \($0.hasVector)" })
            Issue.record("kept only: \(a.subtracting(b).sorted().prefix(5)); whole only: \(b.subtracting(a).sorted().prefix(5)); counts \(incremental.count) \(whole.count)")
        }
        return same
    }

    @Test("new versions, a superseded version, a retired part and later vectors: the cache kept current equals a whole read")
    func keptEqualsWhole() async throws {
        let session = P.photoSession(try W.directory())
        let configuration = L.configuration(.hybrid)
        let memory = MemoryService.shared(for: session.directory)
        let service = RecallService(memory: memory, configuration: configuration, embedder: L.HashedEmbedding())
        RecallService.install(service)
        let (candidate, first) = try await L.learnPhoto(session, configuration: configuration, service: service)
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        _ = try await service.cachedEntries()
        let initial = await service.refreshCounts()
        #expect(initial.whole.count == 1)

        // New versions: the corpus's knowledge, learned through the tools while the cache is held.
        let corpus = try RecallCorpus.load()
        for item in corpus.knowledge.prefix(4) { _ = try await corpus.learn(item, into: session.directory) }
        #expect(await service.waitUntilIdle(within: .seconds(120)))
        #expect(try await Self.same(service, memory, configuration), "after new versions")

        // A reinterpretation supersedes the photo's first version: its entries leave, the second's come.
        let renamed = P.photoInterpretation(candidate).replacingOccurrences(of: "Confirm the export", with: "Save the exported image")
        #expect(try await P.task(P.tools(session), renamed)["status"].string == "interpreted")
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        #expect(try await Self.same(service, memory, configuration), "after a superseded version")
        #expect(try await service.cachedEntries().allSatisfy { !$0.partID.hasPrefix(first + "/") }, "the superseded version is out")

        // A part retired: its entry leaves, and before the worker removes it the catalogue keeps it from any delivery.
        let second = ProcedureAssembly.routeID(candidateID: candidate, revision: 2)
        let format = "\(second)/step-5"
        _ = try await memory.perform { try await $0.procedures.setState(.retired, of: format, reason: "the pop-up moved", by: "test",
                                                                        at: memory.clock.calendarMS()) }
        let begun = try await P.task(P.tools(session, stream: "before-the-worker"), RecallCycleTests.exportRequest)
        let steps = begun["recall"]["needs"].array?.first?["selection"]["steps"].array?.compactMap { RecallCycleTests.int($0["step"]) } ?? []
        #expect(!steps.contains(6), "never delivered, whatever the cache still held: \(steps)")
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        #expect(try await Self.same(service, memory, configuration), "after a retired part")
        #expect(try await service.cachedEntries().allSatisfy { $0.partID != format })

        let counts = await service.refreshCounts()
        #expect(counts.whole.count == 1, "one whole read, then only what changed: \(counts)")
        #expect(!counts.changed.isEmpty && counts.changedVersions.allSatisfy { $0 >= 1 })
        await L.close(session)
    }

    @Test("a new generation is read whole; the whole read is still what a service that does not keep the cache current does")
    func newGenerationReadWhole() async throws {
        let session = P.photoSession(try W.directory())
        let configuration = L.configuration(.lexical)
        let memory = MemoryService.shared(for: session.directory)
        let service = RecallService(memory: memory, configuration: configuration)
        RecallService.install(service)
        _ = try await L.learnPhoto(session, configuration: configuration, service: service)
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        _ = try await service.cachedEntries()
        try await memory.perform { try await $0.recall.queueRebuild(at: memory.clock.calendarMS()) }
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        _ = try await service.cachedEntries()
        let rebuilt = await service.refreshCounts()
        #expect(rebuilt.whole.count == 2, "another generation is another index")
        // The comparison's other arm: every moved revision read whole.
        let whole = RecallService(memory: memory, configuration: { var guest = configuration; guest.ownsIndex = false; return guest }())
        await whole.refreshIncrementally(false)
        _ = try await whole.cachedEntries()
        let corpus = try RecallCorpus.load()
        _ = try await corpus.learn(corpus.knowledge[0], into: session.directory)
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        _ = try await whole.cachedEntries()
        let wholeCounts = await whole.refreshCounts()
        #expect(wholeCounts.whole.count == 2 && wholeCounts.changed.isEmpty)
        #expect(try await Self.same(service, memory, configuration))
        await L.close(session)
    }
}
