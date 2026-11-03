import AutomationMCP
import AutomationRuntime
import Capabilities
import Foundation
import LocalMCP
import Memory
import Testing

private nonisolated enum DemoFailure: Error {
    case provider
    case recording
}

private actor RecordingSpy: CapabilityRecording {
    var events: [String] = []
    var sessionID: UUID?
    var hasFreshScope = false
    let failAtBegin: Bool
    let failAtEnd: Bool

    init(failAtBegin: Bool = false, failAtEnd: Bool = false) {
        self.failAtBegin = failAtBegin
        self.failAtEnd = failAtEnd
    }

    func began(_ id: CapabilityID, arguments: JSONValue) async throws {
        events.append("began:\(id.rawValue)")
        if failAtBegin { throw DemoFailure.recording }
    }

    func called(_ id: CapabilityID, context: CapabilityCallContext, hasFreshScope: Bool) {
        events.append("called:\(id.rawValue)")
        sessionID = context.sessionID
        self.hasFreshScope = hasFreshScope
    }

    func ended(_ id: CapabilityID, result: JSONValue?, failure: String?, verified: Bool?) async throws {
        events.append("ended:\(id.rawValue):\(failure == nil ? "success" : "failure")")
        #expect(verified == nil)
        #expect((result == nil) == (failure != nil))
        if failAtEnd { throw DemoFailure.recording }
    }
}

private nonisolated struct DemoProvider: CapabilityProviding {
    let family = "demo"
    let spy: RecordingSpy
    var readInterruption: InterruptionClass = .readOnly
    var failsWrites = true
    var result: JSONValue = .object(["value": .string("demo result")])

    var contracts: [CapabilityContract] {
        [("read", EffectClass.read, readInterruption), ("write", .write, .mutating)].map { name, effect, interruption in
            CapabilityContract(
                id: CapabilityID(rawValue: "demo.\(name)"),
                group: "demo",
                description: "Demo capability",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                effect: effect,
                interruption: interruption,
                verification: .none(reason: "Result only"),
                channel: .braus,
                origin: .registered(provider: family),
                memory: .capabilityStep,
                takesSession: false,
                parallelSafe: false
            )
        }
    }

    func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue {
        await spy.called(id, context: context, hasFreshScope: CallScope.current.withheld.isEmpty)
        if id.rawValue == "demo.write", failsWrites { throw DemoFailure.provider }
        return result
    }
}

@Suite
@MainActor
struct RegisteredFamilyTests {
    @Test func readOnlyHintUsesEffectEvenWhenInterruptionIsMutating() throws {
        let tools = AutomationTools(
            session: DemoSession(),
            capabilities: [DemoProvider(spy: RecordingSpy(), readInterruption: .mutating)]
        )
        let definition = try #require(tools.toolDefinitions.first { $0["name"].string == "demo.read" })
        #expect(definition["annotations"]["readOnlyHint"] == .bool(true))
    }

    @Test func recordsExactlyOnceAroundSuccessAndFailure() async throws {
        let session = DemoSession()
        let spy = RecordingSpy()
        let tools = AutomationTools(session: session, capabilities: [DemoProvider(spy: spy)], recording: spy)
        #expect(tools.toolDefinitions.suffix(2).compactMap { $0["name"].string } == ["demo.read", "demo.write"])
        #expect(tools.interruptionClass(of: "demo.read", arguments: .null) == .readOnly)
        #expect(tools.effectClass(of: "demo.read", arguments: .null) == .read)
        #expect(!tools.isParallelSafe("demo.read", arguments: .null))
        #expect(AutomationTools.interruptionPolicy(for: "demo.read") == .mutating)
        let result = try decodedCapabilityResult(await tools.call("demo.read", .object([:])))
        #expect(result["value"].string == "demo result")
        await #expect(throws: DemoFailure.provider) { try await tools.call("demo.write", .object([:])) }
        #expect(await spy.events == ["began:demo.read", "called:demo.read", "ended:demo.read:success",
                                    "began:demo.write", "called:demo.write", "ended:demo.write:failure"])
        #expect(await spy.sessionID == session.id)
    }

    @Test func missingObserverSaysNotRecorded() async throws {
        let spy = RecordingSpy()
        let tools = AutomationTools(session: DemoSession(), capabilities: [DemoProvider(spy: spy)])
        let result = try decodedCapabilityResult(await tools.call("demo.read", .object([:])))
        #expect(result["memory"].string?.contains("not recorded") == true)
        #expect(await spy.events == ["called:demo.read"])
    }

    @Test(arguments: ["demo.read", "demo.write"])
    func endFailureDoesNotRepeatTheObserverOrProvider(_ name: String) async throws {
        let spy = RecordingSpy(failAtEnd: true)
        let tools = AutomationTools(
            session: DemoSession(),
            capabilities: [DemoProvider(spy: spy, failsWrites: false)],
            recording: spy
        )
        let result = try decodedCapabilityResult(await tools.call(name, .object([:])))
        #expect(result["value"].string == "demo result")
        #expect(result["memory"].string?.contains("Recording failed") == true)
        #expect(result["memory"].string?.contains("Do not repeat") == true)
        #expect(await spy.events == ["began:\(name)", "called:\(name)", "ended:\(name):success"])
    }

    @Test func endFailurePreservesScalarResultsWithTheNotice() async throws {
        let spy = RecordingSpy(failAtEnd: true)
        let tools = AutomationTools(
            session: DemoSession(),
            capabilities: [DemoProvider(spy: spy, result: .string("completed"))],
            recording: spy
        )
        let response = try await tools.call("demo.read", .object([:]))
        let result = try decodedCapabilityResult(response)
        #expect(response["isError"] == .bool(false))
        #expect(result["result"] == .string("completed"))
        #expect(result["memory"].string?.contains("Do not repeat") == true)
    }

    @Test func readBeginningFailureContinuesWithNotice() async throws {
        let spy = RecordingSpy(failAtBegin: true)
        let tools = AutomationTools(session: DemoSession(), capabilities: [DemoProvider(spy: spy)], recording: spy)
        let result = try decodedCapabilityResult(await tools.call("demo.read", .object([:])))
        #expect(result["memory"].string?.contains("not recorded") == true)
        #expect(await spy.events == ["began:demo.read", "called:demo.read"])
    }

    @Test func registeredCallsReceiveTheirOwnScope() async throws {
        let spy = RecordingSpy()
        let tools = AutomationTools(session: DemoSession(), capabilities: [DemoProvider(spy: spy)], recording: spy)
        var outer = CallScope()
        outer.withhold("outer text", .unclassifiedTarget)
        _ = try await CallScope.$current.withValue(outer) {
            try await tools.call("demo.read", .object([:]))
        }
        #expect(await spy.hasFreshScope)
    }

}
