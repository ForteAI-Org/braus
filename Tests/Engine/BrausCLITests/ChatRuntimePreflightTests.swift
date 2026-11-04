import Foundation
import LocalMCP
import Testing

@MainActor
@Suite("CLI runtime preflight", .serialized)
struct ChatRuntimePreflightTests {
    @Test func activeCyclePassesPreflightAndWritesActualConfiguration() async throws {
        let root = URL.temporaryDirectory.appending(path: "chat-runtime-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let profile = root.appending(path: "profile.json")
        try JSONSerialization.data(withJSONObject: ["preset": "cli"]).write(to: profile)
        let expected = root.appending(path: "expected.json")
        try JSONSerialization.data(withJSONObject: ["runtime": ["contract": "braus-t2-single-path"]]).write(to: expected)
        let evidence = root.appending(path: "evidence")
        let result = try await ChatChildProcess.run(provider: "codex", options: [
            "--profile", profile.path, "--preflight", expected.path, "--evidence", evidence.path
        ], messages: "Reply briefly without tools.\n")
        #expect(result.status == 0, "\(result.output)")
        #expect(result.arguments.count == 1)
        let configuration = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf:
            evidence.appending(path: "01/runtime.json")))
        #expect(configuration["contract"].string == "braus-t2-single-path")
        #expect(configuration["tool_attempts"].object?.isEmpty == true)
        let names = configuration["served_tools"].array?.compactMap(\.string) ?? []
        #expect(names.contains("plan") && names.contains("end"))
        #expect(!names.contains("memory_task"))

        try Data(#"{"runtime":{"contract":"wrong-build"}}"#.utf8).write(to: expected)
        let mismatch = try await ChatChildProcess.run(provider: "codex", options: [
            "--profile", profile.path, "--preflight", expected.path
        ], messages: "Reply briefly without tools.\n")
        #expect(mismatch.status != 0)
        #expect(mismatch.arguments.isEmpty)
        #expect(mismatch.output.contains("The preflight does not match"))
    }
}


extension ChatRuntimePreflightTests {
    @Test func statusCommandDelegatesWithoutStartingAProvider() async throws {
        for provider in ["claude", "codex"] {
            let result = try await ChatChildProcess.run(provider: provider, prompt: "/status")
            #expect(result.status == 0, "\(result.output)")
            #expect(result.arguments.isEmpty, "A local command must not start the provider")
            #expect(result.output.contains("permissions") && result.output.contains("session"))
            #expect(!result.output.contains("Unknown tool") && !result.output.contains("Chat error:"))
        }
    }
}
