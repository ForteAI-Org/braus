import AutomationMCP
import AutomationRuntime
import ChatCore
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing
@testable import Turn

@MainActor
struct ManualSmokeProviderTests {
    @Test(arguments: ["S1", "S2"])
    func preparedChildUsesOnlyTheRealPublishedSurface(_ scenario: String) async throws {
        let root = try testTurnRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "codex")
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/manual-smoke-provider.py")
        try FileManager.default.copyItem(at: fixture, to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try Data("""
        from pathlib import Path
        import json
        def write(path, value):
            Path(path).write_text(json.dumps(value))
        def app_oracle(kit, bundle, process):
            return {'has_window':True, 'applications':[{'windows':[{'title':'A window'},{'title':'B window'}]}]}
        """.utf8).write(to: root.appending(path: "smoke_support.py"))
        let context: JSONValue = .object(["case": .string(scenario), "kit": .string("unused-offline"),
            "nonce": .string(UUID().uuidString), "windows_ready": .bool(true), "windows_reason": .string(""),
            "window_a": .string("A window"), "window_b": .string("B window"), "real_cli_frontdoor": .bool(false)])
        try JSONValue.canonicalEncoder().encode(context).write(to: root.appending(path: "context.json"))
        let session = ManualSmokeApplication()
        let tools = AutomationTools(session: session, channels: [.native, .web])
        let host = TestTurnHost()
        let runner = TurnRunner(tools: tools, configuration: .init(workingDirectory: root,
            bridgeExecutable: URL(filePath: "/bin/cat"), allowsSuspension: false,
            closesSessionOnEnd: false), host: host)
        _ = try await runner.run(.init(prompt: "Verify explicit opening and lifecycle", route: .commandLine(provider: .codex,
            executable: script, model: nil, effort: nil, environment: [:], allowsWebSearch: false))) { _ in }
        let proof = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appending(path: "functional.json")))
        #expect(proof["functional"].string == "passed", "\(proof)")
        #expect(proof["cleanup"].string == "passed", "\(proof)")
        #expect(proof["release"]["close_answer_received"].bool == true)
        #expect(proof["release"]["status_answer_received"].bool == true)
        #expect(proof["release"]["session_absent"].bool == true)
        #expect(proof["release"]["cleanup_warning_absent"].bool == true)
        #expect(proof["process_exit_claimed"].bool == false)
        let trace = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: root.appending(path: "tool-trace.json")))
        let names = Set(tools.toolDefinitions.compactMap { $0["name"].string })
        #expect(trace.allSatisfy { names.contains($0["tool"].string ?? "") })
        #expect(!trace.contains { ["status", "close_session"].contains($0["tool"].string ?? "") })
        #expect(trace.contains { $0["tool"].string == "call" && $0["arguments"]["name"].string == "close_session" })
        #expect(session.closeCount == 1 && session.id == nil && session.actions == 0)
        if scenario == "S1" { #expect(session.opened == ["com.apple.Maps"]) }
        else {
            #expect(proof["failed_B_retains_A"].string == "passed")
            #expect(proof["normal_switch_and_other_window"].string == "passed")
            #expect(session.opened.count == 7)
        }
        print("MANUAL_SMOKE_CONTRACT scenario=\(scenario) actual_child=true actual_host=true fake_app=true requests=\(trace.count)")
        try await runner.close()
    }
}

/// ManualSmokeApplication preserves IDs on resume/failure and records zero allowed gestures.
@MainActor
private final class ManualSmokeApplication: AutomationSessionOperating {
    var id: UUID?
    var memoryApplication: String?
    var title = "Smoke window"
    var opened: [String] = []
    var closeCount = 0
    var actions = 0

    func resolvedBundleID(of application: String) async -> String? { application }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        opened.append(application)
        if application.hasPrefix("org.braus.smoke.definitely-missing-") {
            throw AutomationFailure("Synthetic missing application", beforeDispatch: true)
        }
        if application != memoryApplication || (window != nil && window != title) { id = UUID() }
        memoryApplication = application
        if let window { title = window }
        return try await observe()
    }

    func observe() async throws -> SceneSnapshot {
        SceneSnapshot(bundleID: memoryApplication ?? "", appName: "Smoke", windowTitle: title,
            viewportPixelSize: .init(width: 400, height: 200), elements: [])
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        actions += 1
        throw AutomationFailure("No gesture belongs to this fixture")
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        actions += 1
        throw AutomationFailure("No selection belongs to this fixture")
    }

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        actions += 1
        throw AutomationFailure("No input belongs to this fixture")
    }

    func close() async { closeCount += 1; id = nil; memoryApplication = nil }
}
