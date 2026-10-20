import EngineCore
import Memory
import Testing

@Suite("Reconciliation reads prove a specific effect")
struct ReconciliationPolicyTests {
    @Test("existence is insufficient for an arbitrary state change")
    func adapterEffect() throws {
        let identifier = try StructuredField(path: "/reminders/0/id", kind: .text, text: "r1")
        let completed = try StructuredField(path: "/reminders/0/completed", kind: .boolean, text: "true")
        #expect(ReconciliationPolicy.supportsAdapter(adapter: "reminders", verb: "complete_reminder", resource: "r1",
                                                       results: [identifier, completed], finding: .happened))
        #expect(!ReconciliationPolicy.supportsAdapter(adapter: "reminders", verb: "complete_reminder", resource: "r1",
                                                        results: [identifier], finding: .happened))
        #expect(!ReconciliationPolicy.supportsAdapter(adapter: "reminders", verb: "complete_reminder", resource: "r1",
                                                        results: [identifier, completed], finding: .notHappened))
        #expect(!ReconciliationPolicy.supportsAdapter(adapter: "notes", verb: "create_unknown_effect", resource: "r1",
                                                        results: [identifier], finding: .happened))
    }

}
