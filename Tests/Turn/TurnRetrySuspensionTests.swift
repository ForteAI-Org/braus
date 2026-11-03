import ChatCore
import Foundation
import ModelTransports
import Synchronization
import Testing
import Turn

@MainActor
@Suite("TurnTests retry suspension") struct TurnRetrySuspensionTests {
    @Test func retryableFailureDuringTakeoverKeepsTheEpisode() async throws {
        let root = try testTurnRoot()
        defer { do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) } }
        let host = TestTurnHost()
        defer { withExtendedLifetime(host) {} }
        let runner = testTurnRunner(host: host, root: root)
        let transport = SuspendedRetryTransport()
        let run = Task { try await runner.run(.init(prompt: "Hello", route: .modelLoop(transport: transport, contextWindow: nil))) { _ in } }
        let deadline = ContinuousClock.now + .seconds(5)
        while transport.count == 0 {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        let token = try runner.suspend()
        await #expect(throws: TurnSuspended.self) { try await run.value }
        #expect(transport.count == 1)
        #expect(await runner.waitForCallsToDrain(within: .seconds(1)))
        #expect(try runner.suspend() == token)
        try runner.end(token)
        try await runner.close()
    }
}

private final class SuspendedRetryTransport: ModelTransport {
    private struct State {
        var count = 0
    }
    private let state = Mutex(State())
    var count: Int { state.withLock { $0.count } }
    var streaming: StreamingSupport { .incremental }
    func complete(prompt: String, schema: Data, timeout: TimeInterval) async throws -> (text: String, usage: ModelUsage) {
        throw ProviderError.badResponse("unused")
    }
    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        state.withLock { $0.count += 1 }
        return AsyncThrowingStream { $0.finish(throwing: ProviderError.http(status: 429, message: "test")) }
    }
}
