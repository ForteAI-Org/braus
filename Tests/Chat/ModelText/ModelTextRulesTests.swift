import AutomationRuntime
import Foundation
import Testing
@testable import AutomationMCP

struct ModelTextNamesTests {
    @Test
    func names() {
        #expect(validate(ModelText.catalogue, context: RuleContext()).filter { $0.code == .name }.isEmpty)
        #expect(validate([specimen("Call observe with expected_value.")], context: RuleContext()).isEmpty)
        #expect(validate([specimen("Call missing_tool.")], context: RuleContext()).contains { $0.code == .name })
    }
}

struct ModelTextValuesTests {
    @Test
    func values() {
        #expect(validate(ModelText.catalogue, context: RuleContext()).filter { $0.code == .value }.isEmpty)
        #expect(validate([specimen("Count {count}.")], context: RuleContext()).isEmpty)
        for value in RuleContext().sentinels {
            #expect(validate([specimen(value)], context: RuleContext()).contains { $0.code == .value })
        }
        let slots: [ModelTextSlot] = [.toolName("observe"), .count(3), .revision(2)]
        #expect(slots.count == 3)
        #expect(ModelText.render(.init(rawValue: "memory_task_tool.needLimit.v1"), ["count": .count(3)]) == "3")
    }
}

struct ModelTextStyleTests {
    @Test
    func style() {
        #expect(validate(ModelText.catalogue, context: RuleContext()).filter { $0.code == .style }.isEmpty)
        #expect(validate([specimen("Read the result · wait ⇒ continue… ⟦secret⟧ ~")], context: RuleContext()).isEmpty)
        for word in ["Chrome", "IMPORTANT", "qualified", "handback", "readback", "oracle", "producer", "candidate", "tract", "MacDriver", "P2-12", "p2-12", "R-X-01", "r-x-01", "Seat", "—", "é"] {
            #expect(validate([specimen(word)], context: RuleContext()).contains { $0.code == .style })
        }
        #expect(validate([specimen("Seat ready", delivery: .seatLine)], context: RuleContext()).isEmpty)
        #expect(validate([specimen("Read the tractable result.")], context: RuleContext()).isEmpty)
    }
}

struct ModelTextContradictionTests {
    @Test
    func rules() {
        for bits in 0..<8 {
            var context = RuleContext()
            if bits & 1 != 0 { context.channels.insert(.native) }
            if bits & 2 != 0 { context.channels.insert(.web) }
            if bits & 4 != 0 { context.channels.insert(.adapters) }
            #expect(validate(ModelText.catalogue, context: context).filter { $0.code == .contradiction }.isEmpty)
            let seat = validate([specimen("All actions stay on the background Seat.")], context: context)
            #expect(seat.contains { $0.code == .contradiction } == (bits & 3 != 0))
        }
        #expect(validate([specimen("Call observe. Use act. observe then act.")], context: RuleContext()).isEmpty)
        for phrase in ["Call absent.", "Use absent.", "observe then absent", "Never call absent.", "Discover windows then open_session."] {
            #expect(validate([specimen(phrase)], context: RuleContext()).contains { $0.code == .contradiction })
        }
        #expect(validate([specimen("Never call act.")], context: RuleContext()).isEmpty)
        var context = RuleContext()
        context.requiresWindow = true
        #expect(validate([specimen("Discover windows then open_session.")], context: context).isEmpty)
        let observe = specimen("Observe.", delivery: .toolAnswer(tool: "act"))
        #expect(validate([observe], context: context).isEmpty)
        context.hasAfterScene = true
        #expect(validate([observe], context: context).contains { $0.code == .contradiction })
        context.hasAfterScene = false
        context.recovery = "stop"
        for word in ["Observe", "Perceive", "Re-read", "Look again"] {
            #expect(validate([specimen(word, delivery: .toolAnswer(tool: "act"))], context: context).contains { $0.code == .contradiction })
        }
        let first = specimen("Before you answer, wait.", key: "first")
        let second = specimen("In your next call, wait.", key: "second")
        #expect(validate([first], context: context).isEmpty)
        #expect(validate([first, second], context: context).contains { $0.code == .contradiction })
        let enumeration = specimen("state is one of on or off.")
        #expect(validate([enumeration], context: context).isEmpty)
        #expect(validate([enumeration, enumeration], context: context).contains { $0.code == .contradiction })
    }
}

struct ModelTextLegacyTests {
    @Test
    func frozenBytes() throws {
        let url = modelTextRoot.appending(path: "Tests/Chat/Fixtures/model-text-legacy.json")
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let legacy = ModelText.catalogue.filter(\.legacy)
        #expect(Set(legacy.map { $0.key.rawValue }) == legacyKeys)
        #expect(Set(expected.keys) == legacyKeys)
        for entry in legacy {
            let text = try #require(expected[entry.key.rawValue])
            #expect(Data(text.utf8) == Data(entry.text.utf8))
        }
    }
}
