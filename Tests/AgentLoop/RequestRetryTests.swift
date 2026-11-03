import ChatCore
import Foundation
import ModelTransports
import Testing
@testable import AgentLoop

@Suite struct RequestRetryTests {
    @Test func decisionTable() {
        for retryable in [false, true] {
            let failure: RequestRetry.Failure = retryable ? .retryable(status: 429) : .notRetryable
            for attempt in 1...3 {
                for anyToolRan in [false, true] {
                    for suspended in [false, true] {
                        let expected: RequestRetry.Decision
                        if !retryable || anyToolRan { expected = .fail }
                        else if suspended { expected = .suspend }
                        else if attempt == 3 { expected = .fail }
                        else { expected = .retry(after: .seconds(attempt == 1 ? 1 : 3)) }
                        #expect(RequestRetry.decide(failure, attempt: attempt, anyToolRan: anyToolRan,
                                                    isSuspended: suspended) == expected)
                    }
                }
            }
        }
    }

    @Test func classification() {
        for status in [429, 529, 500, 503] {
            #expect(RequestRetry.classify(ProviderError.http(status: status, message: "test"))
                == .retryable(status: status))
        }
        for status in [400, 401] {
            #expect(RequestRetry.classify(ProviderError.http(status: status, message: "test")) == .notRetryable)
        }
        #expect(RequestRetry.classify(URLError(.timedOut)) == .retryable(status: nil))
        #expect(RequestRetry.classify(URLError(.cancelled)) == .notRetryable)
        #expect(RequestRetry.classify(CancellationError()) == .notRetryable)
    }

    @Test @MainActor func usageKeepsPartsWithoutAddingThemTwice() {
        let tokens = ModelToolLoop.tokens(of: ModelUsage(inputTokens: 100, outputTokens: 80, duration: .zero,
            cacheReadTokens: 900, cacheWriteTokens: 200, cacheWriteHourTokens: 50, reasoningTokens: 30))
        #expect(tokens.input == 1200)
        #expect(tokens.cacheReads == 900)
        #expect(tokens.cacheWrites == 200)
        #expect(tokens.cacheWritesHour == 50)
        #expect(tokens.output == 80)
        #expect(tokens.reasoning == 30)
    }
}
