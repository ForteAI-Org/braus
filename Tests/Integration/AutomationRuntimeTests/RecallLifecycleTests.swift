//
//  RecallLifecycleTests.swift
//  Braus
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
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// RecallLifecycleTests prove what the Recall answers when its index cannot, and what its index does when the
/// catalogue or the configuration changes, through the product's tools and service over the session double: an
/// index not built yet is unavailable and one that cannot be read failed, neither of them an absence; a part retired
/// between the search and the delivery is never delivered; a superseded version is never offered; index work that
/// keeps failing stays pending and is said; a new embedding space is built while the old generation answers; a build
/// interrupted by the end of the process is resumed; an archive of schema 5 migrates and queues its one rebuild.
/// The thresholds are structural (the best episode alone, never a whole part), so what is proved is the lifecycle,
/// not a calibration. These are integration proofs, not a live run.
@MainActor
@Suite("The Recall's index through faults, changes, new spaces and migrations", .serialized, .automaticSelection)
struct RecallLifecycleTests {

    typealias P = ProcedureLearningTests

    /// A deterministic embedding in the space of the pinned E5 manifest, for the tests of a space's lifecycle: a
    /// hashed bag of the text's content words, normalized. It reads nothing but its texts and needs no model file.
    struct HashedEmbedding: TextEmbedding {
        let space = EmbeddingModelManifest.multilingualE5Small.space

        func embed(_ texts: [String], as role: EmbeddingRole) throws -> [EmbeddedText] {
            texts.map { text in
                var vector = [Float](repeating: 0, count: space.dimensions)
                let tokens = RecallText.tokens(text)
                for token in tokens {
                    let hash = token.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
                    vector[Int(hash % UInt64(space.dimensions))] += 1
                }
                vector[0] += 0.01
                let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
                return EmbeddedText(vector: vector.map { $0 / norm }, tokenCount: tokens.count + 2, isTruncated: false)
            }
        }
    }

    static let structural = SelectionThresholds(absolute: 0.15, stepMargin: 0.01, partMargin: -0.5, adequacy: 0, tie: 0)

    static func configuration(_ channel: RecallConfiguration.Channel = .lexical) -> RecallConfiguration {
        var configuration = RecallCycleTests.configuration(channel)
        // The hashed embedding stands in for E5: the space a semantic configuration names is its.
        if channel != .lexical { configuration.model = .multilingualE5Small }
        configuration.lexicalThresholds = structural
        configuration.semanticThresholds = SelectionThresholds(absolute: 0.1, stepMargin: 0.01, partMargin: -0.5, adequacy: 0, tie: 0)
        configuration.hybridThresholds = structural
        return configuration
    }

    /// Learns the photo export through the tools with the Recall installed (`service`, else one of `configuration`), and
    /// waits for its index.
    static func learnPhoto(_ session: LearningSession, configuration: RecallConfiguration = configuration(),
                           service: RecallService? = nil) async throws -> (String, String) {
        let memory = MemoryService.shared(for: session.directory)
        RecallService.install(service ?? RecallService(memory: memory, configuration: configuration))
        let tools = P.tools(session)
        _ = try await P.task(tools, #"""
            {"operation":"begin","goal":"Find foto_demo, rotate it and export it as foto_web.jpg in JPEG","recall":false,
             "inputs":[{"name":"criterion","value":"foto_demo"},{"name":"output_name","value":"foto_web"}]}
            """#)
        try await P.runPhotoExport(tools, session)
        let ended = try await P.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let candidate = try #require(ended["candidate"]["id"].string)
        _ = try await P.task(tools, P.photoInterpretation(candidate))
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        return (candidate, ProcedureAssembly.routeID(candidateID: candidate, revision: 1))
    }

    static func close(_ session: LearningSession) async {
        let memory = MemoryService.shared(for: session.directory)
        RecallService.forget(memory)
        await memory.close()
        MemoryService.forget(session.directory)
    }

    static func url(_ session: LearningSession) -> URL { session.directory.appendingPathComponent("memory.sqlite") }

    // MARK: Faults

    @Test("an index never built over a learned procedure answers unavailable and unknown, recorded as such: never an absence; an archive that never learned anything answers a complete search that finds nothing")
    func unavailableIsNotAbsent() async throws {
        let empty = P.photoSession(try W.directory())
        let emptyMemory = MemoryService.shared(for: empty.directory)
        let emptyService = RecallService(memory: emptyMemory, configuration: Self.configuration())
        RecallService.install(emptyService)
        await emptyService.holdWork(true)
        let emptyBegun = try await P.task(P.tools(empty), #"{"operation":"begin","goal":"Export the photo as PNG","recall":false}"#)
        let nothing = try await emptyService.recall(
            try RecallRequest(taskID: try #require(emptyBegun["task"].string), attemptID: try #require(emptyBegun["attempt"].string),
                              revision: 1, reason: .initial, remainingWork: "Export the photo as PNG"),
            producer: try TaskProducer(source: .app, streamID: "worker-1"))
        #expect(nothing.delivery.search.status == "completed" && nothing.delivery.coverage == "absent", "the catalogue proves the absence")
        #expect(nothing.delivery.index.status == "empty" && nothing.delivery.search.note == "nothing has been learned on this Mac yet")
        await Self.close(empty)

        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        let service = RecallService(memory: memory, configuration: Self.configuration())
        RecallService.install(service)
        // The worker is held: a procedure is learned and nothing of it reaches an index.
        await service.holdWork(true)
        _ = try await Self.learnPhoto(session, service: service)
        let tools = P.tools(session, stream: "worker-2")
        let begun = try await P.task(tools, #"{"operation":"begin","goal":"Export the photo as PNG","recall":false}"#)
        let request = try RecallRequest(taskID: try #require(begun["task"].string), attemptID: try #require(begun["attempt"].string),
                                        revision: 1, reason: .initial, remainingWork: "Export the photo as PNG")
        let answer = try await service.recall(request, producer: try TaskProducer(source: .app, streamID: "worker-2"))
        #expect(answer.delivery.search.status == "unavailable" && answer.delivery.coverage == "unknown")
        #expect(answer.delivery.index.status == "unavailable" && answer.delivery.delivery == "nothing")
        #expect(try rawRows("SELECT search_status || ':' || coverage || ':' || delivery || ':' || channel FROM memory_recall_queries",
                            at: Self.url(session)) == ["unavailable:unknown:nothing:none"])
        await Self.close(session)
    }

    @Test("an index that cannot be read answers failed and unknown through the tool; the task is begun all the same")
    func failedIsNotAbsent() async throws {
        let session = P.photoSession(try W.directory())
        let (_, _) = try await Self.learnPhoto(session)
        let memory = MemoryService.shared(for: session.directory)
        await RecallService.shared(for: memory).setIndexFault(RecallCorpus.Failure("disk I/O error"))
        let begun = try await P.task(P.tools(session, stream: "worker-2"), RecallCycleTests.exportRequest)
        #expect(begun["status"].string == "begun")
        #expect(begun["recall"]["search"]["status"].string == "failed" && begun["recall"]["coverage"].string == "unknown", "\(begun)")
        #expect(begun["recall"]["search"]["note"].string?.contains("disk I/O error") == true)
        #expect(try rawRows("SELECT search_status || ':' || coverage FROM memory_recall_queries", at: Self.url(session)) == ["failed:unknown"])
        await Self.close(session)
    }

    // MARK: Changes of the catalogue

    @Test("a part retired between the search and the delivery is never delivered: the versions are read again and selected again")
    func retiredBeforeDelivery() async throws {
        let session = P.photoSession(try W.directory())
        let (_, routeID) = try await Self.learnPhoto(session)
        let memory = MemoryService.shared(for: session.directory)
        let format = "\(routeID)/step-5"
        await RecallService.shared(for: memory).setBeforeRecord {
            _ = try? await memory.perform { try await $0.procedures.setState(.retired, of: format, reason: "the format pop-up moved",
                                                                              by: "test", at: memory.clock.calendarMS()) }
        }
        let begun = try await P.task(P.tools(session, stream: "worker-2"), RecallCycleTests.exportRequest)
        let need = try #require(begun["recall"]["needs"].array?.first)
        let steps = need["selection"]["steps"].array?.compactMap { RecallCycleTests.int($0["step"]) } ?? []
        #expect(!steps.isEmpty && !steps.contains(6), "the retired format step is not delivered: \(need)")
        #expect(need["coverage"].string == "partial" && need["reason"].string == "gaps", "\(need)")
        #expect(need["selection"]["conditions"].array?.contains { $0["kind"].string == "prerequisite_out_of_catalogue" } == true)
        #expect(try rawRows("SELECT count(*) FROM memory_recall_selections WHERE 5 BETWEEN first_position AND last_position",
                            at: Self.url(session)) == ["0"])
        // The state's index work is queued with it and removes the part from the index when a worker takes it.
        #expect(try rawRows("SELECT reason FROM memory_recall_work WHERE done_at_ms IS NULL", at: Self.url(session)) == ["state"])
        await RecallService.shared(for: memory).schedule()
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(30)))
        #expect(try rawRows("SELECT count(*) FROM memory_recall_entries WHERE part_id = '\(format)'", at: Self.url(session)) == ["0"])
        await Self.close(session)
    }

    @Test("a version superseded by a new interpretation leaves the index and is never offered")
    func supersededNeverOffered() async throws {
        let session = P.photoSession(try W.directory())
        let (candidate, first) = try await Self.learnPhoto(session)
        let renamed = P.photoInterpretation(candidate).replacingOccurrences(of: "Confirm the export", with: "Save the exported image")
        let interpreted = try await P.task(P.tools(session), renamed)
        #expect(interpreted["status"].string == "interpreted" && interpreted["revision"] == .number(2), "\(interpreted)")
        let memory = MemoryService.shared(for: session.directory)
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(30)))
        #expect(try rawRows("SELECT count(*) FROM memory_recall_entries WHERE route_id = '\(first)'", at: Self.url(session)) == ["0"])
        let second = ProcedureAssembly.routeID(candidateID: candidate, revision: 2)
        let begun = try await P.task(P.tools(session, stream: "worker-2"), RecallCycleTests.exportRequest)
        #expect(begun["recall"]["needs"].array?.first?["selection"]["version"].string == second, "\(begun)")
        #expect(try rawRows("SELECT DISTINCT route_id FROM memory_recall_selections", at: Self.url(session)) == [second])
        await Self.close(session)
    }

    @Test("index work that keeps failing stays pending and is said; the part it concerns is not offered whatever the index holds")
    func stuckWork() async throws {
        let session = P.photoSession(try W.directory())
        let (_, routeID) = try await Self.learnPhoto(session)
        let memory = MemoryService.shared(for: session.directory)
        RecallService.forget(memory)
        let confirm = "\(routeID)/step-6"
        _ = try await memory.perform { try await $0.procedures.setState(.toReevaluate, of: confirm, reason: "check the dialog",
                                                                         by: "test", at: memory.clock.calendarMS()) }
        let work = try #require(try await memory.perform { try await $0.recall.pendingWork(limit: 10) }.first)
        for _ in 0..<RecallService.workAttemptLimit {
            try await memory.perform { try await $0.recall.failed(work.workID, reason: "simulated fault") }
        }
        let service = RecallService(memory: memory, configuration: Self.configuration())
        RecallService.install(service)
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(30)))
        let status = try await service.status()
        #expect(status.index.pendingWork == 1)
        #expect(try await memory.perform { try await $0.recall.pendingWork(limit: 10) }.first?.attempts == RecallService.workAttemptLimit)
        let begun = try await P.task(P.tools(session, stream: "worker-2"), RecallCycleTests.exportRequest)
        #expect(begun["recall"]["search"]["status"].string == "limited", "\(begun)")
        #expect(begun["recall"]["search"]["note"].string?.contains("not in the index yet") == true)
        let steps = begun["recall"]["needs"].array?.first?["selection"]["steps"].array?.compactMap { RecallCycleTests.int($0["step"]) } ?? []
        #expect(!steps.contains(7), "the part to evaluate again is not offered, though its entry is still in the index: \(steps)")
        #expect(try rawRows("SELECT count(*) FROM memory_recall_entries WHERE part_id = '\(confirm)'", at: Self.url(session)) == ["1"])
        await Self.close(session)
    }

    // MARK: Generations

    @Test("a new embedding space is built beside the current generation, which answers lexically and says so until the new one is complete")
    func newSpace() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await Self.learnPhoto(session)
        let memory = MemoryService.shared(for: session.directory)
        let service = RecallService(memory: memory, configuration: Self.configuration(.semantic), embedder: HashedEmbedding())
        RecallService.install(service)
        // The new space's generation started and enumerated, its vectors not computed yet: where a worker stands
        // between its passes on a catalogue larger than one batch.
        let space = HashedEmbedding().space
        let now = memory.clock.calendarMS()
        try await memory.perform { try await $0.recall.ensure(space: space, at: now) }
        let building = try await memory.perform { try await $0.recall.startGeneration(format: .labelled, spaceID: space.spaceID, at: now) }
        _ = try await memory.perform { try await $0.recall.enumerate(building, pageSize: 32, at: now) }
        var status = try await service.status()
        #expect(Set(status.index.generations.map(\.status)) == [.ready, .building])
        let ready = try #require(status.index.generations.first { $0.status == .ready })
        #expect(ready.spaceID == nil, "the lexical generation still answers")
        let request = try RecallRequest(taskID: "t", attemptID: "a", revision: 1, reason: .initial,
                                        remainingWork: "Export the document already open in Preview as PNG")
        var prepared = try await service.prepare(request)
        #expect(prepared.channel == .lexical && prepared.searchStatus == .limited)
        #expect(prepared.notes.contains { $0.contains("semantic index is unavailable") }, "\(prepared.notes)")
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        status = try await service.status()
        #expect(status.index.generations.count == 1 && status.index.generations[0].spaceID == HashedEmbedding().space.spaceID)
        #expect(status.index.vectorBacklog == 0)
        #expect(try rawRows("SELECT status FROM memory_recall_generations WHERE generation_id = \(ready.generationID)",
                            at: Self.url(session)) == ["retired"])
        prepared = try await service.prepare(request)
        #expect(prepared.channel == .semantic && prepared.searchStatus == .completed)
        await Self.close(session)
    }

    @Test("a build interrupted by the end of the process is resumed on the next open, the ready generation answering meanwhile")
    func interruptedBuild() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await Self.learnPhoto(session)
        let memory = MemoryService.shared(for: session.directory)
        let entries = try await memory.perform { try await $0.recall.status() }.entries
        let now = memory.clock.calendarMS()
        try await memory.perform { try await $0.recall.queueRebuild(at: now) }
        let building = try await memory.perform {
            try await $0.recall.startGeneration(format: .labelled, spaceID: nil, at: now)
        }
        await Self.close(session)

        let reopened = MemoryService.shared(for: session.directory)
        let service = RecallService(memory: reopened, configuration: Self.configuration())
        RecallService.install(service)
        let request = try RecallRequest(taskID: "t", attemptID: "a", revision: 1, reason: .initial, remainingWork: "Export the photo as PNG")
        let meanwhile = try await service.prepare(request)
        #expect(meanwhile.channel == .lexical && meanwhile.cache?.generation.generationID != building.generationID,
                "the ready generation answers while the other is incomplete")
        await service.schedule()
        #expect(await service.waitUntilIdle(within: .seconds(60)))
        let status = try await service.status()
        #expect(status.index.generations.map(\.generationID) == [building.generationID], "the interrupted build was completed")
        #expect(status.index.generations.first?.status == .ready && status.index.entries == entries && status.index.pendingWork == 0)
        await Self.close(session)
    }

    @Test("a build that fails leaves the ready generation as it was, answering")
    func failedBuild() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await Self.learnPhoto(session)
        let memory = MemoryService.shared(for: session.directory)
        let service = RecallService.shared(for: memory)
        let before = try await service.status().index.generations
        let now = memory.clock.calendarMS()
        let building = try await memory.perform { try await $0.recall.startGeneration(format: .contextual, spaceID: nil, at: now) }
        try await memory.perform { try await $0.recall.fail(building.generationID, reason: "the process stopped", at: now) }
        #expect(try await service.status().index.generations == before)
        let request = try RecallRequest(taskID: "t", attemptID: "a", revision: 1, reason: .initial, remainingWork: "Export the photo as PNG")
        #expect(try await service.prepare(request).searchStatus == .completed)
        #expect(try rawRows("SELECT status || ':' || reason FROM memory_recall_generations WHERE generation_id = \(building.generationID)",
                            at: Self.url(session)) == ["failed:the process stopped"])
        await Self.close(session)
    }

    // MARK: Migration

    @Test("an archive of schema 1 migrates to the current schema, queues one rebuild of the Recall's index in the same transaction, and the rebuild completes")
    func schemaOneArchive() async throws {
        let session = P.photoSession(try W.directory())
        _ = try await Self.learnPhoto(session)
        await Self.close(session)
        let url = Self.url(session)
        // The archive as main's build would hold it: its calls and its Brain, every later table dropped with its rows.
        try UnificationTests.downgrade(url)
        let reopened = MemoryService.shared(for: session.directory)
        RecallService.install(RecallService(memory: reopened, configuration: Self.configuration()))
        _ = try await reopened.ready()
        #expect(try rawRows("PRAGMA user_version", at: url) == ["\(SQLiteMemorySchema.version)"])
        #expect(try rawRows("SELECT reason || ':' || ifnull(route_id, '*') FROM memory_recall_work", at: url) == ["migration:*"])
        #expect(try rawRows("SELECT to_version || ':' || from_version FROM memory_schema_migrations", at: url)
                == ["\(SQLiteMemorySchema.version):1"])
        await RecallService.shared(for: reopened).schedule()
        #expect(await RecallService.shared(for: reopened).waitUntilIdle(within: .seconds(60)))
        #expect(try rawRows("SELECT count(*) FROM memory_recall_work WHERE done_at_ms IS NULL", at: url) == ["0"])
        #expect(try rawRows("SELECT count(*) FROM memory_recall_entries", at: url) == ["0"], "schema 1 holds no procedure to index")
        let again = try await P.task(P.tools(session, stream: "worker-3"), RecallCycleTests.exportRequest)
        #expect(again["recall"]["search"]["status"].string == "completed")
        #expect(again["recall"]["coverage"].string == "absent", "\(again)")
        await Self.close(session)
    }
}
