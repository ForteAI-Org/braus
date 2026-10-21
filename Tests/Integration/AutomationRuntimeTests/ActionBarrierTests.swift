import AutomationRuntime
import LocalMCP
import Testing

@MainActor
@Suite("A refusal stops other actions in its context")
struct ActionBarrierTests {
    @Test("Only the same call can be reconsidered; status and cleanup remain available")
    func refusalAdmission() {
        let barrier = ActionBarrier()
        let arguments: JSONValue = .object(["app": .string("mail"), "verb": .string("send")])
        barrier.note(.refusedByPerson(.null), of: "app_call", arguments)
        #expect(barrier.isClosed)
        #expect(barrier.refusal(of: "act", .object([:])) != nil)
        #expect(barrier.refusal(of: "app_call", arguments) == nil)
        #expect(barrier.refusal(of: "app_call", .object(["verb": .string("delete")])) != nil)
        for tool in ["status", "close_session", "memory_task"] {
            #expect(barrier.refusal(of: tool, .object([:])) == nil)
        }
    }

    @Test("Only consent to the refused call reopens its context")
    func matchingConsent() {
        let barrier = ActionBarrier()
        let arguments: JSONValue = .object(["title": .string("Synthetic note")])
        barrier.note(.refusedByPerson(.null), of: "app_call", arguments)
        barrier.note(.notDecided(.null), of: "app_call", arguments)
        #expect(barrier.isClosed)
        barrier.note(.consented(.null), of: "act", arguments)
        #expect(barrier.isClosed)
        barrier.note(.consented(.null), of: "app_call", arguments)
        #expect(!barrier.isClosed)
    }

    @Test("A refusal does not affect another context")
    func contextIsolation() {
        let first = ActionBarrier()
        first.note(.refusedByPerson(.null), of: "app_call", .object([:]))
        #expect(first.isClosed)
        #expect(!ActionBarrier().isClosed)
    }
}
