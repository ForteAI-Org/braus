import AutomationMCP
import AutomationRuntime
import ChatCore
import Foundation
import ModelTransports
import Switches
import Testing
import Turn

@MainActor
@Suite("TurnTests Batch switch")
struct BatchSwitchTests {
    @Test(arguments: ["tool", "in_gestures"], [false, true])
    func incompatibleCycleIsRejectedBeforeAdmission(form: String, usesCommandLine: Bool) async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let transport = TurnTestTransport([])
        let route: TurnRequest.Route = usesCommandLine
            ? .commandLine(provider: .codex, executable: URL(filePath: "/bin/cat"), model: nil,
                           effort: nil, environment: [:], allowsWebSearch: false)
            : .modelLoop(transport: transport, contextWindow: nil)
        for cycle: String? in [nil, "v1"] {
            var values = ["batch": "v2", "batch_form": form]
            values["task_cycle"] = cycle
            await SwitchBoard.$testing.withValue(SwitchBoard(values: values)) {
                await #expect(throws: BatchConfigurationError.taskCycleV2Required) {
                    try await runner.run(.init(prompt: "Hello", route: route)) { _ in }
                }
            }
            #expect(host.began == 0)
            #expect(transport.messages.isEmpty)
        }
        try await runner.close()
    }

    @Test(arguments: ["tool", "in_gestures"])
    func compatibleCycleRuns(form: String) async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let transport = TurnTestTransport([[.delta("ok"), .completed(.init(inputTokens: 1,
            outputTokens: 1, duration: .zero))]])
        try await SwitchBoard.$testing.withValue(SwitchBoard(values: [
            "batch": "v2", "batch_form": form, "task_cycle": "v2"
        ])) {
            _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
                contextWindow: nil))) { _ in }
        }
        #expect(host.began == 1)
        #expect(transport.messages.count == 1)
        try await runner.close()
    }

    @Test func defaultBatchMatchesExplicitV1() {
        for cycle in ["v1", "v2"] {
            for form in ["tool", "in_gestures"] {
                let values = ["task_cycle": cycle, "batch_form": form]
                let implicit = SwitchBoard.$testing.withValue(SwitchBoard(values: values)) {
                    #expect(!BatchMode.isEnabled)
                    return AutomationTools.definitions(for: .all)
                }
                var explicitValues = values
                explicitValues["batch"] = "v1"
                let explicit = SwitchBoard.$testing.withValue(SwitchBoard(values: explicitValues)) {
                    AutomationTools.definitions(for: .all)
                }
                #expect(implicit == explicit)
            }
        }
    }
}
