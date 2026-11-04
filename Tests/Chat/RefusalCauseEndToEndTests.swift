import CoreGraphics
import Engine
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import SeatSession
import Testing
@testable import AutomationMCP
@testable import SeatDriving

@MainActor
struct RefusalCauseEndToEndTests {
    private actor RefusingActuator: Actuating {
        let refusal: RemoteContentActuationRefusal
        var confirmations: [DeliveryEffect] = []
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async { confirmations.append(effect) }
        init(_ refusal: RemoteContentActuationRefusal) { self.refusal = refusal }
        func perform(_ gesture: Gesture, in processID: pid_t) async throws {
            throw SeatActuator.deliveryError(refusal)
        }
    }

    private struct Scenes: SceneProviding {
        let scene: SceneSnapshot
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            PerceivedWindow(scene: scene, frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        }
    }

    private struct Windows: WindowListing {
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] { [] }
    }

    @Test(arguments: [RemoteContentActuationRefusal.opensMenu("AXPopUpButton"), .opensMenu("AXMenuButton"),
                      .columnView, .selectionNotVerified("AXRow"), .selectedNotOpened(code: nil),
                      .actionRefused(action: "fake-action", code: -25205),
                      .actionRefused(action: "fake-action", code: -25206)])
    func remoteCauseReachesCatalogue(_ refusal: RemoteContentActuationRefusal) async throws {
        let session = ToolResultSession()
        session.scene.elements = [SceneElement(id: "button", kind: .control, label: "fake-label",
            bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), role: "AXButton")]
        let engine = ActionEngine(ActionEngine.Dependencies(scenes: Scenes(scene: session.scene),
            actuator: RefusingActuator(refusal), windows: Windows()), pause: { _ in })
        let result = await engine.act(ActionRequest(processID: 42, bundleID: "test.synthetic",
            appName: "Synthetic Mixer", target: "fake-label", verb: .click))
        let secrets = ProducerSecrets()
        let policy = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: policy)
        defer { withExtendedLifetime((secrets, policy)) {} }
        let value = await formatter.outcome(result)
        #expect(result.cause == "remote_content_refused." + refusal.code)
        #expect(result.outcome.gesture == (refusal.mayHaveTakenEffect ? .uncertain : .notSent))
        let expected = OutcomeText.message(OutcomeKey(outcome: result.outcome, verb: "click", cause: result.cause), label: nil)
        #expect(value["_outcome_message"].string == expected)
        let rendered = try formatter.finish("act", value, notice: nil, output: CallOutput())
        let text = try #require(rendered["content"].array?.first?["text"].string)
        #expect(text.contains(expected))
        #expect(!expected.contains("fake-label") && !expected.contains("fake-action") && !expected.contains("AX"))
        if refusal.code == "opens_list" { #expect(!expected.contains("menu")) }
    }

    @Test func observePreservesDispatcherRefusal() async throws {
        let session = ToolResultSession()
        session.observedWindowNumber = 1
        session.actionResult = ActOutcome(.refused, "historical", scene: session.scene,
            notSent: .targetUnreachable, cause: "remote_content_refused.column_view")
        try await session.withPlannedTools { tools in
            let arguments: JSONValue = .object(["step": .string("r1"), "target": .string("Target")])
            let first = try await tools.call("act", arguments)
            #expect(first["content"].array?.first?["text"].string?.contains("change_target(unreachable)") == true)
            _ = try await tools.call("observe", .object([:]))
            let repeated = try await tools.call("act", arguments)
            #expect(repeated["content"].array?.first?["text"].string?.contains("Already refused") == true)
        }
    }
    @Test func batchUsesIndividualGestureArguments() async throws {
        let session = ToolResultSession()
        session.observedWindowNumber = 1
        session.scene.elements = ["First", "Second"].enumerated().map { index, target in
            SceneElement(id: "fixture-\(index)", kind: .control, label: target,
                bounds: NormalizedRect(x: 0.1, y: Double(index) * 0.2, width: 0.2, height: 0.1), role: "AXButton")
        }
        session.actionResult = ActOutcome(.refused, "historical", scene: session.scene,
            notSent: .targetUnreachable, cause: "remote_content_refused.opens_list")
        try await session.withPlannedTools { tools in
            for (index, target) in ["First", "Second", "Second"].enumerated() {
                let result = try await tools.call("batch", .object([
                    "steps": .array([.object([
                        "operation": .string("act"), "target": .string(target), "step": .string("r1")
                    ])])
                ]))
                let text = try #require(result["content"].array?.first?["text"].string)
                #expect(text.contains(index == 2 ? "Already refused" : "opens a list"))
                #expect(!text.contains("historical"))
        }
        }
    }

}
