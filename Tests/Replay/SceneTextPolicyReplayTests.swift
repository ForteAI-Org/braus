import EngineCore
import Foundation
import Memory
import LocalMCP
import PerceptionCore
import Testing
@testable import AutomationMCP

@MainActor
struct SceneTextPolicyReplayTests {
    @Test(arguments: try ReplayCorpus.load().filter { $0.deliveries != nil })
    func canonicalPolicyPreservesSceneContentWithBoundedDependencies(_ item: ReplayCase) async throws {
        let session = ReplaySession()
        let policy = SceneTextPolicy()
        let deliveries = try #require(item.deliveries)
        var depths: [Int: Int] = [:]
        var snapshots: [Int: SceneSnapshot] = [:]
        for (index, delivery) in deliveries.enumerated() {
            session.id = delivery.session
            if let input = item.input {
                let scenes = (input.prefix + [input.outcome]).filter { $0.scene != nil }
                session.observedWindowNumber = scenes[index].windowNumber
            }
            let answer = await policy.answer(delivery.scene, changesOnly: true, nested: true,
                                             session: session, shown: ValueMinimization())
            #expect(answer.revision == delivery.revision)
            switch answer.form {
            case .whole:
                depths[answer.revision] = 0
                #expect(answer.text == answer.scene.text(cuts: .safe))
            case .changes(let since, _):
                let previous = try #require(snapshots[since])
                let depth = try #require(depths[since]) + 1
                #expect(depth <= 2)
                depths[answer.revision] = depth
                let expected = "r\(answer.revision) since r\(since)\n"
                    + SceneChanges.changes(from: previous, to: answer.scene, cuts: .safe).text(since: since)
                #expect(answer.text == expected)
            case .unchanged(let since):
                let previous = try #require(snapshots[since])
                #expect(SceneChanges.changes(from: previous, to: answer.scene, cuts: .safe).isEmpty)
                let depth = try #require(depths[since]) + 1
                #expect(depth <= 2)
                depths[answer.revision] = depth
                #expect(answer.text == "r\(answer.revision) unchanged since r\(since)")
            }
            snapshots[answer.revision] = answer.scene
        }
    }

}

extension SceneTextPolicyReplayTests {
    @Test(.disabled("needs recorded scenes"))
    func recordedScenes() async throws {
        let url = ReplayCorpus.fixtures.appending(path: "scene-policy/calls.json")
        let calls = try JSONDecoder().decode([RecordedCall].self, from: Data(contentsOf: url))
        #expect(!calls.isEmpty)
        let session = SceneContextHoldTests.session()
        let policy = SceneTextPolicy()
        for call in calls {
            if let reset = call.reset, reset != "turn" {
                let reason = try #require(SceneContextReset(rawValue: reset))
                policy.contextHolds(after: reason, keeping: call.keptRevision)
            }
            session.observedWindowNumber = call.windowNumber
            let answer = await policy.answer(call.scene, changesOnly: call.changesOnly, nested: call.nested,
                                            session: session, shown: ValueMinimization())
            #expect(answer.revision == call.expectedRevision)
            if call.reset == "turn" { continue }
            #expect(Data(answer.text.utf8) == Data(call.expectedText.utf8))
            switch answer.form {
            case .changes(let since, _), .unchanged(let since): #expect(since == call.expectedSince)
            case .whole: #expect(call.expectedSince == nil)
            }
        }
    }

    private struct RecordedCall: Decodable {
        let scene: SceneSnapshot
        let windowNumber: Int?
        let changesOnly: Bool
        let nested: Bool
        let reset: String?
        let keptRevision: Int?
        let expectedText: String
        let expectedRevision: Int
        let expectedSince: Int?
    }
}

extension SceneTextPolicyReplayTests {
    @Test func canonicalSyntheticTextIncludesItsExplicitBase() async throws {
        let policy = SceneTextPolicy()
        let session = SceneContextHoldTests.session()
        let first = await policy.answer(SceneContextHoldTests.scene(), session: session, shown: ValueMinimization())
        #expect(first.form == .whole(because: nil))
        let next = await policy.answer(SceneContextHoldTests.scene(1), changesOnly: true,
                                       session: session, shown: ValueMinimization())
        #expect(next.text == "r2 since r1\n## Content @0,0 100x100\n~ [control] Setting 0 = 1 @10,0  (was = \"0\")")
        #expect(next.form == .changes(since: 1, base: .anchor))
        let unchanged = await policy.answer(SceneContextHoldTests.scene(1), changesOnly: true,
                                            session: session, shown: ValueMinimization())
        #expect(unchanged.form == .unchanged(since: 2))
        #expect(unchanged.text == "r3 unchanged since r2")
    }

}

struct OneOwnerTests {
    @Test func modelSceneRenderingHasOneOwner() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for folder in ["Sources/Integration/AutomationMCP", "Sources/Turn"] {
            let directory = root.appending(path: folder)
            let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "SceneTextPolicy.swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                #expect(!source.contains("SceneChanges.text("), "\(url.lastPathComponent)")
                #expect(source.range(of: #"\b(?:scene|snapshot)\.(?:text|textLines|mapText)\("#,
                                     options: .regularExpression) == nil, "\(url.lastPathComponent)")
            }
        }
    }
}
