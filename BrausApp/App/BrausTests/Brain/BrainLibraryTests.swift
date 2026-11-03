import AutomationRuntime
import Foundation
import Memory
import SQLiteMemory
import PerceptionCore
import Testing
@testable import Braus

@Suite("Brain library loading")
@MainActor
struct BrainLibraryTests {
    @Test func listDoesNotLoadBrains() async {
        var listReads = 0
        let content = BrainAppContent()
        let state = await BrainLibrary.apps {
            listReads += 1
            return ["test.brain.z", "test.brain.a"]
        }
        guard case .loaded(let apps) = state else {
            Issue.record("The application list was unavailable")
            return
        }
        #expect(listReads == 1)
        #expect(apps.map(\.bundleID) == ["test.brain.a", "test.brain.z"])
        #expect(content.brain == nil)
    }

    @Test func cancellationAllowsReload() async {
        let content = BrainAppContent()
        await content.load(bundleID: "test.brain") { _ in throw CancellationError() }
        #expect(content.unavailable == nil)
        await content.load(bundleID: "test.brain") { _ in UIBrain() }
        #expect(content.brain != nil)
    }

    @Test func absentBrainIsEmptyWithoutAnError() async {
        let content = BrainAppContent()
        await content.load(bundleID: "test.brain") { _ in nil }
        #expect(content.unavailable == nil)
        #expect(content.isEmpty)
    }

    @Test func brainLoadedOnOpen() async {
        let content = BrainAppContent()
        var reads: [String] = []
        #expect(reads.isEmpty)
        for _ in 0..<2 {
            await content.load(bundleID: "test.brain") { bundleID in
                reads.append(bundleID)
                return UIBrain()
            }
        }
        #expect(reads == ["test.brain"])
        #expect(content.brain != nil)
    }

    @Test func sameBrainShown() async throws {
        let date = Date(timeIntervalSince1970: 100)
        let anchor = ObjectAnchor(
            anchorKey: "open-control",
            kind: .control,
            label: "Open",
            boundsTypical: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1),
            firstSeen: date,
            lastSeen: date
        )
        let original = UIBrain(
            objects: [anchor],
            groups: [SiblingGroup(
                axis: .column,
                memberAnchors: [anchor.anchorKey],
                sharedKind: .control,
                cellSize: NormalizedSize(width: 0.1, height: 0.1),
                lastSeen: date
            )],
            transitions: [LearnedTransition(
                anchorKey: anchor.anchorKey,
                trigger: .click,
                effect: "menuOpened:File",
                lastObserved: date
            )]
        )
        let content = BrainAppContent()
        await content.load(bundleID: "test.brain") { _ in original }
        let shown = try #require(content.brain)
        #expect(shown == original)
        #expect(content.list?.brain == original)
    }

    @Test func storedApplications() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = MemoryService(directory: directory)
        do {
            #expect(try await service.brainApplications().isEmpty)
            let brain = UIBrain(objects: [ObjectAnchor(
                kind: .control,
                label: "Open",
                boundsTypical: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1),
                firstSeen: Date(timeIntervalSince1970: 100),
                lastSeen: Date(timeIntervalSince1970: 100)
            )])
            await service.enqueue("Import test Brain") { repositories in
                _ = try await repositories.brains.importProjection(brain, into: "test.brain", now: Date())
            }
            #expect(await service.flush(within: .seconds(10)))
            #expect(await service.status().failed == 0)
            #expect(try await service.brainApplications() == ["test.brain"])
            let expected = try #require(try await service.brain(of: "test.brain"))
            let content = BrainAppContent()
            await content.load(bundleID: "test.brain") { try await service.brain(of: $0) }
            #expect(content.brain == expected)
        } catch {
            await service.close()
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        await service.close()
        try FileManager.default.removeItem(at: directory)
    }
}
