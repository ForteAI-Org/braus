import ChatCore
import Foundation
import Switches
import Testing

struct ProviderTurnToolLoadingTests {
    @Test func loadingHasStableStringEncodingAndDefault() throws {
        for loading in [ToolLoading.upfront, .harnessSearch] {
            #expect(try JSONDecoder().decode(ToolLoading.self, from: JSONEncoder().encode(loading)) == loading)
            #expect(SwitchBoard(values: ["tool_loading": loading.rawValue])
                .arm("tool_loading", default: ToolLoading.upfront) == loading)
        }
        #expect(SwitchBoard().arm("tool_loading", default: ToolLoading.upfront) == .upfront)
    }
}
