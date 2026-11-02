import AutomationRuntime
import Foundation
import ModelTransports
import Synchronization

/// TurnRoundCounter counts model requests without changing the loop's event stream.
nonisolated final class TurnRoundCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func begin(maximum: Int?) throws {
        try value.withLock { value in
            if let maximum, value >= maximum { throw AutomationFailure("The turn reached its round limit.") }
            value += 1
        }
    }
}

/// CountedTurnTransport delegates transport behavior and records each model request.
nonisolated struct CountedTurnTransport: ModelTransport {
    let transport: any ModelTransport
    let counter: TurnRoundCounter
    let budget: TurnBudget
    var streaming: StreamingSupport { transport.streaming }
    var requestTimeout: TimeInterval { transport.requestTimeout }
    func capabilities() async throws -> ModelCapabilities { try await transport.capabilities() }
    func complete(prompt: String, schema: Data, timeout: TimeInterval) async throws -> (text: String, usage: ModelUsage) {
        try counter.begin(maximum: budget.maximumRounds)
        return try await transport.complete(prompt: prompt, schema: schema, timeout: timeout)
    }
    func converse(_ messages: [TurnMessage], tools: [ToolDefinition], timeout: TimeInterval)
        throws -> AsyncThrowingStream<TurnEvent, any Error> {
        try counter.begin(maximum: budget.maximumRounds)
        return try transport.converse(messages, tools: tools, timeout: timeout)
    }
}
