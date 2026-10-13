//
//  FocusedWindowReadingTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import ApplicationServices
@testable import SeatSession
import Testing

/// The bounded focus reading the boundary of an ordinary window's keys takes:
/// only `.cannotComplete`, after its one recovery, or a deadline that ran out
/// is an application that did not answer. Every other answer is a reading.
@Suite("The bounded focus reading")
struct FocusedWindowReadingTests {

    private final class Application {
        var focus : [(AXError, Int?)]
        var window: (AXError, Int?)
        var timeouts: [Float] = []
        var now: UInt64 = 0
        var nowAfterRecovery: UInt64?

        init(focus: [(AXError, Int?)], window: (AXError, Int?)) {
            self.focus  = focus
            self.window = window
        }
    }

    private static let deadline: UInt64 = 1_000_000_000

    private func reading(
        focus : [(AXError, Int?)],
        window: (AXError, Int?) = (.success, 42),
        nowAfterRecovery: UInt64? = nil
    ) -> (FocusedWindowReading, [Float]) {
        let application = Application(focus: focus, window: window)
        application.nowAfterRecovery = nowAfterRecovery
        let resolver = DialogEndpointResolver<Int>(
            nodeAtPoint  : { _ in nil },
            focusedNode  : { nil },
            children     : { _ in .leaf },
            nodeFrame    : { _ in nil },
            nodeWindow   : { _ in nil },
            nodeProcess  : { _ in nil },
            identity     : { _ in nil },
            geometry     : { _, _ in nil },
            now          : { application.now },
            focusAttempt : { timeout in
                application.timeouts.append(timeout)
                if application.timeouts.count > 1, let later = application.nowAfterRecovery {
                    application.now = later
                }
                return application.focus.removeFirst()
            },
            windowAttempt: { _, _ in application.window }
        )
        return (resolver.focusedNodeWindowReading(deadlineNanoseconds: Self.deadline), application.timeouts)
    }

    @Test("a focus that cannot complete and then answers names its window")
    func aRecoveredFocusNamesItsWindow() {
        let (outcome, timeouts) = reading(focus: [(.cannotComplete, nil), (.success, 1)])

        #expect(outcome == .window(42))
        #expect(timeouts == [BoundedAccessibilityRead.fastTimeout, BoundedAccessibilityRead.recoveryTimeout])
    }

    @Test("a focus that cannot complete twice is an application that did not answer")
    func aFocusThatNeverCompletesIsNotResponding() {
        #expect(reading(focus: [(.cannotComplete, nil), (.cannotComplete, nil)]).0 == .notResponding)
        #expect(reading(focus: [(.success, 1)], window: (.cannotComplete, nil)).0 == .notResponding)
    }

    @Test("a recovery that answers after the deadline did not answer in time")
    func aLateRecoveryIsNotResponding() {
        let (outcome, _) = reading(
            focus           : [(.cannotComplete, nil), (.success, 1)],
            nowAfterRecovery: Self.deadline + 1
        )
        #expect(outcome == .notResponding)
    }

    @Test(
        "no focus, an element without a window and any other error are readings",
        arguments: [AXError.noValue, .invalidUIElement, .failure, .illegalArgument]
    )
    func everyOtherAnswerIsAReading(error: AXError) {
        let (focus, timeouts) = reading(focus: [(error, nil)])
        #expect(focus == .noWindow)
        #expect(timeouts.count == 1)
        #expect(reading(focus: [(.success, 1)], window: (error, nil)).0 == .noWindow)
        #expect(reading(focus: [(.success, 1)], window: (.success, 0)).0 == .noWindow)
    }
}
