import AutomationRuntime
import EngineCore
import Foundation
import Memory
import SQLiteMemory
import PerceptionCore
import Testing
@testable import Braus

@Suite("Brain library loading")
@MainActor
struct BrainLibraryTests {
    @Test func currentSceneWithoutNamingAnchorsIsVisible() async throws {
        let scene = SceneDefinition(
            id: "scene", bundleID: "test.brain", surface: .window,
            titleBucket: "Document", structuralKey: nil, firstSeenMS: 1000,
            lastSeenMS: 1000, observationCount: 1,
            skeleton: SceneSkeleton(surface: .window, rolesByPath: [:], captionsByPath: [:], collections: [])
        )
        func element(_ id: String, parent: String?) -> SceneElementRecord {
            SceneElementRecord(
                sceneElementID: id, sceneID: scene.id, elementKey: id,
                scope: parent == nil ? .container : .control, parentElementID: parent,
                edgeHash: nil, cursorAffordance: nil, anchorID: nil,
                label: id, labelOrigin: nil, role: nil, kind: "control", source: nil,
                bounds: nil, firstSeenMS: 1000, lastSeenMS: 1000, observationCount: 1
            )
        }
        let saved = StoredBrain(
            bundleID: "test.brain", projection: UIBrain(), scenes: [scene],
            elements: [element("container", parent: nil), element("button", parent: "container")]
        )
        let content = BrainAppContent()
        await content.loadStored(bundleID: "test.brain") { _ in nil }
        #expect(content.isEmpty)
        content.reset()
        await content.loadStored(bundleID: "test.brain") { _ in saved }
        #expect(!content.isEmpty)
        #expect(content.stored?.scenes.count == 1)
        #expect(content.brain?.objects.isEmpty == true)
        let graph = BrainGraph(stored: saved)
        #expect(Set(graph.nodes.map(\.id)) == ["scene:scene", "element:container", "element:button"])
        #expect(graph.edges.contains { $0.from == "element:container" && $0.to == "element:button" })
        #expect(graph.nodes[1].position != graph.nodes[2].position)
    }

    @Test func observedGraphKeepsStatesActionsAndLateEvidenceDistinct() throws {
        let scenes = ["one", "two"].map { id in
            SceneDefinition(id: id, bundleID: "test.brain", surface: .window,
                            titleBucket: "private-document.rtf", structuralKey: nil,
                            firstSeenMS: 1000, lastSeenMS: 30000, observationCount: 2,
                            skeleton: SceneSkeleton(surface: .window, rolesByPath: [:], captionsByPath: [:], collections: []))
        }
        func relation(_ id: String, from: String, to: String?, supports: Int, at: Int64) -> BrainRelation {
            BrainRelation(relationID: id,
                key: BrainRelationKey(bundleID: "test.brain", contextID: nil, fromSceneID: from,
                    elementKey: nil, verb: .pressKey, argumentsKey: "key=s;modifiers=cmd;count=1",
                    toSceneID: to, outcome: .effect, effectKind: "elementsAppeared"),
                firstSeenMS: at, lastSeenMS: at, supports: supports, contradictions: 0)
        }
        let saved = StoredBrain(bundleID: "test.brain", projection: UIBrain(), scenes: scenes,
            relations: [relation("same", from: "one", to: "one", supports: 1, at: 20000),
                        relation("next", from: "one", to: "two", supports: 2, at: 25000),
                        relation("unknown", from: "two", to: nil, supports: 1, at: 30000)])
        let graph = BrainGraph(stored: saved)
        let inspection = BrainInspection(saved)
        #expect(inspection.scene("one") != inspection.scene("two"))
        #expect(!graph.nodes.contains { $0.label.contains("private-document") })
        #expect(graph.nodes.contains { $0.id == "relation:same" && $0.kind == .relation(.candidate) })
        #expect(graph.nodes.contains { $0.id == "relation:next" && $0.kind == .relation(.exposed) })
        #expect(graph.nodes.contains { $0.id == "unknown:unknown" })
        #expect(graph.edges.contains { $0.from == "scene:one" && $0.to == "relation:same" })
        #expect(graph.edges.contains { $0.from == "relation:same" && $0.to == "scene:one" })
        #expect(!graph.edges.contains { $0.from == $0.to })
        #expect(graph.span.upperBound == Date(timeIntervalSince1970: 30))
        #expect(graph.nodes.first { $0.id == "relation:same" }?.position != graph.nodes.first { $0.id == "scene:one" }?.position)
        var physics = BrainPhysics(graph: graph)
        _ = physics.reveal(upTo: graph.span.upperBound, placing: false)
        #expect(physics.isLinked.allSatisfy { $0 })
    }

    @Test func timelineRedrawsWhenOnlyALateHistoricalEffectChanges() {
        let first = Date(timeIntervalSince1970: 1)
        let last = Date(timeIntervalSince1970: 20)
        let anchors = ["main", "other"].map { name in
            ObjectAnchor(anchorKey: name, kind: .control, label: "Open",
                         boundsTypical: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1),
                         firstSeen: first, lastSeen: first, window: name)
        }
        let graph = BrainGraph(brain: UIBrain(objects: anchors, transitions: [
            LearnedTransition(anchorKey: "main", trigger: .click,
                              effect: "windowTitleChanged:other", lastObserved: last)
        ]))
        var physics = BrainPhysics(graph: graph)
        #expect(graph.span.upperBound == last)
        let hidLateEffect = physics.reveal(upTo: first, placing: false)
        #expect(hidLateEffect)
        #expect(physics.isLinked.contains(false))
        let revealedLateEffect = physics.reveal(upTo: last, placing: false)
        #expect(revealedLateEffect)
        #expect(physics.isLinked.allSatisfy { $0 })
    }

    @Test func cancellingLayoutDoesNotReturnAPublishedSimulation() async {
        let job = Task { try await BrainSimulation.settled(BrainGraph(brain: UIBrain())) }
        job.cancel()
        do {
            _ = try await job.value
            Issue.record("A cancelled layout must not publish a simulation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected layout failure: \(error)")
        }
    }

    @Test func immutableElementCountsAreNotDisplayedAsRepeatSightings() {
        let scene = SceneDefinition(id: "state", bundleID: "test.brain", surface: .window,
            titleBucket: "private-document.rtf", structuralKey: nil, firstSeenMS: 1000,
            lastSeenMS: 2000, observationCount: 13,
            skeleton: SceneSkeleton(surface: .window, rolesByPath: [:], captionsByPath: [:], collections: []))
        let element = SceneElementRecord(sceneElementID: "button", sceneID: scene.id, elementKey: "button",
            scope: .control, parentElementID: nil, edgeHash: nil, cursorAffordance: nil, anchorID: nil,
            label: "Open", labelOrigin: .title, role: "AXButton", kind: "control", source: nil,
            bounds: nil, firstSeenMS: 1000, lastSeenMS: 1000, observationCount: 1)
        let saved = StoredBrain(bundleID: "test.brain", projection: UIBrain(), scenes: [scene], elements: [element])
        let graph = BrainGraph(stored: saved)
        #expect(graph.nodes.first { $0.id == "scene:state" }?.detail?.contains(BrainInspection.observations(scene)) == true)
        #expect(graph.nodes.first { $0.id == "element:button" }?.detail == BrainInspection(saved).scene(scene.id))
        #expect(scene.observationCount == 13 && element.observationCount == 1)
        let command = BrainRelation(relationID: "menu", key: BrainRelationKey(bundleID: "test.brain",
            contextID: nil, fromSceneID: scene.id, elementKey: nil, verb: .menu,
            argumentsKey: "path=file>duplicate", toSceneID: scene.id,
            outcome: .windowSetChanged, effectKind: nil), firstSeenMS: 1000, lastSeenMS: 1000,
            supports: 1, contradictions: 0)
        #expect(BrainInspection.graphAction(command).contains("duplicate"))
        #expect(!BrainInspection.graphAction(command).contains("file>"))
    }

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

    @Test func actionCaptionsResolveOnlyTheRecordedScreenAndKeepUnknownTargetsHonest() {
        let scenes = ["one", "two"].map { id in
            SceneDefinition(id: id, bundleID: "test.brain", surface: .window,
                titleBucket: "private-document.rtf", structuralKey: nil, firstSeenMS: 1000,
                lastSeenMS: 2000, observationCount: 3,
                skeleton: SceneSkeleton(surface: .window, rolesByPath: [:], captionsByPath: [:], collections: []))
        }
        func element(_ id: String, scene: String, label: String) -> SceneElementRecord {
            SceneElementRecord(sceneElementID: id, sceneID: scene, elementKey: "shared",
                scope: .control, parentElementID: nil, edgeHash: nil, cursorAffordance: nil, anchorID: nil,
                label: label, labelOrigin: .title, role: "AXButton", kind: "control", source: nil,
                bounds: nil, firstSeenMS: 1000, lastSeenMS: 1000, observationCount: 1)
        }
        func relation(_ verb: BrainVerb, target: String?, arguments: String = "") -> BrainRelation {
            BrainRelation(relationID: verb.rawValue, key: BrainRelationKey(bundleID: "test.brain",
                contextID: nil, fromSceneID: "one", elementKey: target, verb: verb,
                argumentsKey: arguments, toSceneID: nil, outcome: .effect, effectKind: "elementsAppeared"),
                firstSeenMS: 1000, lastSeenMS: 1000, supports: 1, contradictions: 0)
        }
        let saved = StoredBrain(bundleID: "test.brain", projection: UIBrain(), scenes: scenes,
            elements: [element("first", scene: "one", label: "Multiply"),
                       element("second", scene: "two", label: "Erase")])
        let inspection = BrainInspection(saved)
        let click = relation(.click, target: "shared")
        #expect(inspection.graphAction(click).contains("Multiply"))
        #expect(!inspection.graphAction(click).contains("Erase"))
        #expect(inspection.description(click).contains(inspection.scene(nil)))
        #expect(!inspection.description(click).contains("private-document"))
        let unknown = relation(.click, target: "missing")
        #expect(!inspection.graphAction(unknown).contains("Multiply"))
        #expect(!inspection.graphAction(unknown).contains("Erase"))
        let shortcut = relation(.pressKey, target: nil, arguments: "key=g;modifiers=cmd+shift;count=1")
        #expect(inspection.graphAction(shortcut).contains("⇧⌘G"))
        #expect(!inspection.description(shortcut).contains("shared"))
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

    @Test func frozenNamingImportDoesNotInventStoredKnowledge() async throws {
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
            // The current schema freezes this historical writer. Current scene visibility is
            // tested through storedBrain, without manufacturing anchors to satisfy a view.
            #expect(try await service.brainApplications().isEmpty)
            #expect(try await service.brain(of: "test.brain") == nil)
            #expect(try await service.storedBrain(of: "test.brain") == nil)
        } catch {
            await service.close()
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        await service.close()
        try FileManager.default.removeItem(at: directory)
    }
}
