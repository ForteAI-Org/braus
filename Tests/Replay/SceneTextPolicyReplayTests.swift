import EngineCore
import Foundation
import Memory
import LocalMCP
import PerceptionCore
import Switches
import Testing
@testable import AutomationMCP

@MainActor
struct SceneTextPolicyReplayTests {
    @Test(arguments: try ReplayCorpus.load().filter { $0.deliveries != nil })
    func chainedIsToday(_ item: ReplayCase) async throws {
        let session = ReplaySession()
        let policy = SceneTextPolicy()
        let deliveries = try #require(item.deliveries)
        for (index, delivery) in deliveries.enumerated() {
            session.id = delivery.session
            if let input = item.input {
                let scenes = (input.prefix + [input.outcome]).filter { $0.scene != nil }
                session.observedWindowNumber = scenes[index].windowNumber
            }
            let answer = await policy.answer(delivery.scene, changesOnly: true, nested: true,
                                                   session: session, shown: ValueMinimization()).observation(nested: true)
            #expect(answer["revision"] == .number(Double(delivery.revision)))
            #expect(answer["since"] == (delivery.since.map { .number(Double($0)) } ?? .null))
            #expect(Data((answer["scene"].string ?? answer["changes"].string ?? "").utf8)
                    == Data(delivery.savedText.utf8), "\(item.id) revision \(delivery.revision)")
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
    @Test(arguments: ["", "chained", "invalid"])
    func defaultAndChainedMatchFrozenSyntheticText(_ arm: String) async throws {
        let switches = arm.isEmpty ? [:] : ["scene_text_policy": arm]
        await SwitchBoard.$testing.withValue(SwitchBoard(values: switches)) {
            let policy = SceneTextPolicy()
            let session = SceneContextHoldTests.session()
            let first = await policy.answer(SceneContextHoldTests.scene(), session: session, shown: ValueMinimization())
            #expect(first.form == .whole(because: nil))
            let next = await policy.answer(SceneContextHoldTests.scene(1), changesOnly: true,
                                           session: session, shown: ValueMinimization())
            #expect(next.text == "## Content @0,0 100x100\n~ [control] Setting 0 = 1 @10,0  (was = \"0\")")
            #expect(next.form == .changes(since: 1, base: .last))
            let unchanged = await policy.answer(SceneContextHoldTests.scene(1), changesOnly: true,
                                                session: session, shown: ValueMinimization())
            #expect(unchanged.form == .unchanged(since: 2))
            #expect(unchanged.text == "Unchanged since revision 2.")
        }
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
