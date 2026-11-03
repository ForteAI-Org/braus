import EngineCore
import Foundation
import Memory
import Testing
@testable import SQLiteMemory

@Suite("Scene and graph storage on schema 22", .serialized)
struct DB2CSceneTests {
    @Test func structuralSceneKeepsItsPublicIdentityAndSkeleton() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        let window = SceneFixtures.perceive(SceneFixtures.window("Inbox", [SceneFixtures.button("Compose", y: 700)]))
        let sample = SceneFixtures.sample("sample", of: window)
        let skeleton = SceneSkeleton(sample: sample)
        try await store.write { transaction in
            let app = try SQLiteIdentityRows.ensureApp(transaction, bundleID: SceneFixtures.app.bundleID)
            try SQLiteSceneRows.insertScene(transaction, sceneID: "scene", appID: app, sample: sample,
                                            skeleton: skeleton, nowMS: SceneFixtures.t0)
        }
        let scenes = try await SQLiteSceneRepository(store: store).scenes(of: SceneFixtures.app.bundleID)
        #expect(scenes.count == 1)
        #expect(scenes.first?.id == "scene")
        #expect(scenes.first?.skeleton == skeleton)
        let elements = try await SQLiteBrainGraphRepository(store: store).elements(ofScene: "scene")
        #expect(elements.count == 1)
        #expect(elements.first?.label == "Compose")
        #expect(try await store.read { try SchemaCoherence.check($0) }.isEmpty)
        await store.close()
    }

    @Test func arcsReportFrozenWithoutWriting() async throws {
        let store = SQLiteMemoryStore(url: try temporaryDatabase(), schema: .version22)
        try await store.open()
        let arc = try BrainArc(transitionID: "producer-arc", bundleID: "com.example.Editor", fromSceneID: "scene",
            trigger: .menu(menuCommandID: "1"), toSceneID: nil, effect: TransitionEffectRecord(effect: "menuOpened:Save"),
            status: .candidate, evidenceCount: 0, firstSeenMS: SceneFixtures.t0, lastSeenMS: SceneFixtures.t0)
        let graph = SQLiteBrainGraphRepository(store: store)
        let result = try await graph.recordResult(arc)
        if case .frozen = result {} else { Issue.record("expected frozen arc") }
        #expect(try await graph.record(arc) == .alreadyApplied)
        let update = try await graph.updateResult(from: arc, to: arc)
        if case .frozen = update {} else { Issue.record("expected frozen arc update") }
        #expect(try await graph.update(from: arc, to: arc) == .alreadyApplied)
        #expect(try await store.read { try $0.query("SELECT count(*) FROM brain_transitions") { $0.integer(0) }.first ?? nil } == 0)
        await store.close()
    }
    @Test func associatesAMigratedCaptureWithoutAnotherCaptureWrite() async throws {
        let memory = try await SceneFixtures.open()
        let window = SceneFixtures.perceive(SceneFixtures.window("Inbox", [SceneFixtures.button("Compose", y: 700)]))
        _ = try await memory.captures.record(SceneFixtures.event("event", at: SceneFixtures.t0))
        let sample = SceneFixtures.sample("event", of: window)
        _ = try await memory.captures.record(sample)
        _ = try await SQLiteBrainRepository(store: memory.store).observe(window.scene, now: Date(timeIntervalSince1970: 1_700_000_000))
        await memory.store.close()
        let target = URL(fileURLWithPath: memory.url.path + ".migrating-22-c")
        _ = try await SQLiteMigration22.build(from: memory.url, shape: .unified19, into: target,
                                              availableSpace: { _ in Int64.max }, progress: { _ in })
        let store = SQLiteMemoryStore(url: target, schema: .version22)
        try await store.open()
        let scenes = SQLiteSceneRepository(store: store, makeSceneID: { "scene" })
        let first = try await scenes.associate(sample.key, at: SceneFixtures.t0)
        #expect(first.createdSceneID == "scene")
        #expect(try await scenes.associate(sample.key, at: SceneFixtures.t0).receipt == .alreadyApplied)
        #expect(try await scenes.scenes(of: SceneFixtures.app.bundleID).first?.skeleton == SceneSkeleton(sample: sample))
        let graph = SQLiteBrainGraphRepository(store: store)
        let element = try #require(try await graph.elements(ofScene: "scene").first)
        let anchor = try #require(try await SQLiteBrainRepository(store: store).brain(of: SceneFixtures.app.bundleID)?.objects.first)
        #expect(try await graph.link(element: element.sceneElementID, toAnchor: anchor.anchorKey) == .committed)
        let evidence = try BrainEvidenceRecord(bundleID: SceneFixtures.app.bundleID, eventID: "event", target: .scene("scene"),
            relation: .supports, assessedBy: "test", assessmentVersion: "1", assessedAtMS: SceneFixtures.t0)
        #expect(try await graph.record(evidence) == .committed)
        #expect(try await graph.evidence(ofEvent: "event").first?.isExactly(evidence) == true)

        #expect(try await store.read { try SchemaCoherence.check($0) }.isEmpty)
        await store.close()
    }

}
