//
//  UnificationTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import AutomationRuntime
import CoreGraphics
import CryptoKit
import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import TestScratch
import Testing

/// UnificationTests prove that the user's one archive takes in an external client's earlier private
/// archive (schema 1, as builds before G76 wrote it): its facts with their source, its Brain learned again
/// by key, a proven duplicate once, an identity conflict under a new identity, a stopped transfer resumed,
/// a foreign file and an archive of a later build (with tasks, procedures and relations) refused, and the
/// earlier archive never changed.
@Suite("Unifying the external clients' earlier archives into the user's one archive")
struct UnificationTests {

    struct Place {
        let support: URL
        var shared: URL { KnowledgeLocation.knowledge(under: support) }
        func profile(_ name: String) -> URL {
            support.appendingPathComponent("MCP/Knowledge/\(name)", isDirectory: true)
        }
    }

    static func place() throws -> Place {
        let support = Scratch.directory("unification")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return Place(support: support)
    }

    /// An external client's archive of schema 1 in `directory`: a call that taught the Brain, an
    /// observation, written as that client's producer, then left at schema 1 as an earlier build wrote it.
    static func legacyArchive(in directory: URL, stream: String, elements: [SceneElement]) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SQLiteMemoryStore(url: directory.appendingPathComponent("memory.sqlite"), schema: .historical19)
        try await store.open()
        let captures = SQLiteCaptureRepository(store: store)
        let calls = SQLiteAgentCallRepository(store: store)
        let applications = SQLiteBrainApplicationRepository(store: store)
        let app = AppContextIdentity(bundleID: W.bundle)
        let observed = UUID().uuidString, action = UUID().uuidString
        let at: Int64 = 1_790_000_000_000
        let now = Date(timeIntervalSince1970: Double(at) / 1000)
        let before = W.window(elements)
        let after = W.window(elements + [W.button("Bold", x: 0.7)])
        _ = try await captures.record(MemoryEventRecord(eventID: observed, source: .mcp, streamID: stream,
            kind: .observation, app: app, occurredAtMS: at))
        let sample = CaptureSampleKey(eventID: observed, phase: .current)
        _ = try await captures.record(CaptureSample(key: sample, of: before))
        _ = try await applications.apply(.observe(before.scene, sample: sample, requestedAt: now))
        _ = try await calls.record(AgentCallRecord(
            event: MemoryEventRecord(eventID: action, source: .mcp, streamID: stream, sessionID: "s-\(stream)",
                                     kind: .action, app: app, occurredAtMS: at + 1),
            request: .act(target: elements[0].label, verb: .click, value: nil, section: nil)))
        _ = try await calls.advance([AgentCallTransition(action, .init(.started, startedAtMS: at + 1))])
        for (phase, window) in [(CapturePhase.before, before), (.after, after)] {
            _ = try await captures.record(CaptureSample(key: CaptureSampleKey(eventID: action, phase: phase), of: window))
        }
        let effect = SceneEffect.menuOpened(labels: ["Bold", "Italic", "Underline"])
        _ = try await calls.advance([AgentCallTransition(action, .init(.completed,
            result: .outcome(.foundActed, message: "clicked"), endedAtMS: at + 2,
            observedEffect: ObservedEffect(effect)))])
        let record = ActionRecord(bundleID: W.bundle, element: elements[0], verb: .click, effect: effect,
                                  windowTitleAfter: "Document", before: before, after: after)
        _ = try await applications.apply(.record(record, eventID: action, requestedAt: now))
        _ = try await SQLiteBrainRepository(store: store).record(record, now: now)
        await store.close()
        try downgrade(directory.appendingPathComponent("memory.sqlite"))
    }

    /// Leaves a file of this build at schema 1: what the later schemas added is dropped, in the order
    /// that removes it, and the version set back.
    static func downgrade(_ url: URL) throws {
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        let earlier = try SQLiteMemorySchema.objects(of: SQLiteMemorySchema.text(of: 1))
        let added = try SQLiteMemorySchema.orderedObjects(of: SQLiteMemorySchema.historical19Text())
            .filter { !earlier.contains($0) }
        let removal = added.filter { $0.type != "table" } + added.filter { $0.type == "table" }.reversed()
        for object in removal {
            try raw.execute("DROP \(object.type.uppercased()) \(object.name)")
        }
        try raw.execute("PRAGMA user_version = 1")
        _ = try raw.query("PRAGMA wal_checkpoint(TRUNCATE)") { $0.integer(0) }
    }

    static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func count(_ sql: String, at url: URL) throws -> Int64 {
        Int64(try rawRows(sql, at: url).first ?? "0") ?? -1
    }

    @Test("a client's earlier archive comes into the shared one with its source; the workers read what it taught; the earlier archive is unchanged and a second open takes nothing again")
    func unifiesOnce() async throws {
        let place = try Self.place()
        try await Self.legacyArchive(in: place.profile("A"), stream: "mcp-A", elements: [W.format, W.save])
        let legacy = place.profile("A").appendingPathComponent("memory.sqlite")
        let before = try Self.digest(legacy)
        let legacyEvents = try Self.count("SELECT count(*) FROM memory_events", at: legacy)

        let origins = KnowledgeLocation.legacyProfiles(under: place.support)
        #expect(origins.map(\.originID) == ["mcp-profile:A"] && origins[0].hasArchive)
        MemoryService.unify(place.shared, with: origins)
        let memory = MemoryService(directory: place.shared)
        let worker = CallRecorder(
            memory : memory,
            brain  : W.brain(memory),
            context: ActionContext(source: .app, streamID: "worker-1")
        )
        _ = await worker.observe(W.window([W.open]))
        await memory.unificationFinished()
        #expect(await memory.flush(within: .seconds(10)))
        let status = await memory.status()
        #expect(status.lastUnification?.contains("MCP/Knowledge/A: completed") == true,
                "\(status.lastUnification ?? "")")

        let shared = memory.url
        #expect(try Self.count(
            "SELECT count(*) FROM memory_origin_events WHERE origin_id = (SELECT origin_id FROM memory_archive_origins WHERE origin_uuid = 'mcp-profile:A')",
            at: shared
        ) == legacyEvents)
        #expect(try Self.count(
            "SELECT count(*) FROM memory_events WHERE source = 'mcp'",
            at: shared
        ) == legacyEvents)
        #expect(try Self.count(
            "SELECT count(*) FROM memory_agent_actions WHERE execution_status = 'completed'",
            at: shared
        ) == 1)
        let brain = try #require(try await memory.brain(of: W.bundle))
        #expect(brain.objects.isEmpty, "transfer leaves the historical projection frozen")
        #expect(brain.transitions.isEmpty)
        #expect(try Self.digest(legacy) == before, "the earlier archive is only read")
        await memory.close()

        let again = MemoryService(directory: place.shared)
        _ = try await again.ready()
        await again.unificationFinished()
        #expect(try Self.count("SELECT count(*) FROM memory_events WHERE source = 'mcp'", at: shared) == legacyEvents,
                "a second open finds the origin complete and unchanged, and takes nothing again")
        #expect(try rawRows("SELECT status FROM memory_archive_origins", at: shared) == ["completed"])
        await again.close()
    }

    @Test("a copy of facts the shared archive holds adds nothing and no evidence; an identity held by another fact comes in renamed, its samples with it",
          arguments: [false, true])
    func duplicatesAndConflicts(onTheCall: Bool) async throws {
        let place  = try Self.place()
        let shared = place.shared
        try await Self.legacyArchive(in: shared, stream: "mcp-A", elements: [W.format, W.save])
        // The historical duplicate case keeps the text identities and projection writers of schema 19.
        let destination = SQLiteMemoryStore(url: shared.appendingPathComponent("memory.sqlite"), schema: .historical19)
        try await destination.open()
        let evidenceBefore     = try await count("SELECT count(*) FROM brain_evidence", in: destination)
        let applicationsBefore = try await count("SELECT count(*) FROM brain_applications", in: destination)
        // The client's archive is a copy of the same facts, plus one event whose id the shared archive
        // holds with other content.
        let source = place.profile("B").appendingPathComponent("memory.sqlite")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(try await SQLiteArchiveTransfer.adopt(destination.url, as: source))
        // The conflict falls on the observation, so the concluded call comes in as a duplicate, or on
        // the call itself.
        let calls = "SELECT event_id FROM memory_agent_actions"
        let choice = onTheCall ? calls : "SELECT event_id FROM memory_events WHERE event_id NOT IN (\(calls))"
        let taken = try #require(try await destination.read { try $0.query(choice) { try $0.text(0) } }.first ?? nil)
        let concluded = "SELECT count(*) FROM memory_agent_actions WHERE execution_status = 'completed'"
        let concludedBefore = try await count(concluded, in: destination)
        try Self.downgrade(source)
        // Another fact under the same identity: written by hand past the immutability trigger, which is
        // put back as it was.
        let raw = try SQLiteConnection(path: source.path)
        let trigger = try #require(
            try raw.query("SELECT sql FROM sqlite_schema WHERE name = 'memory_events_identity_immutable'") {
                try $0.text(0)
            }.first ?? nil
        )
        try raw.execute("DROP TRIGGER memory_events_identity_immutable")
        _ = try raw.run("UPDATE memory_events SET source_stream_id = 'mcp-B' WHERE event_id = ?", [.text(taken)])
        try raw.execute(trigger)
        raw.close()

        let report = try await SQLiteArchiveTransfer.transfer(
            from    : source,
            origin  : "mcp-profile:B",
            location: "MCP/Knowledge/B",
            into    : destination,
            staging : place.support.appendingPathComponent("staging"),
            nowMS   : 1_760_000_000_000
        )
        #expect(report.status == "completed")
        #expect(report.eventsRenamed == 1 && report.eventsAdded == 0 && report.eventsDuplicate > 0, "\(report)")
        // The copies are the same applications under the same keys and teach nothing again; the renamed event is
        // another fact, whose own application is new.
        #expect(report.applicationsAdded == 1 && report.applicationsDuplicate >= 1, "\(report)")
        #expect(try await count("SELECT count(*) FROM brain_evidence", in: destination) >= evidenceBefore)
        #expect(try await count("SELECT count(*) FROM brain_applications", in: destination)
                == applicationsBefore + Int64(report.applicationsAdded), "only the renamed fact's application is new")
        #expect(Int64(report.applicationsDuplicate) == applicationsBefore - 1)
        let renamed = "\(taken)~mcp-profile:B"
        #expect(try await count(
            "SELECT count(*) FROM memory_events WHERE event_id = '\(renamed)' AND source_stream_id = 'mcp-B'",
            in: destination
        ) == 1)
        #expect(try await count(
            """
            SELECT count(*) FROM memory_event_observations
            WHERE event_id = '\(renamed)' AND observation_kind = 'capture'
            """,
            in: destination
        ) > 0, "its samples follow it")
        #expect(try await count(
            "SELECT count(*) FROM memory_origin_events WHERE disposition = 'renamed'",
            in: destination
        ) == 1)
        #expect(try await count(concluded, in: destination) == concludedBefore + (onTheCall ? 1 : 0),
                "a duplicate call keeps its end; a renamed one is one more concluded call")
        #expect(try await destination.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        await destination.close()
    }

    @Test("a transfer stopped half way, as a process ending would, resumes from its mapping: nothing is taken twice")
    func stoppedTransferResumes() async throws {
        struct Stop: Error {}
        let place = try Self.place()
        try await Self.legacyArchive(in: place.profile("C"), stream: "mcp-C", elements: [W.format, W.save])
        let source = place.profile("C").appendingPathComponent("memory.sqlite")
        let sourceEvents = try Self.count("SELECT count(*) FROM memory_events", at: source)
        let destination = try await SQLiteMemoryStore.open(at: try temporaryArchive())
        await #expect(throws: Stop.self) {
            _ = try await SQLiteArchiveTransfer.transfer(
                from    : source,
                origin  : "mcp-profile:C",
                location: "MCP/Knowledge/C",
                into    : destination,
                staging : place.support.appendingPathComponent("staging"),
                nowMS   : 1,
                at      : { if $0 == .event(0) { throw Stop() } }
            )
        }
        #expect(try await destination.read {
            try $0.query("SELECT status FROM memory_archive_origins") { try $0.text(0) }
        } == ["failed"])
        let partial = try await count("SELECT count(*) FROM memory_events", in: destination)
        #expect(partial > 0 && partial < sourceEvents)
        #expect(!FileManager.default.fileExists(atPath: place.support.appendingPathComponent("staging").path),
                "no staging left behind")

        #expect(await SQLiteArchiveTransfer.needsTransfer(source: source, origin: "mcp-profile:C", into: destination))
        let report = try await SQLiteArchiveTransfer.transfer(
            from    : source,
            origin  : "mcp-profile:C",
            location: "MCP/Knowledge/C",
            into    : destination,
            staging : place.support.appendingPathComponent("staging"),
            nowMS   : 2
        )
        #expect(report.status == "completed")
        #expect(try await count("SELECT count(*) FROM memory_events", in: destination) == sourceEvents)
        #expect(try await count("SELECT count(*) FROM memory_origin_events", in: destination) == sourceEvents)
        #expect(!(await SQLiteArchiveTransfer.needsTransfer(
            source: source,
            origin: "mcp-profile:C",
            into  : destination
        )))
        await destination.close()
    }

    @Test("a client directory whose file is somebody else's database is refused and left as it is; the shared archive goes on")
    func foreignFileRefused() async throws {
        let place = try Self.place()
        let directory = place.profile("D")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let foreign = directory.appendingPathComponent("memory.sqlite")
        let raw = try SQLiteConnection(path: foreign.path)
        try raw.execute("CREATE TABLE somebody_elses (x INTEGER)")
        raw.close()
        let before = try Self.digest(foreign)
        let destination = try await SQLiteMemoryStore.open(at: try temporaryArchive())
        let report = try await SQLiteArchiveTransfer.transfer(
            from    : foreign,
            origin  : "mcp-profile:D",
            location: "MCP/Knowledge/D",
            into    : destination,
            staging : place.support.appendingPathComponent("staging"),
            nowMS   : 1
        )
        #expect(report.status == "refused" && report.detail?.contains("schema") == true)
        #expect(try Self.digest(foreign) == before)
        #expect(try await count("SELECT count(*) FROM memory_events", in: destination) == 0)
        await destination.close()
    }

    @Test("an archive that holds procedures and relations is refused whole and left as it is: a build that wrote them already shared the archive")
    @MainActor
    func learnedArchiveRefused() async throws {
        let place = try Self.place()
        let directory = place.profile("F")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = ProcedureLearningTests.photoSession(directory)
        let tools = ProcedureLearningTests.tools(session)
        _ = try await ProcedureLearningTests.task(tools, #"{"operation":"begin","goal":"Export the photo"}"#)
        try await ProcedureLearningTests.runPhotoExport(tools, session)
        _ = try await ProcedureLearningTests.task(tools, #"{"operation":"end","outcome":"completed"}"#)
        let memory = MemoryService.shared(for: directory)
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()
        MemoryService.forget(directory)
        let source = directory.appendingPathComponent("memory.sqlite")
        let before = try Self.digest(source)
        let destination = try await SQLiteMemoryStore.open(at: try temporaryArchive())
        let report = try await SQLiteArchiveTransfer.transfer(
            from    : source,
            origin  : "mcp-profile:F",
            location: "MCP/Knowledge/F",
            into    : destination,
            staging : place.support.appendingPathComponent("staging"),
            nowMS   : 1
        )
        #expect(report.status == "refused")
        for table in ["memory_procedure_candidates", "brain_relations", "brain_relation_evaluations"] {
            #expect(report.detail?.contains(table) == true, "\(report.detail ?? "")")
        }
        #expect(try Self.digest(source) == before)
        #expect(try await count("SELECT count(*) FROM memory_events", in: destination) == 0)
        await destination.close()
    }

    @Test("a write failure of the destination (as a full device answers) stops the transfer typed, the journal says failed, and it resumes")
    func destinationFailure() async throws {
        let place = try Self.place()
        try await Self.legacyArchive(in: place.profile("E"), stream: "mcp-E", elements: [W.format])
        let source = place.profile("E").appendingPathComponent("memory.sqlite")
        let destination = try await SQLiteMemoryStore.open(at: try temporaryArchive())
        let full = MemoryStoreError.failed(MemoryStoreFault(
            code   : .init(primary: 13, extended: 13),
            phase  : .commit,
            message: "database or disk is full"
        ))
        await #expect(throws: MemoryStoreError.self) {
            _ = try await SQLiteArchiveTransfer.transfer(
                from    : source,
                origin  : "mcp-profile:E",
                location: "MCP/Knowledge/E",
                into    : destination,
                staging : place.support.appendingPathComponent("staging"),
                nowMS   : 1,
                at      : { if $0 == .factsTransferred { throw full } }
            )
        }
        #expect(EssentialWriteFailure(full) == .storageFull(MemoryService.describe(full)),
                "a full device is told apart from contention")
        #expect(try await destination.read {
            try $0.query("SELECT status FROM memory_archive_origins") { try $0.text(0) }
        } == ["failed"])
        let report = try await SQLiteArchiveTransfer.transfer(
            from    : source,
            origin  : "mcp-profile:E",
            location: "MCP/Knowledge/E",
            into    : destination,
            staging : place.support.appendingPathComponent("staging"),
            nowMS   : 2
        )
        #expect(report.status == "completed")
        await destination.close()
    }

    @Test("two openers of the shared archive unify the same client at once: every source event is taken once")
    func twoOpenersUnifyOnce() async throws {
        let place = try Self.place()
        try await Self.legacyArchive(in: place.profile("F"), stream: "mcp-F", elements: [W.format, W.save])
        let source = place.profile("F").appendingPathComponent("memory.sqlite")
        let sourceEvents = try Self.count("SELECT count(*) FROM memory_events", at: source)
        let origins = KnowledgeLocation.legacyProfiles(under: place.support)
        MemoryService.unify(place.shared, with: origins)
        let first = MemoryService(directory: place.shared), second = MemoryService(directory: place.shared)
        async let a = first.ready()
        async let b = second.ready()
        _ = try await (a, b)
        await first.unificationFinished()
        await second.unificationFinished()
        let shared = first.url
        #expect(try Self.count("SELECT count(*) FROM memory_events", at: shared) == sourceEvents)
        #expect(try Self.count("SELECT count(*) FROM memory_origin_events", at: shared) == sourceEvents)
        await first.close()
        await second.close()
    }

    @Test("a client directory with only JSON Brains gives the shared archive, whole, the Brain of an application it has none of")
    func jsonOnlyOrigin() async throws {
        let place = try Self.place()
        let directory = place.profile("G")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Build the historical Brain independently of the active schema's frozen projection.
        let brain = W.legacyBrain([W.format, W.save])
        let knowledge = AppKnowledge(bundleID: "com.example.Other", brain: brain)
        try KnowledgeCoding.makeEncoder().encode(knowledge)
            .write(to: directory.appendingPathComponent("com.example.Other.json"))
        MemoryService.unify(place.shared, with: KnowledgeLocation.legacyProfiles(under: place.support))
        let memory = MemoryService(directory: place.shared)
        _ = try await memory.ready()
        await memory.unificationFinished()
        #expect(try await memory.brain(of: "com.example.Other") == nil)
        #expect(try rawRows("SELECT status || ':' || brains_imported FROM memory_archive_origins", at: memory.url)
                == ["completed:0"])
        await memory.close()
    }

    /// Writes `brain` as main's file store wrote an application's knowledge, in `directory`.
    static func writeJSON(_ brain: UIBrain, of bundleID: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try KnowledgeCoding.makeEncoder().encode(AppKnowledge(bundleID: bundleID, brain: brain))
            .write(to: directory.appendingPathComponent("\(bundleID).json"))
    }

    /// An anchor like `anchor` under a new identity and label.
    static func another(_ anchor: ObjectAnchor, label: String) -> ObjectAnchor {
        var copy = anchor
        copy.anchorKey = UUID().uuidString
        copy.label     = label
        copy.aliases   = []
        copy.groupID   = nil
        return copy
    }

    @Test("a JSON origin's Brain of an application the shared archive knows is merged by identity: the same anchor and transition kept with their counts, a new identity added though its label is one already here, each element journaled")
    func jsonMergeByIdentity() async throws {
        let place = try Self.place()
        try await Self.legacyArchive(in: place.shared, stream: "worker", elements: [W.open, W.save])
        let shared = MemoryService(directory: place.shared)
        _ = try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in Int64.max }) {
            try await shared.ready()
        }
        let here = try #require(try await shared.brain(of: W.bundle))
        await shared.close()
        let open = try #require(here.objects.first { $0.label == "Open" })
        let known = try #require(here.transitions.first)
        var same = open
        same.seenCount = open.seenCount + 40
        let secondSave = Self.another(open, label: "Save"), format = Self.another(open, label: "Format")
        var learned = known
        learned.anchorKey = secondSave.anchorKey
        learned.effect    = SceneEffect.menuOpened(labels: ["Save As", "Export"]).encoded
        var repeated = known
        repeated.evidence = known.evidence + 40
        try Self.writeJSON(UIBrain(objects: [same, secondSave, format], transitions: [repeated, learned]),
                           of: W.bundle, in: place.profile("H"))

        MemoryService.unify(place.shared, with: KnowledgeLocation.legacyProfiles(under: place.support))
        let memory = MemoryService(directory: place.shared)
        _ = try await memory.ready()
        await memory.unificationFinished()
        let merged = try #require(try await memory.brain(of: W.bundle))
        #expect(merged == here, "the historical projection is unchanged")
        let journal = try rawRows(
            """
            SELECT element_kind || ':' || disposition || ':' || count(*) FROM memory_origin_brain_contributions
            GROUP BY element_kind, disposition ORDER BY 1
            """,
            at: memory.url
        )
        #expect(journal.isEmpty)
        #expect(try rawRows("SELECT status || ':' || brains_imported FROM memory_archive_origins", at: memory.url)
                == ["completed:0"])
        await memory.close()
    }

    @Test("an element whose identity another application holds here is excluded: the origin is partial, never completed, the element named and left in its file; a second open merges nothing again")
    func jsonExclusionIsPartial() async throws {
        let place = try Self.place()
        try await Self.legacyArchive(in: place.shared, stream: "worker", elements: [W.open, W.save])
        let shared = MemoryService(directory: place.shared)
        _ = try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in Int64.max }) {
            try await shared.ready()
        }
        let here = try #require(try await shared.brain(of: W.bundle))
        await shared.close()
        let taken = try #require(here.objects.first)
        var collision = taken
        collision.label = "Elsewhere"
        let fresh = Self.another(taken, label: "Inspector")
        let directory = place.profile("I")
        try Self.writeJSON(UIBrain(objects: [collision, fresh]), of: "com.example.Other", in: directory)
        let file = directory.appendingPathComponent("com.example.Other.json")
        let before = try Self.digest(file)

        MemoryService.unify(place.shared, with: KnowledgeLocation.legacyProfiles(under: place.support))
        var memory = MemoryService(directory: place.shared)
        _ = try await memory.ready()
        await memory.unificationFinished()
        #expect(try await memory.brain(of: "com.example.Other") == nil)
        #expect(try await memory.brain(of: W.bundle)?.objects.count == here.objects.count,
                "the other Brain is unchanged")
        let origin = try rawRows(
            "SELECT status || ':' || ifnull(detail, '') FROM memory_archive_origins",
            at: memory.url
        )
        #expect(origin.count == 1 && origin[0].hasPrefix("completed:"), "\(origin)")
        #expect(try rawRows(
            "SELECT element_key FROM memory_origin_brain_contributions WHERE disposition = 'excluded'",
            at: memory.url
        ).isEmpty)
        #expect(try Self.digest(file) == before, "the excluded stays in the origin's file")
        await memory.close()

        MemoryService.unify(place.shared, with: KnowledgeLocation.legacyProfiles(under: place.support))
        memory = MemoryService(directory: place.shared)
        _ = try await memory.ready()
        await memory.unificationFinished()
        #expect(try rawRows("SELECT count(*) FROM memory_origin_brain_contributions", at: memory.url) == ["0"])
        #expect(try await memory.brain(of: "com.example.Other") == nil)
        await memory.close()
    }

    @Test("a JSON merge stopped between two applications, as a process ending would, resumes on the next open: what it added is not added twice, and the origin completes")
    func jsonMergeResumes() async throws {
        let place = try Self.place()
        try await Self.legacyArchive(in: place.shared, stream: "worker", elements: [W.open])
        let shared = MemoryService(directory: place.shared)
        _ = try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in Int64.max }) {
            try await shared.ready()
        }
        let seed = try #require(try await shared.brain(of: W.bundle)?.objects.first)
        await shared.close()
        let directory = place.profile("J")
        let first  = UIBrain(objects: [Self.another(seed, label: "Alpha"), Self.another(seed, label: "Beta")])
        let second = UIBrain(objects: [Self.another(seed, label: "Gamma")])
        try Self.writeJSON(first, of: "com.example.First", in: directory)
        try Self.writeJSON(second, of: "com.example.Second", in: directory)
        // The first application's transaction committed, then the process ended.
        let store = try await SQLiteMemoryStore.open(at: place.shared.appendingPathComponent("memory.sqlite"))
        try await SQLiteArchiveTransfer.beginJSONOnly(
            store,
            origin  : "mcp-profile:J",
            location: "MCP/Knowledge/J",
            nowMS   : 1
        )
        _ = try await JSONBrainImport.merge(
            [AppKnowledge(bundleID: "com.example.First", brain: first)],
            into  : SQLiteBrainRepository(store: store),
            origin: "mcp-profile:J",
            now   : Date()
        )
        await store.close()
        let archive = place.shared.appendingPathComponent("memory.sqlite")
        #expect(try rawRows("SELECT status FROM memory_archive_origins", at: archive) == ["in_progress"])

        MemoryService.unify(place.shared, with: KnowledgeLocation.legacyProfiles(under: place.support))
        let memory = MemoryService(directory: place.shared)
        _ = try await memory.ready()
        await memory.unificationFinished()
        #expect(try await memory.brain(of: "com.example.First") == nil)
        #expect(try await memory.brain(of: "com.example.Second") == nil)
        #expect(try rawRows(
            """
            SELECT bundle_id || ':' || disposition FROM memory_origin_brain_contributions
            ORDER BY bundle_id, element_key
            """,
            at: memory.url
        ).isEmpty, "a frozen import adds no contribution rows")
        #expect(try rawRows("SELECT status || ':' || brains_imported FROM memory_archive_origins", at: memory.url)
                == ["completed:0"])
        await memory.close()
    }

    static let token = "sk-brausReviewSynthetic0000123456789"

    @Test("review F02c: an earlier archive's credential in an argument, a sample's label, a result's message and an effect's labels comes into the shared archive withheld, each gap declared; the earlier file is only read")
    func transferAdmitsAsLive() async throws {
        let place = try Self.place()
        try await Self.legacyArchive(in: place.profile("K"), stream: "mcp-K", elements: [W.format, W.save])
        let legacy = place.profile("K").appendingPathComponent("memory.sqlite")
        // As a build before G76 could have written them: no minimization at all.
        try rawEdit(legacy) { raw in
            let token = SQLiteValue.text(Self.token)
            _ = try raw.run(
                """
                UPDATE memory_operation_arguments SET text_value = text_value || ' ' || ?
                WHERE argument_name = 'target'
                """,
                [token]
            )
            _ = try raw.run(
                """
                UPDATE memory_event_observations SET label = label || ' ' || ?
                WHERE label = 'Save'
                """,
                [token]
            )
            _ = try raw.run(
                """
                UPDATE memory_agent_actions SET result_message = result_message || ' ' || ?
                WHERE result_message IS NOT NULL
                """,
                [token]
            )
            _ = try raw.run(
                """
                UPDATE memory_agent_action_effect_labels SET label = label || ' ' || ?
                WHERE label = 'Bold'
                """,
                [token]
            )
        }
        #expect(try !archiveOccurrences(of: Self.token, in: legacy).isEmpty, "the earlier archive holds the credential")
        let before = try Self.digest(legacy)

        MemoryService.unify(place.shared, with: KnowledgeLocation.legacyProfiles(under: place.support))
        let memory = MemoryService(directory: place.shared)
        _ = try await memory.ready()
        await memory.unificationFinished()
        let status = await memory.status()
        #expect(status.lastUnification?.contains("MCP/Knowledge/K: completed") == true,
                "\(status.lastUnification ?? "")")
        #expect(await memory.flush(within: .seconds(10)))
        await memory.close()
        #expect(try archiveOccurrences(of: Self.token, in: memory.url).isEmpty)
        let gaps = Set(try rawRows("SELECT location_kind FROM memory_value_redactions", at: memory.url))
        #expect(gaps.isSuperset(of: ["argument", "sample_label", "result_message", "observed_effect"]), "\(gaps)")
        #expect(try rawRows("SELECT label FROM memory_agent_action_effect_labels ORDER BY position", at: memory.url)
            == ["Bold [withheld]", "Italic", "Underline"], "the effect keeps its other labels")
        #expect(try Self.digest(legacy) == before, "the earlier archive is only read")
    }

    @Test("review F02c: a JSON origin's credential is withheld from a merged anchor and a transition holding one is left out, both journaled as withheld without the value; the origin is partial")
    func jsonMergeAdmitsAsLive() async throws {
        let place = try Self.place()
        try await Self.legacyArchive(in: place.shared, stream: "worker", elements: [W.open])
        let shared = MemoryService(directory: place.shared)
        _ = try await SQLiteMemoryStore.$migrationAvailableSpace.withValue({ _ in Int64.max }) {
            try await shared.ready()
        }
        let seed = try #require(try await shared.brain(of: W.bundle)?.objects.first)
        await shared.close()
        let keyed = Self.another(seed, label: "Key \(Self.token)")
        let paste = LearnedTransition(anchorKey: keyed.anchorKey, trigger: .click,
                                      effect: SceneEffect.menuOpened(labels: ["Paste \(Self.token)"]).encoded,
                                      evidence: 2, lastObserved: seed.lastSeen)
        try Self.writeJSON(UIBrain(objects: [keyed], transitions: [paste]), of: W.bundle, in: place.profile("L"))

        MemoryService.unify(place.shared, with: KnowledgeLocation.legacyProfiles(under: place.support))
        let memory = MemoryService(directory: place.shared)
        _ = try await memory.ready()
        await memory.unificationFinished()
        let merged = try #require(try await memory.brain(of: W.bundle))
        #expect(merged.objects.map(\.label) == ["Open"])
        #expect(merged.transitions.allSatisfy { $0.anchorKey != keyed.anchorKey }, "no transition predicts the marker")
        await memory.close()
        #expect(try archiveOccurrences(of: Self.token, in: memory.url).isEmpty)
        #expect(try rawRows(
            """
            SELECT element_kind || ':' || disposition || ':' || withheld FROM memory_origin_brain_contributions
            ORDER BY element_kind
            """,
            at: memory.url
        ).isEmpty)
        #expect(try rawRows("SELECT status FROM memory_archive_origins", at: memory.url) == ["completed"])
    }

    private func temporaryArchive() throws -> URL {
        let directory = Scratch.directory("unification-destination")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("memory.sqlite")
    }

    private func count(_ sql: String, in store: SQLiteMemoryStore) async throws -> Int64 {
        try await store.read { try $0.query(sql) { $0.integer(0) ?? -1 }.first ?? -1 }
    }
}
