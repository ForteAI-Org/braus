import ChatCore
import LocalMCP
import Foundation
import ModelTransports
import Testing
import Turn

@MainActor
@Suite("TurnTests suspension")
struct TurnSuspensionContractTests {
    @Test func disabledSuspensionHasNoEffects() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root, allowsSuspension: false)
        #expect(throws: TurnRefusal.suspensionUnavailable) { try runner.suspend() }
        #expect(runner.contextState.resets == 0)
        #expect(host.stopping == 0)
        try await runner.close()
    }

    @Test func episodeRefusesWorkAndRequiresItsCurrentToken() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let token = try runner.suspend()
        #expect(try runner.suspend() == token)
        #expect(runner.contextState.lastReset == .personHadApp)
        let request = TurnRequest(prompt: "Hello", route: .modelLoop(transport: TurnTestTransport([]), contextWindow: nil))
        await #expect(throws: TurnRefusal.personHasControl) { try await runner.run(request) { _ in } }
        await #expect(throws: TurnRefusal.personHasControl) { try await runner.compact(request, trigger: .manual) }
        #expect(host.began == 0)
        #expect(throws: TurnRefusal.staleEpisode) { try runner.end(.init(id: UUID())) }
        try runner.end(token)
        #expect(runner.contextState.resets == 2)
        let next = try runner.suspend()
        runner.stop(marksTaskInterrupted: false)
        await runner.waitForCleanup()
        #expect(throws: TurnRefusal.staleEpisode) { try runner.end(next) }
        try await runner.close()
    }
}

extension TurnSuspensionContractTests {
    @Test(arguments: ["observe", "act"])
    func admittedReadIsInterruptedAndActionDrains(_ name: String) async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        var entered = false
        var finished = false
        var release: CheckedContinuation<Void, Never>?
        host.scope = {
            entered = true
            if name == "observe" { try await Task.sleep(for: .seconds(30)) }
            else { await withCheckedContinuation { release = $0 } }
            finished = true
        }
        let runner = testTurnRunner(host: host, root: root)
        let transport = TurnTestTransport([[
            .toolCall(.init(id: "one", name: name, arguments: Data("{}".utf8))),
            .completed(.init(inputTokens: 10, outputTokens: 2, duration: .zero))
        ]])
        let run = Task {
            try await runner.run(.init(prompt: "Check", route: .modelLoop(transport: transport, contextWindow: nil))) { _ in }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        let token = try runner.suspend()
        #expect(throws: TurnRefusal.staleEpisode) { try runner.end(token) }
        if name == "act" {
            #expect(await runner.waitForCallsToDrain(within: .milliseconds(20)) == false)
            #expect(!finished)
            release?.resume()
        }
        await #expect(throws: TurnSuspended.self) { try await run.value }
        #expect(await runner.waitForCallsToDrain(within: .seconds(1)))
        #expect(finished == (name == "act"))
        try runner.end(token)
        #expect(runner.contextState.lastReset == .personHadApp)
        try await runner.close()
    }
}

extension TurnSuspensionContractTests {
    @Test func theNextTurnDoesNotCountThePersonsEpisode() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        let runner = testTurnRunner(host: host, root: root)
        let token = try runner.suspend()
        try await Task.sleep(for: .milliseconds(20))
        try runner.end(token)
        let started = ContinuousClock.now
        let transport = TurnTestTransport([[.completed(.init(inputTokens: 1, outputTokens: 1, duration: .zero))]])
        let outcome = try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport,
            contextWindow: nil))) { _ in }
        #expect(outcome.duration <= started.duration(to: .now))
        #expect(outcome.rounds == 1)
        try await runner.close()
    }
}
