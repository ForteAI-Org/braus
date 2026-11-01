import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Switches
import Testing
@testable import AutomationMCP

@MainActor
struct MisleadingMessageTests {
    @Test func repeatedRefusalTracksContentAndExactGesture() async throws {
        await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let session = ToolResultSession()
            session.observedWindowNumber = 1
            let secrets = ProducerSecrets()
            let policy = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: policy)
            defer { withExtendedLifetime((secrets, policy)) {} }
            let id = UUID()
            func context(_ verb: String = "click", window: Int = 1, key: String? = nil) -> ResultFormatter.RefusalContext {
                .init(sessionID: id, windowNumber: window, tool: key == nil ? "act" : "press_key",
                      arguments: .object(["target": .string("exact-target"), "verb": .string(verb),
                                          "key": key.map(JSONValue.string) ?? .null]))
            }
            let refused = ActOutcome(.refused, "fake-private-value", notSent: .targetUnreachable,
                                     cause: "remote_content_refused.column_view")
            formatter.noteScene(session.scene, sessionID: id, windowNumber: 1)
            let first = await formatter.outcome(refused, refusal: context())
            #expect(first["recovery"].string == "change_target(unreachable)")
            formatter.noteScene(session.scene, sessionID: id, windowNumber: 1)
            let second = await formatter.outcome(refused, refusal: context())
            #expect(second["recovery"].string == "do_not_repeat")
            #expect(second["_outcome_message"].string?.contains("Already refused") == true)
            let different = await formatter.outcome(refused, refusal: context("double_click"))
            #expect(different["recovery"].string == "change_target(unreachable)")
            let otherWindow = await formatter.outcome(refused, refusal: context("double_click", window: 2))
            #expect(otherWindow["recovery"].string == "change_target(unreachable)")
            session.scene.windowTitle = "Changed content"
            formatter.noteScene(session.scene, sessionID: id, windowNumber: 1)
            let changed = await formatter.outcome(refused, refusal: context("double_click"))
            #expect(changed["recovery"].string == "change_target(unreachable)")
            for key in ["A", "B"] {
                let value = await formatter.outcome(refused, refusal: context(key: key))
                #expect(value["recovery"].string == "change_target(unreachable)")
            }
            let sent = ActOutcome(.foundActed, "sent")
            _ = await formatter.outcome(sent, refusal: context(key: "B"))
            let afterSent = await formatter.outcome(refused, refusal: context(key: "B"))
            #expect(afterSent["recovery"].string == "change_target(unreachable)")
        }
    }

    @Test func argumentOrderAndTokensDoNotClearRefusal() async {
        await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": "v2"])) {
            let session = ToolResultSession()
            let secrets = ProducerSecrets()
            let policy = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: policy)
            defer { withExtendedLifetime((secrets, policy)) {} }
            let id = UUID()
            let refusal = ActOutcome(.refused, "historical", notSent: .targetUnreachable, cause: "remote_content_refused.opens_list")
            let args: JSONValue = .object(["verb": .string("click"), "target": .string("Target"), "token": .string("old")])
            let reordered: JSONValue = .object(["token": .string("new"), "target": .string("Target"), "verb": .string("click")])
            formatter.noteScene(session.scene, sessionID: id, windowNumber: 1)
            _ = await formatter.outcome(refusal, refusal: .init(sessionID: id, windowNumber: 1, tool: "act", arguments: args))
            var fresh = session.scene
            fresh.token = SceneToken(bundleID: "fake.new", windowTitle: "new capture", elements: [])
            formatter.noteScene(fresh, sessionID: id, windowNumber: 1)
            let repeated = await formatter.outcome(refusal, refusal: .init(sessionID: id, windowNumber: 1, tool: "act", arguments: reordered))
            #expect(repeated["recovery"].string == "do_not_repeat")
            let newSession = await formatter.outcome(refusal, refusal: .init(sessionID: UUID(), windowNumber: 1, tool: "act", arguments: args))
            #expect(newSession["recovery"].string == "change_target(unreachable)")
        }
    }

    @Test(arguments: ["v1", "v2"])
    func genericFailureUsesSelectedArm(_ arm: String) async {
        await SwitchBoard.$testing.withValue(SwitchBoard(values: ["outcome": arm])) {
            let session = ToolResultSession()
            let secrets = ProducerSecrets()
            let policy = SceneTextPolicy()
            let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: policy)
            defer { withExtendedLifetime((secrets, policy)) {} }
            let original = "VirtualScreens.DisplayFailure error 15"
            let value = await formatter.outcome(ActOutcome(.actedUnverified, original,
                check: .unchecked(performed: .uncertain)))
            #expect(value["message"].string == original)
            if arm == "v2" {
                #expect(value["_outcome_message"].string == "The seat reported an error it does not describe.")
            } else {
                #expect(value["_outcome_message"] == .null)
            }
        }
    }
}
