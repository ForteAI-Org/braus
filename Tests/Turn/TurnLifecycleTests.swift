import AutomationMCP
import ChatCore
import Foundation
import ModelTransports
import Testing
@testable import Turn

@MainActor
@Suite("TurnTests lifecycle")
struct TurnLifecycleTests {
    @Test(arguments: [true, false], [false, true])
    func failedOrStoppedTurnsRespectSessionOwnership(_ closesSession: Bool, _ stops: Bool) async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let session = TurnTestSession()
        let runner = TurnRunner(tools: AutomationTools(session: session), configuration: .init(
            workingDirectory: root, bridgeExecutable: URL(filePath: "/bin/cat"),
            allowsSuspension: closesSession, closesSessionOnEnd: closesSession), host: host)
        let failure = ProviderFailure(kind: .turnError, message: "Original failure")
        let transport = TurnTestTransport(
            [[.delta("Answer"), .completed(.init(inputTokens: 1, outputTokens: 1, duration: .zero))]],
            failure: stops ? nil : failure
        )
        do {
            _ = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
                contextWindow: nil))) { event in
                if stops, case .provider(.assistant) = event { runner.stop(marksTaskInterrupted: false) }
            }
            Issue.record("The turn should fail or stop.")
        } catch {
            if stops { #expect(error is CancellationError) }
            else { #expect((error as? ProviderFailure)?.message == failure.message) }
        }
        #expect(session.closes == (closesSession ? 1 : 0))
        await runner.retire()
        #expect(session.closes == (closesSession ? 2 : 1))
        try await runner.close()
    }

    @Test func releasedHostRefusesNewWorkAndAllowsCleanup() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        var host: TestTurnHost? = TestTurnHost()
        weak let borrowed = host
        let runner = testTurnRunner(host: try #require(host), root: root)
        host = nil
        #expect(borrowed == nil)
        await #expect(throws: CancellationError.self) {
            try await runner.run(.init(prompt: "Hello", route: .modelLoop(
                transport: TurnTestTransport([]), contextWindow: nil))) { _ in }
        }
        runner.stop(marksTaskInterrupted: false)
        try await runner.close()
    }

    @Test func admittedCallRetainsItsHostUntilTheScopeEnds() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        var host: TestTurnHost? = TestTurnHost()
        weak let borrowed = host
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        host?.scope = {
            entered = true
            await withCheckedContinuation { release = $0 }
        }
        let runner = testTurnRunner(host: try #require(host), root: root)
        let transport = TurnTestTransport([
            [.toolCall(.init(id: "one", name: "status", arguments: Data("{}".utf8))),
             .completed(.init(inputTokens: 1, outputTokens: 1, duration: .zero))],
            [.completed(.init(inputTokens: 1, outputTokens: 1, duration: .zero))]
        ])
        let run = Task {
            try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
                contextWindow: nil))) { _ in }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        host = nil
        #expect(borrowed != nil)
        release?.resume()
        _ = try await run.value
        #expect(borrowed == nil)
        try await runner.close()
    }

    private struct CleanupFailure: Error, Equatable {}

    @Test(arguments: ["success", "failure", "stop"])
    func endpointCleanupPreservesTheTurnResult(_ ending: String) async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let script = root.appending(path: "provider.py")
        try Data("""
        #!/usr/bin/python3
        import json, sys
        sys.stdin.read()
        print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 's1'}))
        print(json.dumps({'type': 'result', 'result': 'ok', 'is_error': \(ending == "failure" ? "True" : "False")}))
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let host = TestTurnHost()
        let session = TurnTestSession()
        var removals = 0
        let runner = TurnRunner(tools: AutomationTools(session: session), configuration: .init(
            workingDirectory: root, bridgeExecutable: script, allowsSuspension: false,
            closesSessionOnEnd: false), host: host, reminder: { nil }, removeConnectionFile: { _ in
                removals += 1
                throw CleanupFailure()
            })
        do {
            let outcome = try await runner.run(.init(prompt: "Hello", route: .commandLine(provider: .claude,
                executable: script, model: nil, effort: nil, environment: [:], allowsWebSearch: false))) { event in
                if ending == "stop", case .provider(.completed) = event { runner.stop(marksTaskInterrupted: false) }
            }
            #expect(ending == "success")
            #expect(outcome.session == "s1")
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf:
                root.appending(path: "codex-instructions.json"))) as? [String: String]
            #expect(record?["session"] == "s1")
            #expect(record?["instructions"] == TurnInstructions.compose(role: nil))
        } catch let error as ProviderFailure where ending == "failure" {
            #expect(error == .init(kind: .turnError, message: "ok", exitStatus: 0))
        } catch is CancellationError where ending == "stop" {
            #expect(ending == "stop")
        }
        #expect(removals == 1)
        #expect(session.closes == 0)
        await #expect(throws: CleanupFailure.self) { try await runner.close() }
        try await runner.close()
        #expect(removals == 1)
    }
}
