//
//  BrainImportTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// The manual import of an earlier JSON Knowledge directory: a Brain the file holds becomes the
/// application's projection, read back as it was, and an application the memory already knows is
/// left alone.
@Suite("Importing an earlier JSON Brain into the memory")
struct BrainImportTests {

    private func brain() -> UIBrain {
        var brain = UIBrain()
        let elements = ["Open", "Save", "Export"].enumerated().map { index, label in
            SceneElement(id: "control|\(label)", kind: .control, label: label,
                         bounds: NormalizedRect(x: 0.1 + Double(index) * 0.2, y: 0.1, width: 0.08, height: 0.04),
                         role: "AXButton")
        }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        _ = BrainUpdater.ingest(elements.map(BrainDetection.init), into: &brain, now: now, window: "document")
        _ = BrainUpdater.ingest(elements.map(BrainDetection.init), into: &brain, now: now.addingTimeInterval(60), window: "document")
        let save = brain.objects.first { $0.label == "Save" }!
        _ = BrainUpdater.recordTransition(anchorKey: save.anchorKey, trigger: .click,
                                          effect: SceneEffect.windowTitleChanged(title: "Save As").encoded,
                                          into: &brain, now: now.addingTimeInterval(61))
        return brain
    }

    @Test("a Brain from a JSON file becomes the projection and reads back with its anchors, groups and transitions", arguments: [false, true])
    func importsOnce(schema22: Bool) async throws {
        let url = try temporaryDatabase()
        let store = schema22 ? SQLiteMemoryStore(url: url, schema: .version22) : SQLiteMemoryStore(url: url, schema: .historical19)
        try await store.open()
        let brains  = SQLiteBrainRepository(store: store)
        let earlier = brain()
        let now     = Date(timeIntervalSince1970: 1_790_000_100)
        if schema22 {
            let result = try await brains.importProjectionResult(earlier, into: "com.example.Editor", now: now)
            if case .frozen = result {} else { Issue.record("expected frozen projection") }
            #expect(try await brains.importProjection(earlier, into: "com.example.Editor", now: now) == false)
            #expect(try await store.read { try $0.query("SELECT count(*) FROM brain_anchors") { $0.integer(0) }.first ?? nil } == 0)
            await store.close()
            return
        }
        #expect(try await brains.importProjection(earlier, into: "com.example.Editor", now: now))
        let read = try #require(try await brains.brain(of: "com.example.Editor"))
        #expect(Set(read.objects.map(\.label)) == Set(earlier.objects.map(\.label)))
        #expect(read.objects.map(\.seenCount).sorted() == earlier.objects.map(\.seenCount).sorted())
        #expect(read.transitions.map(\.effect) == earlier.transitions.map(\.effect))
        #expect(read.groups.count == earlier.groups.count)
        #expect(try await brains.importProjection(UIBrain(), into: "com.example.Editor", now: now) == false,
                "an application the memory already knows keeps its Brain")
        #expect(try await store.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        await store.close()
    }
    @Test func readsFrozenHistory() async throws {
        let source = try temporaryDatabase()
        let old = SQLiteMemoryStore(url: source, schema: .historical19)
        try await old.open()
        let earlier = brain()
        let bundle = "com.example.Editor"
        _ = try await SQLiteBrainRepository(store: old).importProjection(earlier, into: bundle, now: Date(timeIntervalSince1970: 1_790_000_100))
        await old.close()
        let target = URL(fileURLWithPath: source.path + ".migrating-22-c")
        _ = try await SQLiteMigration22.build(from: source, shape: .unified19, into: target,
                                              availableSpace: { _ in Int64.max }, progress: { _ in })
        let store = SQLiteMemoryStore(url: target, schema: .version22)
        try await store.open()
        let read = try #require(try await SQLiteBrainRepository(store: store).brain(of: bundle))
        let anchorIDs = Dictionary(uniqueKeysWithValues: zip(earlier.objects, read.objects).map { ($0.anchorKey, $1.anchorKey) })
        let groupIDs = Dictionary(uniqueKeysWithValues: zip(earlier.groups, read.groups).map { ($0.id, $1.id) })
        var expected = earlier
        for index in expected.objects.indices {
            expected.objects[index].anchorKey = try #require(anchorIDs[expected.objects[index].anchorKey])
            expected.objects[index].groupID = expected.objects[index].groupID.flatMap { groupIDs[$0] }
        }
        for index in expected.groups.indices {
            expected.groups[index].id = try #require(groupIDs[expected.groups[index].id])
            expected.groups[index].memberAnchors = try expected.groups[index].memberAnchors.map { try #require(anchorIDs[$0]) }
        }
        for index in expected.transitions.indices {
            expected.transitions[index].anchorKey = try #require(anchorIDs[expected.transitions[index].anchorKey])
        }
        #expect(read.objects == expected.objects)
        #expect(read.groups == expected.groups)
        #expect(read.transitions == expected.transitions)
        await store.close()
    }

}
