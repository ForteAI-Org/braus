import AutomationMCP
import Capabilities
import Foundation
import LocalMCP
import Testing
import Turn
import ModelTransports
@testable import AgentLoop

@MainActor
@Suite("TurnTests parallel safety") struct ParallelSafetyDefaultTests {
    @Test func everyServedCoreToolRemainsSerial() {
        let tools = AutomationTools(session: TurnTestSession())
        for definition in tools.toolDefinitions {
            let name = definition["name"].string ?? ""
            #expect(!tools.isParallelSafe(name, arguments: .object([:])))
        }
        for name in ["observe", "plan", "end", "unknown", "call"] {
            #expect(!tools.isParallelSafe(name, arguments: .object([:])))
        }
    }

    @Test func realAdmissionPreservesSequentialTranscriptAndRecords() async throws {
        let baseline = try await execute(useContracts: false)
        let admitted = try await execute(useContracts: true)
        #expect(admitted.messages == baseline.messages)
        #expect(admitted.records == baseline.records)
        #expect(admitted.messages.last == "1")
    }

    @Test func admittedFakeCallsThroughRunnerMatchSequentialTranscriptAndRecords() async throws {
        let sequential = try await executeRunner(parallelSafe: false)
        let parallel = try await executeRunner(parallelSafe: true)
        #expect(parallel.messages == sequential.messages)
        #expect(parallel.transcript == sequential.transcript)
        #expect(parallel.records == sequential.records)
        #expect(parallel.records.count == 4)
        #expect(parallel.transcript == parallel.records)
    }

    private func executeRunner(parallelSafe: Bool) async throws
        -> (messages: [TurnMessage], transcript: [String], records: [String]) {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let reads = FakeReads(parallelSafe: parallelSafe)
        let tools = AutomationTools(session: TurnTestSession(), capabilities: [reads], recording: reads)
        for name in ["fake.first", "fake.second"] {
            #expect(tools.isParallelSafe("call", arguments: .object(["name": .string(name), "arguments": .object([:])])) == parallelSafe)
        }
        let host = TestTurnHost()
        var admitted = 0
        host.scope = { admitted += 1 }
        let runner = TurnRunner(tools: tools, configuration: .init(
            workingDirectory: root, bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: false
        ), host: host)
        var records: [String] = []
        let forward = tools.record
        tools.record = { records.append($0); try forward?($0) }
        let transport = TurnTestTransport([
            [.toolCall(.init(id: "one", name: "call", arguments: Data(#"{"name":"fake.first","arguments":{}}"#.utf8))),
             .toolCall(.init(id: "two", name: "call", arguments: Data(#"{"name":"fake.second","arguments":{}}"#.utf8)))],
            [.delta("Done.")]
        ])
        var transcript: [String] = []
        _ = try await runner.run(.init(prompt: "Read both", route: .modelLoop(transport: transport, contextWindow: nil))) {
            if case .tool(let line) = $0 { transcript.append(line) }
        }
        #expect(admitted == 2)
        #expect(runner.toolCalls == 2)
        let messages = try #require(transport.messages.last).filter { $0.role == .tool }
        #expect(messages.compactMap { $0.call?.id } == ["one", "two"])
        try await runner.close()
        return (messages, transcript, records)
    }

    private nonisolated struct FakeReads: CapabilityProviding, CapabilityRecording {
        let family = "fake"
        let parallelSafe: Bool
        var contracts: [CapabilityContract] {
            ["fake.first", "fake.second"].map { name in
                CapabilityContract(
                    id: .init(rawValue: name), group: family, description: "Read a fixed value.",
                    inputSchema: .object(["type": .string("object")]), effect: .read,
                    interruption: .readOnly, verification: .none(reason: "Fixed result"),
                    channel: .braus, origin: .registered(provider: family), memory: .capabilityStep,
                    takesSession: false, parallelSafe: parallelSafe
                )
            }
        }
        func began(_ id: CapabilityID, arguments: JSONValue) async throws {}
        func ended(_ id: CapabilityID, result: JSONValue?, failure: String?, verified: Bool?) async throws {}

        func call(_ id: CapabilityID, arguments: JSONValue, context: CapabilityCallContext) async throws -> JSONValue {
            .object(["value": .string(id.rawValue)])
        }
    }

    private func execute(useContracts: Bool) async throws -> (messages: [String], records: [String]) {
        let tools = AutomationTools(session: TurnTestSession())
        var records: [String] = []
        var active = 0
        var state = 0
        let call: @MainActor (String, JSONValue) async throws -> JSONValue = { name, arguments in
            #expect(active == 0)
            active += 1
            records.append("begin " + name)
            await Task.yield()
            if name == "plan", arguments["request"].string != nil { state += 1 }
            records.append("end \(name) \(state)")
            active -= 1
            return .object(["content": .array([.object(["text": .string(String(state))])])])
        }
        let loop: ModelToolLoop
        if useContracts {
            loop = ModelToolLoop(call: call, definitions: [], instructions: Instructions(),
                                parallelSafe: { tools.isParallelSafe($0, arguments: $1) })
        } else { loop = ModelToolLoop(call: call, definitions: [], instructions: Instructions()) }
        let calls = [
            ToolCall(id: "one", name: "observe", arguments: Data("{}".utf8)),
            ToolCall(id: "two", name: "observe", arguments: Data("{}".utf8)),
            ToolCall(id: "three", name: "plan", arguments: Data(
                #"{"request":"Write the document","rows":[{"title":"Write"}]}"#.utf8)),
            ToolCall(id: "four", name: "end", arguments: Data(#"{"outcome":"completed"}"#.utf8))
        ]
        let messages = try await loop.results(of: calls).map(\.text)
        return (messages, records)
    }

    private struct Instructions: LoopInstructionComposing {
        func systemText(role: String?, hasTools: Bool, tools: String) -> String { tools }
    }

}
