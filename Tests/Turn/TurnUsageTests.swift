import LocalMCP
import ChatCore
import Foundation
import Testing
@testable import Turn

@Suite("Turn usage")
struct TurnUsageTests {
    @Test func tokenKindsDoNotCountReasoningTwice() {
        let usage = TurnTokenUsage(.init(input: 1000, cacheReads: 100, cacheWrites: 500,
                                        cacheWritesHour: 200, output: 300, reasoning: 120))
        #expect(usage.uncachedInput == 400)
        #expect(usage.cacheWrites5m == 300)
        #expect(usage.cacheWrites1h == 200)
        #expect(usage.cacheReads == 100)
        #expect(usage.output == 300)
        #expect(usage.reasoning == 120)
        #expect(usage.total == 1300)
    }

    @Test func sessionTotalsBecomeProcessCountsBeforeAdding() {
        let first = ProviderUsage(tokens: .init(input: 1000), isSessionTotal: true)
        let reminder = ProviderUsage(tokens: .init(input: 1150), isSessionTotal: true)
        let a = TurnTokenUsage.own(first, session: "s1", previous: nil)
        let b = TurnTokenUsage.own(reminder, session: "s1", previous: ("s1", first.tokens))
        #expect((TurnTokenUsage(a) + TurnTokenUsage(b)).total == 1150)
        #expect(TurnTokenUsage.own(.init(tokens: .init(input: 1600), isSessionTotal: true),
                                  session: "s1", previous: ("s1", first.tokens)).input == 600)
        #expect(TurnTokenUsage.own(.init(tokens: .init(input: 400), isSessionTotal: true),
                                  session: "s2", previous: ("s1", first.tokens)).input == 400)
        #expect(TurnTokenUsage.own(.init(tokens: .init(input: 400), isSessionTotal: true),
                                  session: "s1", previous: ("s1", first.tokens)).input == 400)
    }

    @Test func oldTokenRecordsDecodeWithoutHourWrites() throws {
        let tokens = try JSONDecoder().decode(ProviderUsage.Tokens.self,
            from: Data(#"{"input":10,"cacheReads":2,"cacheWrites":3,"output":4,"reasoning":1}"#.utf8))
        #expect(tokens.cacheWritesHour == 0)
    }

    @Test func endingsKeepObservedFailureAndHandover() {
        #expect(TurnEnding(thrown: CancellationError(), handedOver: false,
                           isHandedOver: true, reportedFailure: nil) == .handedToPerson)
        #expect(TurnEnding(thrown: nil, handedOver: false,
                           isHandedOver: false, reportedFailure: "failed") == .failed(reason: "failed"))
    }
}
