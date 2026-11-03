import Memory
import Testing
@testable import braus

struct SchemaMigration22CLIStateTests {
    @Test func statesUseClosedReasonCodes() {
        #expect(MemoryCommand.reasonCode(for: .usable) == "requalified")
        #expect(MemoryCommand.reasonCode(for: .toReevaluate) == "judged_wrong")
        #expect(MemoryCommand.reasonCode(for: .retired) == "retired_by_person")
    }
}
