import ChatCore
import Foundation
import Testing

struct ProviderTurnToolLoadingTests {
    @Test func providerTurnContainsInputsWithoutAnImplementationSelector() {
        let turn = ProviderTurn(provider: .claude, model: "test-model", sessionID: nil,
            prompt: "Read", instructions: "Use the current catalogue", bridgeExecutable: "/bridge",
            connectionFile: "/connection", workingDirectory: "/work")
        let fields = Set(Mirror(reflecting: turn).children.compactMap { $0.label })
        #expect(!fields.contains("toolLoading") && !fields.contains("loading"))
        #expect(turn.prompt == "Read" && turn.instructions == "Use the current catalogue")
        #expect(!turn.isCompaction && !turn.allowsWebSearch)
    }
}
