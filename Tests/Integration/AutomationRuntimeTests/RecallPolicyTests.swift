//
//  RecallPolicyTests.swift
//  Braus
//

import AutomationMCP
@testable import AutomationRuntime
import CoreGraphics
import Engine
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Testing

/// R10: a step the memory recalls is a suggestion, never an authorization. A procedure learned through the tools
/// that sends an email ends with an `act` on Send; recalled from the archive for a new task, its delivery carries that
/// step, and the engine still refuses it under the current policy, regardless of the earlier authorization.
@MainActor
@Suite("A recalled step under the current policy (R10)", .serialized)
struct RecallPolicyTests {

    typealias P = ProcedureLearningTests

    /// The window the recalled step acts in, with Send in it.
    final class Scenes: SceneProviding, @unchecked Sendable {
        let window: PerceivedWindow
        init(_ label: String) {
            let send = SceneElement(id: "control|send", kind: .control, label: label,
                                    bounds: NormalizedRect(x: 0.8, y: 0.1, width: 0.08, height: 0.03), role: "AXButton")
            window = PerceivedWindow(scene: SceneSnapshot(
                bundleID: "com.apple.mail", appName: "Mail", windowTitle: "Report Q4",
                viewportPixelSize: ViewportPixelSize(width: 2000, height: 1600), elements: [send]
            ), frame: CGRect(x: 100, y: 100, width: 1000, height: 800))
        }
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow { window }
    }

    final class Windows: WindowListing, @unchecked Sendable {
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
            [WindowRow(layer: 0, frame: CGRect(x: 100, y: 100, width: 1000, height: 800), title: "Report Q4",
                       number: 1)]
        }
    }

    /// Every gesture delivered, so a test sees that none went out.
    final class Actuator: Actuating, @unchecked Sendable {
        var gestures: [Gesture] = []
        func perform(_ gesture: Gesture, in processID: pid_t) async throws { gestures.append(gesture) }
        func confirm(_ effect: DeliveryEffect, in processID: pid_t) async {}
    }

    @Test("R10: a learned email recalled from the archive ends by sending; carried out now, that step is refused")
    func recalledSendUnderTheCurrentPolicy() async throws {
        let (session, memory) = try await RecallScopeTests.learned()
        let tools = P.tools(session, stream: "r10")
        let begun = try await P.task(tools, #"""
            {"operation":"begin","goal":"Find report_q4.pdf and send it by email to Marco with subject Report Q4",
             "remaining":"Find report_q4.pdf and send it by email to Marco with subject Report Q4",
             "inputs":[{"name":"file_name","value":"report_q4.pdf"},{"name":"recipient","value":"marco@example.com"},
                       {"name":"subject","value":"Report Q4"}]}
            """#)
        // The product's path: the memory proposes, the agent chooses its ready plan, and the memory delivers it.
        let proposal = try #require(begun["recall_proposal"]["proposal"].string, "\(begun)")
        let plan = try #require(begun["recall_proposal"]["needs"].array?.first?["readyPlan"].string, "\(begun)")
        let chosen = try await P.task(tools, #"{"operation":"choose","proposal":"\#(proposal)","plan":[\#(plan)]}"#)
        let steps = (chosen["recall"]["needs"].array?.first?["tracts"].array ?? []).flatMap { $0["steps"].array ?? [] }
        let send = try #require(steps.first { step in
            step["tool"].string == "act" && (step["arguments"].array ?? []).contains { $0["value"].string == "Send" }
        }, "the delivered plan carries the sending step: \(chosen)")
        let arguments = send["arguments"].array ?? []
        let target = try #require(arguments.first { $0["name"].string == "target" }?["value"].string)
        await RecallScopeTests.close(session, memory)

        // The step as the memory delivers it, carried out through the engine: the policy of now decides.
        for permissions in [ActionPermissions(), ActionPermissions(allowsDestructive: true)] {
            let actuator = Actuator()
            let engine = ActionEngine(ActionEngine.Dependencies(scenes: Scenes(target), actuator: actuator,
                                                                windows: Windows()),
                                      permissions: permissions, pause: { _ in })
            let outcome = await engine.act(ActionRequest(processID: 4242, bundleID: "com.apple.mail", appName: "Mail",
                                                         target: target, verb: .click))
            #expect(outcome.kind == .refused, Comment(rawValue: outcome.message))
            let expected = permissions.allowsDestructive ? "cannot read its effect back" : "person must allow"
            #expect(outcome.message.contains(expected), Comment(rawValue: outcome.message))
            #expect(actuator.gestures.isEmpty, "a recalled step is no authorization: nothing was sent")
        }
    }
}
