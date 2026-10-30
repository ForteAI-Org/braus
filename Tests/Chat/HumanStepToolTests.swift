//
//  HumanStepToolTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

@testable import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing

@Suite
@MainActor
struct HumanStepToolTests {
    @Test func catalogIncludesLazyHumanDetails() {
        #expect(AutomationTools.definitions.contains { $0["name"].string == "human_step" })
    }

    @Test func parsesStepsWindowsAndPictures() throws {
        #expect(try HumanStepTool.request(.object(["steps": .string("3-5")])) == .steps(3...5))
        #expect(try HumanStepTool.request(.object(["steps": .string("7")])) == .steps(7...7))
        #expect(try HumanStepTool.request(.object(["steps": .string("1-20")])) == .steps(1...20))
        #expect(try HumanStepTool.request(.object(["diff": .string("§2")])) == .diff("§2"))
        #expect(try HumanStepTool.request(.object(["diff": .number(42)])) == .diff("42"))
        #expect(try HumanStepTool.request(.object(["picture": .number(3)])) == .picture(3))
    }

    @Test func rejectsAmbiguousUnboundedAndMalformedRequests() {
        let arguments: [JSONValue] = [
            .null, .object([:]), .object(["unknown": .string("1")]),
            .object(["steps": .string("1"), "picture": .number(1)]),
            .object(["steps": .string("0")]), .object(["steps": .number(1)]),
            .object(["steps": .string("1-21")]), .object(["steps": .string("5-3")]),
            .object(["steps": .string("1-")]), .object(["steps": .string("1-2-3")]),
            .object(["steps": .string("+1")]), .object(["steps": .string("01")]),
            .object(["steps": .string("99999999999999999999999999999")]),
            .object(["diff": .string("§0")]), .object(["diff": .string("§anything")]),
            .object(["picture": .number(1.5)]), .object(["picture": .number(-1)])
        ]
        for arguments in arguments {
            #expect(throws: AutomationFailure.self) { try HumanStepTool.request(arguments) }
        }
    }

    @Test func routerReturnsCompactDetailsWithoutArchiving() async throws {
        let session = HumanStepSession()
        session.answer = HumanStepResult(text: "§1=\"Draft 15\"\n3: renamed §1")
        let tools = AutomationTools(session: session)
        var records: [String] = []
        tools.record = { records.append($0) }
        let router = MCPRouter(tools: tools.toolDefinitions, call: tools.call)
        let listed = try #require(await router.handle(.object([
            "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list")
        ])))
        #expect(listed["result"]["tools"].array?.contains { $0["name"].string == "human_step" } == true)
        let response = try #require(await router.handle(request(["steps": .string("3-5")])))
        #expect(response["result"]["content"].array?.first?["text"].string == session.answer.text)
        #expect(session.requests == [.steps(3...5)])
        #expect(records.isEmpty)
    }

    @Test func refusesOutsideTheResumedTurn() async throws {
        let session = HumanStepSession()
        let tools = AutomationTools(session: session)
        let result = try await tools.call("human_step", .object(["steps": .string("1")]))
        #expect(result["isError"] == .bool(true))
        #expect(result["content"].array?.first?["text"].string == HumanStepResult.unavailable.text)
    }

    @Test func imagesSurviveTheRouterAndHaveATextFallback() async throws {
        let session = HumanStepSession()
        let picture = Data([0, 1, 2, 3])
        session.answer = HumanStepResult(text: "3: Colour palette", picture: picture)
        let tools = AutomationTools(session: session)
        let router = MCPRouter(tools: tools.toolDefinitions, call: tools.call)
        let response = try #require(await router.handle(request(["picture": .number(3)])))
        let blocks = try #require(response["result"]["content"].array)
        #expect(blocks.count == 2)
        #expect(blocks[0]["text"].string?.contains("Picture attached (HEIC).") == true)
        #expect(blocks[1]["type"] == .string("image"))
        #expect(blocks[1]["mimeType"] == .string("image/heic"))
        #expect(blocks[1]["data"] == .string(picture.base64EncodedString()))
    }

    @Test func minimizesAllResponseTextAndDoesNotAttachFailedPictures() {
        let result = HumanStepTool.result(
            HumanStepResult(text: "secret", picture: Data([1]), isError: true),
            withholding: { $0.replacingOccurrences(of: "secret", with: "[protected]") }
        )
        #expect(result["content"].array?.count == 1)
        #expect(result["content"].array?.first?["text"].string?.contains("secret") == false)
    }

    @Test func invalidRequestsDoNotReachTheRetainedHistory() async throws {
        let session = HumanStepSession()
        let tools = AutomationTools(session: session)
        let router = MCPRouter(tools: tools.toolDefinitions, call: tools.call)
        let response = try #require(await router.handle(request(["steps": .string("1-1000")])))
        #expect(response["result"]["isError"] == .bool(true))
        #expect(session.requests.isEmpty)
    }

    private func request(_ arguments: [String: JSONValue]) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/call"),
            "params": .object(["name": .string("human_step"), "arguments": .object(arguments)])
        ])
    }
}

@MainActor
private final class HumanStepSession: AutomationSessionOperating {
    let id: UUID? = nil
    var answer = HumanStepResult.unavailable
    var requests: [HumanStepRequest] = []

    func humanStep(_ request: HumanStepRequest) async -> HumanStepResult {
        requests.append(request)
        return answer
    }

    func open(application: String, window: String?) async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func observe() async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("unused") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func close() async {}
}
