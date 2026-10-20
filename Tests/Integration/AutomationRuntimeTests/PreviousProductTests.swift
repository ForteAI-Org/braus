//
//  PreviousProductTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// PreviousProductTests prove the continuity of the knowledge the product kept under its earlier name into the user's
/// one archive of Braus, on folders of their own: never the person's. The earlier folder is only read, and only when
/// `BRAUS_PREVIOUS_SUPPORT_DIR` names it (`KnowledgeLocation.previousSupport`). Its archive is adopted whole
/// where Braus has none yet (a consistent copy through the backup API, then the migration of its shape); its JSON Brains,
/// and an archive found beside one Braus already has, are taken in by the unification's transfer, journaled under the
/// origin `previous_product`, once. An archive the transfer does not carry is refused whole, untouched, and said.
@MainActor
@Suite("The knowledge of the product's earlier name, adopted or taken in once, its folder only read", .serialized)
struct PreviousProductTests {
    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests
    typealias U = UnificationTests
    typealias H = HistoricalArchiveTests

    /// A support folder of Braus and one of the earlier name, both new and empty.
    struct Folders {
        let support: URL
        let previous: URL
        var knowledge: URL { KnowledgeLocation.knowledge(under: support) }
        var earlier: URL { KnowledgeLocation.knowledge(under: previous) }
        var environment: [String: String] {
            [KnowledgeLocation.supportOverride: support.path, KnowledgeLocation.previousSupportOverride: previous.path]
        }
        /// The origins a frontend registers for the knowledge directory, as the app and `braus` do.
        func register() {
            MemoryService.unify(knowledge, with: KnowledgeLocation.legacyProfiles(under: support)
                                    + KnowledgeLocation.previousProductOrigins(environment: environment))
        }
    }

    static func folders() throws -> Folders {
        let root = try W.directory()
        let folders = Folders(support: root.appendingPathComponent("Braus", isDirectory: true),
                              previous: root.appendingPathComponent("Earlier", isDirectory: true))
        try FileManager.default.createDirectory(at: folders.support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folders.previous, withIntermediateDirectories: true)
        return folders
    }

    /// The photo export learned through the tools, its archive brought to the D3 build's shape and closed in `knowledge`.
    static func earlierArchive(learnedInto knowledge: URL) async throws -> String {
        let (session, url, routeID) = try await H.learned()
        _ = try H.convert(url, to: try H.dThreeSeven(), version: 7)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.copyItem(atPath: url.path + suffix, toPath: knowledge.appendingPathComponent("memory.sqlite" + suffix).path)
        }
        _ = session
        return routeID
    }

    /// The data files of a folder with their sha256: what reading it must leave as it was. The WAL index (`-shm`), which
    /// every SQLite reader marks, and the presence lock (`.lock`), which every build since main takes before reading an
    /// archive, are coordination, not data: a lock left behind must be empty (`emptyLocks`).
    static func files(_ folder: URL) throws -> [String: String] {
        var found: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where !name.hasSuffix("-shm") && !name.hasSuffix(".lock") {
            let file = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            found[name] = try U.digest(file)
        }
        return found
    }

    /// Whether every presence lock in the folder is empty: the coordination file a read leaves, holding nothing.
    static func emptyLocks(_ folder: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".lock") }.allSatisfy {
            (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.size] as? Int) == 0
        }
    }

    static func open(_ folders: Folders) async throws -> MemoryService {
        folders.register()
        let memory = MemoryService.shared(for: folders.knowledge)
        RecallService.install(RecallService(memory: memory, configuration: L.configuration()))
        _ = try await memory.ready()
        await memory.unificationFinished()
        return memory
    }

    static func close(_ folders: Folders) async {
        let memory = MemoryService.shared(for: folders.knowledge)
        RecallService.forget(memory)
        await memory.close()
        MemoryService.forget(folders.knowledge)
    }

    // MARK: Which folder

    @Test("only a folder named is read as the earlier name's: none by default, none for a moved support folder")
    func isolation() throws {
        #expect(KnowledgeLocation.previousSupport(environment: [KnowledgeLocation.supportOverride: "/private/tmp/braus-live/AppSupport"]) == nil)
        #expect(KnowledgeLocation.previousProductOrigins(environment: [KnowledgeLocation.supportOverride: "/private/tmp/braus-live/AppSupport"]).isEmpty)
        #expect(KnowledgeLocation.previousSupport(environment: [KnowledgeLocation.previousSupportOverride: ""]) == nil)
        #expect(KnowledgeLocation.previousSupport(environment: [KnowledgeLocation.previousSupportOverride: "/tmp/Old"])?.path == "/tmp/Old")
        #expect(KnowledgeLocation.previousSupport(environment: [:]) == nil, "no folder of the person's is read unless one is named")
        #expect(KnowledgeLocation.previousProductOrigins(environment: [:]).isEmpty)
        // The support folder itself is never its own earlier name.
        let same = "/private/tmp/same-support"
        #expect(KnowledgeLocation.previousProductOrigins(environment: [KnowledgeLocation.supportOverride: same,
                                                                       KnowledgeLocation.previousSupportOverride: same]).isEmpty)
    }

    // MARK: Cases

    @Test("the earlier name's archive only: adopted whole where Braus has none, migrated, journaled once; its procedure is proposed; the earlier folder is unchanged; reopening adopts nothing again")
    func adoptsTheEarlierArchive() async throws {
        let folders = try Self.folders()
        let routeID = try await Self.earlierArchive(learnedInto: folders.earlier)
        let earlierFiles = try Self.files(folders.earlier)
        let earlierEvents = try U.count("SELECT count(*) FROM memory_events", at: folders.earlier.appendingPathComponent("memory.sqlite"))

        let memory = try await Self.open(folders)
        let status = await memory.status()
        #expect(status.lastUnification?.contains("Earlier/Knowledge: adopted whole") == true, "\(status.lastUnification ?? "")")
        #expect(status.lastMigration?.contains("from schema d3-7 to \(SQLiteMemorySchema.version)") == true, "\(status.lastMigration ?? "")")
        let url = memory.url
        #expect(try U.count("SELECT count(*) FROM memory_events", at: url) == earlierEvents)
        #expect(try rawRows("SELECT origin_id || ':' || origin_kind || ':' || status || ':' || location FROM memory_archive_origins", at: url)
                == ["previous-product:knowledge:previous_product:completed:Earlier/Knowledge"])
        #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(60)))
        let session = P.photoSession(folders.knowledge)
        let proposal = try await P.task(P.tools(session, stream: "after-rename"), RecallChoiceToolTests.proposeRequest)["recall_proposal"]
        #expect(proposal["sources"].array?.contains { $0["version"].string == routeID } == true, "\(proposal)")
        await Self.close(folders)
        let readBack = try Self.files(folders.earlier)
        #expect(try Self.emptyLocks(folders.earlier))
        #expect(readBack == earlierFiles, "the earlier folder is only read: \(readBack.filter { earlierFiles[$0.key] != $0.value }.keys.sorted()) \(Set(readBack.keys).symmetricDifference(earlierFiles.keys))")

        // Reopened: nothing adopted or taken in again.
        let again = try await Self.open(folders)
        #expect(try rawRows("SELECT count(*) FROM memory_archive_origins", at: again.url) == ["1"])
        #expect(try U.count("SELECT count(*) FROM memory_origin_events", at: again.url) == 0)
        #expect(try U.count("SELECT count(*) FROM memory_events", at: again.url) >= earlierEvents)
        await Self.close(folders)
    }

    @Test("the earlier name's JSON Brains only: merged once into the new archive, journaled as the earlier name's; reopening merges nothing again")
    func takesTheJSONBrains() async throws {
        let folders = try Self.folders()
        let scratch = try W.service()
        let window = W.window([W.format, W.save])
        var scene = window.scene
        scene.bundleID = "com.example.Earlier"
        _ = await CallRecorder(memory: scratch, brain: W.brain(scratch), context: ActionContext(source: .app, streamID: "w"))
            .observe(PerceivedWindow(scene: scene, frame: window.frame, capture: window.capture, surface: window.surface))
        #expect(await scratch.flush(within: .seconds(10)))
        let brain = try #require(try await scratch.brain(of: "com.example.Earlier"))
        await scratch.close()
        try U.writeJSON(brain, of: "com.example.Earlier", in: folders.earlier)
        let earlierFiles = try Self.files(folders.earlier)

        let memory = try await Self.open(folders)
        #expect(try await memory.brain(of: "com.example.Earlier")?.objects.count == 2)
        #expect(try rawRows("SELECT origin_kind || ':' || status || ':' || brains_imported FROM memory_archive_origins", at: memory.url)
                == ["previous_product:completed:1"])
        await Self.close(folders)
        let again = try await Self.open(folders)
        #expect(try rawRows("SELECT count(*) || ':' || sum(brains_imported) FROM memory_archive_origins", at: again.url) == ["1:1"])
        #expect(try await again.brain(of: "com.example.Earlier")?.objects.count == 2, "merged once")
        await Self.close(folders)
        #expect(try Self.files(folders.earlier) == earlierFiles)
    }

    @Test("Braus's archive only: nothing of the earlier name exists, nothing is journaled")
    func nothingEarlier() async throws {
        let folders = try Self.folders()
        try FileManager.default.removeItem(at: folders.previous)
        let memory = try await Self.open(folders)
        #expect(try rawRows("SELECT count(*) FROM memory_archive_origins", at: memory.url) == ["0"])
        #expect((await memory.status()).lastUnification == nil)
        await Self.close(folders)
    }

    @Test("both archives, the earlier one of facts: taken in by transfer with every event's source, Braus's own kept; once")
    func bothWithFacts() async throws {
        let folders = try Self.folders()
        try await U.legacyArchive(in: folders.earlier, stream: "earlier-app", elements: [W.format, W.save])
        let earlier = folders.earlier.appendingPathComponent("memory.sqlite")
        let earlierEvents = try U.count("SELECT count(*) FROM memory_events", at: earlier)
        let earlierFiles = try Self.files(folders.earlier)
        // Braus already has its own archive with its own facts.
        let own = MemoryService.shared(for: folders.knowledge)
        _ = await CallRecorder(memory: own, brain: W.brain(own), context: ActionContext(source: .app, streamID: "braus"))
            .observe(W.window([W.open]))
        #expect(await own.flush(within: .seconds(10)))
        await own.close()
        MemoryService.forget(folders.knowledge)
        let ownEvents = try U.count("SELECT count(*) FROM memory_events", at: folders.knowledge.appendingPathComponent("memory.sqlite"))

        let memory = try await Self.open(folders)
        let url = memory.url
        #expect(try U.count("SELECT count(*) FROM memory_events", at: url) == ownEvents + earlierEvents)
        #expect(try U.count("SELECT count(*) FROM memory_origin_events WHERE origin_id = 'previous-product:knowledge'", at: url) == earlierEvents)
        #expect(try rawRows("SELECT origin_kind || ':' || status FROM memory_archive_origins", at: url) == ["previous_product:completed"])
        await Self.close(folders)
        let again = try await Self.open(folders)
        #expect(try U.count("SELECT count(*) FROM memory_events", at: again.url) == ownEvents + earlierEvents, "taken in once")
        await Self.close(folders)
        #expect(try Self.files(folders.earlier) == earlierFiles)
    }

    @Test("both archives, the earlier one with tasks and procedures: refused whole and said, nothing of it half merged, both archives as they were")
    func bothWithProcedures() async throws {
        let folders = try Self.folders()
        _ = try await Self.earlierArchive(learnedInto: folders.earlier)
        let earlierFiles = try Self.files(folders.earlier)
        let own = MemoryService.shared(for: folders.knowledge)
        _ = await CallRecorder(memory: own, brain: W.brain(own), context: ActionContext(source: .app, streamID: "braus"))
            .observe(W.window([W.open]))
        #expect(await own.flush(within: .seconds(10)))
        await own.close()
        MemoryService.forget(folders.knowledge)
        let ownEvents = try U.count("SELECT count(*) FROM memory_events", at: folders.knowledge.appendingPathComponent("memory.sqlite"))

        let memory = try await Self.open(folders)
        let url = memory.url
        #expect(try U.count("SELECT count(*) FROM memory_events", at: url) == ownEvents, "nothing half merged")
        let journal = try rawRows("SELECT origin_kind || ':' || status || ':' || ifnull(detail, '') FROM memory_archive_origins", at: url)
        #expect(journal.count == 1 && journal[0].hasPrefix("previous_product:refused:") && journal[0].contains("memory_tasks"), "\(journal)")
        #expect((await memory.status()).lastUnification?.contains("Earlier/Knowledge: refused") == true)
        await Self.close(folders)
        let readBack = try Self.files(folders.earlier)
        #expect(try Self.emptyLocks(folders.earlier))
        #expect(readBack == earlierFiles, "the earlier archive is left as it is: \(readBack.filter { earlierFiles[$0.key] != $0.value }.keys.sorted()) \(Set(readBack.keys).symmetricDifference(earlierFiles.keys))")
    }

    @Test("a process that stopped after the adoption's copy, before its record: the next open takes the source in by transfer, each event recognized as already here, none twice")
    func adoptionStoppedBeforeItsRecord() async throws {
        let folders = try Self.folders()
        try await U.legacyArchive(in: folders.earlier, stream: "earlier-app", elements: [W.format, W.save])
        let earlier = folders.earlier.appendingPathComponent("memory.sqlite")
        let earlierEvents = try U.count("SELECT count(*) FROM memory_events", at: earlier)
        try FileManager.default.createDirectory(at: folders.knowledge, withIntermediateDirectories: true)
        #expect(try await SQLiteArchiveTransfer.adopt(earlier, as: folders.knowledge.appendingPathComponent("memory.sqlite")))

        let memory = try await Self.open(folders)
        let url = memory.url
        #expect(try U.count("SELECT count(*) FROM memory_events", at: url) == earlierEvents, "no event twice")
        #expect(try rawRows("SELECT status || ':' || events_added || ':' || events_duplicate FROM memory_archive_origins", at: url)
                == ["completed:0:\(earlierEvents)"])
        await Self.close(folders)
    }
}
