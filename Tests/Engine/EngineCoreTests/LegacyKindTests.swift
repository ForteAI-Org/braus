import EngineCore
import Testing

struct LegacyKindTests {
    @Test func defaultConversion() {
        for kind in ActOutcomeKind.allCases where kind != .dryRun {
            #expect(Outcome.converting(kind, check: nil, notSent: nil, noop: nil,
                                       sceneAttached: false).legacyKind == kind)
        }
    }
}
