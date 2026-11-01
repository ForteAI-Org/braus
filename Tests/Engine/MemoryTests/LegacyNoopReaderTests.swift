import EngineCore
import Memory
import Testing

struct LegacyNoopReaderTests {
    @Test func listingEquivalence() {
        for tool in AgentTool.allCases {
            for kind in ActOutcomeKind.allCases {
                #expect(ProcedureSegmentation.isListing(tool: tool, resultKind: kind)
                    == (tool == .menu && kind == .actedNoop))
            }
            #expect(!ProcedureSegmentation.isListing(tool: tool, resultKind: nil))
        }
    }
}
