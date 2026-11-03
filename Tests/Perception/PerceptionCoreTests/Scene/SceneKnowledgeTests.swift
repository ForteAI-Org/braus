import PerceptionCore
import Testing

@Suite("Scene knowledge lines")
struct SceneKnowledgeTests {

    @Test
    func statusAloneIsNoLine() {
        for status in [SceneKnowledge.Status.nothing, .unrecognized, .unavailable, .applied] {
            #expect(SceneKnowledge(status: status).lines.isEmpty)
        }
        for status in [SceneKnowledge.Status.nothing, .unrecognized, .unavailable] {
            #expect(SceneKnowledge(status: status, window: ["unused"]).lines.isEmpty)
        }
        #expect(SceneKnowledge(status: .applied, window: ["first operation", "second operation"]).lines == [
            "memory: what was learned in this window's state is shown",
            "  window: first operation",
            "  window: second operation",
        ])
    }
}
