//
//  LendActivityTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import CoreGraphics
import Foundation
import InteractionListener
import Testing
@testable import SeatBroker

/// The activity policy on a hand-driven clock: what each piece of evidence says about the person, when
/// a question falls due, how answers and input back off, and what is never asked.
@Suite
struct LendActivityTests {

    typealias Activity = LendActivity

    /// A landed lend at t = 0, the lent application in front.
    private func landed(inFront: Bool = true) -> Activity {
        var activity = Activity(at: 0, lentInFront: inFront)
        #expect(activity.release(at: 0) == nil)
        return activity
    }

    // MARK: Elsewhere

    @Test func workingElsewhereAsksAfterTwoMinutes() {
        var activity = landed()
        #expect(activity.receive(.frontmost(.other), at: 10) == nil)
        #expect(activity.state == .elsewhere)
        #expect(activity.receive(.input(.other), at: 20) == nil)
        #expect(activity.deadline == 130)
        #expect(activity.tick(at: 129) == nil)
        #expect(activity.tick(at: 130) == .ask(.elsewhere))
        #expect(activity.reason == "the person worked in another application for 2 min")
    }

    @Test func aLookElsewhereWithoutInputIsLeftToTheAwayDelay() {
        var activity = landed()
        _ = activity.receive(.frontmost(.other), at: 10)
        _ = activity.receive(.hover(.other), at: 12)
        #expect(activity.tick(at: 200) == nil)
        #expect(activity.deadline == 312)
        #expect(activity.tick(at: 312) == .ask(.away))
        #expect(activity.state == .away)
    }

    @Test(arguments: [Activity.Evidence.frontmost(.lent), .hover(.lent), .input(.lent), .menu(open: true)])
    func comingBackEndsTheSpan(_ back: Activity.Evidence) {
        var activity = landed()
        _ = activity.receive(.frontmost(.other), at: 10)
        _ = activity.receive(.input(.other), at: 11)
        #expect(activity.receive(back, at: 100) == nil)
        _ = activity.receive(.menu(open: false), at: 101)
        _ = activity.receive(.frontmost(.other), at: 110)
        _ = activity.receive(.input(.other), at: 111)
        // A new span: two minutes from leaving again, not from the first time.
        #expect(activity.tick(at: 200) == nil)
        #expect(activity.tick(at: 230) == .ask(.elsewhere))
    }

    @Test func evidenceFromBeforeLeavingDoesNotEndTheSpan() {
        var activity = landed()
        _ = activity.receive(.frontmost(.other), at: 10)
        _ = activity.receive(.input(.other), at: 12)
        // A typing burst in the lent application, reported once it paused, that ended before leaving.
        _ = activity.receive(.input(.lent), at: 9)
        #expect(activity.tick(at: 130) == .ask(.elsewhere))
    }

    @Test func hiddenOrMinimizedAsksSoonerWithoutWorkElsewhere() {
        var activity = landed()
        _ = activity.receive(.frontmost(.other), at: 10)
        _ = activity.receive(.windows(.tucked), at: 40)
        #expect(activity.deadline == 70)
        #expect(activity.tick(at: 70) == .ask(.elsewhere))
        #expect(activity.reason.contains("hidden or minimized for 30 s"))
    }

    @Test func minimizingWhileInFrontStartsTheSpan() {
        var activity = landed()
        _ = activity.receive(.windows(.tucked), at: 5)
        #expect(activity.state == .elsewhere)
        #expect(activity.tick(at: 35) == .ask(.elsewhere))
        // A burst that ended before leaving is no evidence of coming back.
        var late = landed()
        _ = late.receive(.frontmost(.other), at: 10)
        _ = late.receive(.input(.lent), at: 9)
        #expect(late.state == .elsewhere)
    }

    @Test func windowsBackOnScreenFallBackToTheWorkRule() {
        var activity = landed()
        _ = activity.receive(.frontmost(.other), at: 10)
        _ = activity.receive(.windows(.tucked), at: 20)
        _ = activity.receive(.windows(.shown), at: 30)
        #expect(activity.tick(at: 60) == nil)
        #expect(activity.deadline == 300)
    }

    // MARK: Away and reading

    @Test func anyInputOnTheMacPostponesAway() {
        var activity = landed()
        _ = activity.receive(.input(.other), at: 250)
        #expect(activity.tick(at: 300) == nil)
        _ = activity.receive(.input(.unknown), at: 500)
        #expect(activity.deadline == 800)
        #expect(activity.tick(at: 800) == .ask(.away))
        #expect(activity.reason == "no input on the Mac for 5 min")
    }

    @Test func workingInTheApplicationNeverAsks() {
        var activity = landed()
        for second in stride(from: 0.0, through: 3600, by: 60) {
            #expect(activity.receive(.input(.lent), at: second) == nil)
            #expect(activity.tick(at: second + 59) == nil)
        }
        #expect(activity.state == .working)
    }

    @Test func anOpenMenuHoldsEveryDelayUntilItCloses() {
        var activity = landed()
        _ = activity.receive(.menu(open: true), at: 10)
        #expect(activity.deadline == nil)
        #expect(activity.tick(at: 1000) == nil)
        #expect(activity.state == .reading)
        _ = activity.receive(.menu(open: false), at: 1000)
        #expect(activity.deadline == 1300)
    }

    @Test func anotherApplicationInFrontClosesTheLentMenu() {
        var activity = landed()
        _ = activity.receive(.menu(open: true), at: 10)
        _ = activity.receive(.frontmost(.other), at: 20)
        _ = activity.receive(.input(.other), at: 21)
        #expect(activity.tick(at: 140) == .ask(.elsewhere))
    }

    @Test func restingOnTheApplicationAfterWorkStaysWorking() {
        var activity = landed()
        _ = activity.receive(.input(.lent), at: 1)
        _ = activity.receive(.hover(.lent), at: 2)
        #expect(activity.state == .working)
        _ = activity.receive(.frontmost(.other), at: 3)
        _ = activity.receive(.hover(.lent), at: 4)
        #expect(activity.state == .reading)
    }

    // MARK: Closed and quit

    @Test func closingEveryWindowAsksAtOnceAndOnlyOnce() {
        var activity = landed()
        #expect(activity.receive(.windows(.closed), at: 30) == .ask(.closed))
        #expect(activity.state == .closed)
        #expect(activity.answered(.no, at: 35) == nil)
        #expect(activity.tick(at: 36) == nil)
        _ = activity.receive(.windows(.shown), at: 40)
        #expect(activity.receive(.windows(.closed), at: 50) == .ask(.closed))
    }

    @Test func quittingTakesBackAtOnceEvenWithAQuestionOpen() {
        var activity = landed()
        #expect(activity.receive(.windows(.closed), at: 10) == .ask(.closed))
        #expect(activity.receive(.quit, at: 12) == .takeBack(.quit))
        #expect(activity.reason == "the application quit")
        #expect(activity.answered(.timeout, at: 20) == nil)
        #expect(activity.deadline == nil)
    }

    // MARK: Locked and asleep

    @Test(arguments: [Activity.Evidence.locked(true), .asleep(true)])
    func lockedTakesBackAfterAMinuteWithoutAsking(_ lock: Activity.Evidence) {
        var activity = landed()
        _ = activity.receive(.frontmost(.other), at: 0)
        _ = activity.receive(.input(.other), at: 1)
        #expect(activity.receive(lock, at: 100) == nil)
        #expect(activity.state == .locked)
        // The elsewhere question would have fallen due at 121: nobody can answer it.
        #expect(activity.tick(at: 130) == nil)
        #expect(activity.deadline == 160)
        #expect(activity.tick(at: 160) == .takeBack(.locked))
        #expect(activity.reason == "the screen stayed locked or the Mac asleep for 1 min")
    }

    @Test func unlockingWithinTheMinuteChangesNothing() {
        var activity = landed()
        _ = activity.receive(.frontmost(.other), at: 0)
        _ = activity.receive(.input(.other), at: 1)
        _ = activity.receive(.locked(true), at: 100)
        #expect(activity.receive(.locked(false), at: 150) == nil)
        #expect(activity.tick(at: 160) == nil)
        // Unlocking restarts the span: nothing is asked the moment the person is back.
        _ = activity.receive(.input(.other), at: 151)
        #expect(activity.deadline == 270)
    }

    @Test func wakingPastTheMinuteStillTakesBack() {
        var activity = landed()
        _ = activity.receive(.locked(true), at: 10)
        _ = activity.receive(.asleep(true), at: 11)
        // The timer could not fire while the Mac slept.
        #expect(activity.receive(.asleep(false), at: 3600) == .takeBack(.locked))
    }

    @Test func sleepWhileLockedCountsFromTheLock() {
        var activity = landed()
        _ = activity.receive(.locked(true), at: 10)
        _ = activity.receive(.asleep(true), at: 40)
        _ = activity.receive(.asleep(false), at: 50)
        #expect(activity.deadline == 70)
    }

    // MARK: Never asking

    @Test func nothingFallsDueWhileTheLendLands() {
        var activity = Activity(at: 0)
        _ = activity.receive(.frontmost(.other), at: 1)
        _ = activity.receive(.input(.other), at: 2)
        _ = activity.receive(.windows(.closed), at: 3)
        _ = activity.receive(.quit, at: 4)
        #expect(activity.deadline == nil)
        #expect(activity.tick(at: 1000) == nil)
        #expect(activity.release(at: 1001) == .takeBack(.quit))
    }

    @Test func landingDefersAQuestionUntilItLands() {
        var activity = Activity(at: 0)
        _ = activity.receive(.windows(.closed), at: 1)
        #expect(activity.tick(at: 2) == nil)
        #expect(activity.release(at: 3) == .ask(.closed))
    }

    @Test func oneQuestionAtATimeAndNothingAfterTheTakeBack() {
        var activity = landed()
        #expect(activity.tick(at: 300) == .ask(.away))
        _ = activity.receive(.windows(.closed), at: 301)
        _ = activity.receive(.locked(true), at: 302)
        #expect(activity.tick(at: 400) == nil)
        #expect(activity.answered(.timeout, at: 400) == .takeBack(.away))
        #expect(activity.reason == "no input on the Mac for 5 min; nobody answered within 10 s")
        #expect(activity.receive(.windows(.shown), at: 401) == nil)
        #expect(activity.receive(.quit, at: 402) == nil)
        #expect(activity.deadline == nil)
    }

    // MARK: Answers and back-off

    @Test func yesTakesBackWithTheReason() {
        var activity = landed()
        _ = activity.receive(.frontmost(.other), at: 0)
        _ = activity.receive(.input(.other), at: 1)
        #expect(activity.tick(at: 120) == .ask(.elsewhere))
        #expect(activity.answered(.yes, at: 125) == .takeBack(.elsewhere))
        #expect(activity.reason == "the person worked in another application for 2 min; the person confirmed being done")
    }

    @Test func noDoublesEachTriggerUntilWorkInTheApplication() {
        var activity = landed()
        _ = activity.receive(.frontmost(.other), at: 0)
        _ = activity.receive(.input(.other), at: 1)
        #expect(activity.tick(at: 120) == .ask(.elsewhere))
        #expect(activity.answered(.no, at: 125) == nil)
        #expect(activity.delay(of: .elsewhere) == 240)
        _ = activity.receive(.input(.other), at: 126)
        #expect(activity.deadline == 365)
        #expect(activity.tick(at: 365) == .ask(.elsewhere))
        #expect(activity.reason == "the person worked in another application for 4 min")
        _ = activity.answered(.no, at: 370)
        #expect(activity.delay(of: .elsewhere) == 480)
        #expect(activity.delay(of: .away) == 300)
        _ = activity.receive(.input(.lent), at: 400)
        #expect(activity.delay(of: .elsewhere) == 120)
    }

    @Test func theClickThatAnsweredNoIsNoWorkInTheNewSpan() {
        var activity = landed()
        _ = activity.receive(.frontmost(.other), at: 0)
        _ = activity.receive(.input(.other), at: 1)
        #expect(activity.tick(at: 120) == .ask(.elsewhere))
        _ = activity.answered(.no, at: 125)
        // The listener reports the click on the bubble after the bubble answered.
        _ = activity.receive(.input(.other), at: 124.8)
        #expect(activity.deadline == 424.8)
    }

    @Test func awayBacksOffFromTheAnswer() {
        var activity = landed()
        #expect(activity.tick(at: 300) == .ask(.away))
        #expect(activity.answered(.no, at: 305) == nil)
        #expect(activity.state == .reading)
        #expect(activity.deadline == 905)
        #expect(activity.tick(at: 905) == .ask(.away))
        #expect(activity.reason == "no input on the Mac for 10 min")
    }

    @Test func inputToTheApplicationWithdrawsOnceAndBacksOff() {
        var activity = landed()
        #expect(activity.tick(at: 300) == .ask(.away))
        #expect(activity.receive(.input(.lent), at: 303) == .withdraw)
        #expect(activity.receive(.input(.lent), at: 304) == nil)
        #expect(activity.answered(.no, at: 304) == nil)
        #expect(activity.delay(of: .away) == 600)
        // Its own typing burst, reported once it paused, ended before the answer: no reset.
        _ = activity.receive(.input(.lent), at: 303.5)
        #expect(activity.delay(of: .away) == 600)
        _ = activity.receive(.input(.lent), at: 310)
        #expect(activity.delay(of: .away) == 300)
    }

    @Test func theBubblesAnswerStandsAfterAWithdrawal() {
        var activity = landed()
        #expect(activity.tick(at: 300) == .ask(.away))
        #expect(activity.receive(.input(.lent), at: 309) == .withdraw)
        // The countdown had already run out when the withdrawal reached the bubble.
        #expect(activity.answered(.timeout, at: 310) == .takeBack(.away))
    }

    @Test func answersWithoutAQuestionChangeNothing() {
        var activity = landed()
        #expect(activity.answered(.yes, at: 5) == nil)
        #expect(activity.answered(.no, at: 6) == nil)
        #expect(activity.delay(of: .away) == 300)
    }

    // MARK: Listener events

    @Test func listenerEventsSayWhereInputWent() {
        func event(_ kind: InteractionEvent.Kind, pid: Int32) -> InteractionEvent {
            InteractionEvent(kind: kind, timestamp: Date(), startedAt: 1, endedAt: 2, precedingRevision: 0,
                             revision: 1, point: .zero, window: nil, processID: pid)
        }
        #expect(Activity.Evidence(event(.click, pid: 42), lent: 42) == .input(.lent))
        #expect(Activity.Evidence(event(.typing, pid: 7), lent: 42) == .input(.other))
        #expect(Activity.Evidence(event(.scroll, pid: 0), lent: 42) == .input(.unknown))
        #expect(Activity.Evidence(event(.hover, pid: 42), lent: 42) == .hover(.lent))
        #expect(Activity.Evidence(event(.focus, pid: 7), lent: 42) == .frontmost(.other))
        #expect(Activity.Evidence(event(.focus, pid: 42), lent: 42) == .frontmost(.lent))
        #expect(Activity.Evidence(event(.gap, pid: 42), lent: 42) == .input(.unknown))
    }

    @Test @MainActor func observedSourceSeesEveryEventAndRecordsNoHover() async throws {
        let inner = Source()
        let source = ObservedInteractionSource(inner) { inner.observed.append($0.kind) }
        for kind in [InteractionEvent.Kind.click, .hover, .focus, .typing] {
            inner.continuation.yield(InteractionEvent(kind: kind, timestamp: Date(), startedAt: 1, endedAt: 2,
                                                      precedingRevision: 0, revision: 1, point: .zero,
                                                      window: nil, processID: 42))
        }
        inner.continuation.finish()
        var passed: [InteractionEvent.Kind] = []
        for try await event in source.events { passed.append(event.kind) }
        #expect(inner.observed == [.click, .hover, .focus, .typing])
        #expect(passed == [.click, .focus, .typing])
        await source.stop()
        #expect(inner.stops == 1)
    }

    @MainActor
    private final class Source: HumanInteractionSource {
        let buttons = InteractionButtonState()
        let events: AsyncThrowingStream<InteractionEvent, any Error>
        let continuation: AsyncThrowingStream<InteractionEvent, any Error>.Continuation
        var stops = 0
        var observed: [InteractionEvent.Kind] = []

        init() {
            (events, continuation) = AsyncThrowingStream.makeStream()
        }

        func stop() async {
            stops += 1
            continuation.finish()
        }
    }
}
