import EngineCore
import Testing

struct OutcomeRowTests {
    @Test func exactRowsAndRoundTrip() {
        #expect(Outcome(gesture: .notSent, effect: .notApplicable,
                        recovery: .changeTarget(.notFound)).row == "not_sent · not_applicable · change_target(not_found)")
        let effects: [Outcome.Effect] = [.confirmed, .absent, .notApplicable]
            + Outcome.Unknown.allCases.map { .unknown($0) }
        let recoveries: [Recovery] = [.continue, .observe, .doNotRepeat, .askPerson, .retry]
            + Recovery.Blocked.allCases.map { .changeTarget($0) }
        let maximum = (Outcome.Gesture.allCases.map { $0.rawValue.count }.max() ?? 0)
            + (effects.map { $0.text.count }.max() ?? 0)
            + (recoveries.map { $0.text.count }.max() ?? 0) + 6
        #expect(maximum == 64)
        for gesture in Outcome.Gesture.allCases {
            for effect in effects {
                for recovery in recoveries {
                    let value = Outcome(gesture: gesture, effect: effect, recovery: recovery)
                    #expect(value.row.count <= maximum)
                    #expect(Outcome.parse(value.row) == value)
                }
            }
        }
    }

    @Test func vocabulariesAreDisjoint() {
        let gestures = Set(Outcome.Gesture.allCases.map(\.rawValue))
        let effects = Set(["confirmed", "absent", "unknown", "not_applicable"])
        let recoveries = Set(["continue", "observe", "do_not_repeat", "change_target", "ask_person", "retry"])
        #expect(gestures.isDisjoint(with: effects))
        #expect(gestures.isDisjoint(with: recoveries))
        #expect(effects.isDisjoint(with: recoveries))
    }

}
