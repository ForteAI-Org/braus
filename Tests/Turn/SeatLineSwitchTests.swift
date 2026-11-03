import AutomationMCP
import AutomationRuntime
import Foundation
import ModelTransports
import Switches
import Testing
import Turn

@MainActor
@Suite("TurnTests SeatLine switch")
struct SeatLineSwitchTests {
    @Test func incompatibleSurfaceIsRejectedBeforeAdmission() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let transport = TurnTestTransport([])
        await SwitchBoard.$testing.withValue(SwitchBoard(values: ["seat_line": "v2"])) {
            await #expect(throws: SeatLineError.incompatibleSurface) {
                try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
                    contextWindow: nil))) { _ in }
            }
        }
        #expect(host.began == 0)
        #expect(transport.messages.isEmpty)
        try await runner.close()
    }

    @Test(arguments: [SeatLineArm.v1, .v2])
    func frozenArmSelectsTextsAndPrompt(_ arm: SeatLineArm) async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let transport = TurnTestTransport([[.delta("ok"), .completed(.init(inputTokens: 1,
            outputTokens: 1, duration: .zero))]])
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: ["seat_line": arm.rawValue, "tool_surface": "v2"])) {
            _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
                contextWindow: nil))) { _ in }
        }
        let messages = try #require(transport.messages.first)
        let system = try #require(messages.first).text
        #expect(system.contains("call status and observe") == (arm == .v1))
        #expect(system.contains("windows, then open_session") == (arm == .v1))
        #expect(system.contains("which replaces the status call") == (arm == .v1))
        let prompt = try #require(messages.last).text
        if arm == .v1 {
            #expect(prompt == "Braus seat: no session is open.\n\nHello")
        } else {
            #expect(prompt == "<braus_state>\nsession: closed\ntask: none\n</braus_state>\n\nHello")
        }
        try await runner.close()
    }
}
