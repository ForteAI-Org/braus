//
//  AdapterApprovalsTests.swift
//  Braus
//

import AppAdapters
import Foundation
import LocalMCP
import Testing
@testable import Braus

@MainActor
@Suite("Adapter approvals")
struct AdapterApprovalsTests {

    private func consent(_ verb: String) -> AdapterConsent {
        AdapterConsent(
            adapter  : "files",
            app      : "Finder",
            verb     : verb,
            arguments: ["path": .string("/x")]
        )
    }

    @Test("one confirmation per call, in order; each answer resolves its own call")
    func order() async throws {
        let approvals = AdapterApprovals()
        let first = Task { await approvals.ask(consent("move_to_trash")) }
        let second = Task { await approvals.ask(consent("send")) }
        while approvals.pending.count < 2 { await Task.yield() }
        #expect(approvals.pending.map(\.consent.verb).sorted() == ["move_to_trash", "send"])
        let shown = try #require(approvals.pending.first)
        approvals.answer(shown.id, allowed: true)
        approvals.answer(shown.id, allowed: false)
        let next = try #require(approvals.pending.first)
        approvals.answer(next.id, allowed: false)
        let answers = [await first.value, await second.value]
        #expect(Set(answers) == [false, true])
        #expect(approvals.pending.isEmpty)
    }

    @Test("a request nobody answers is refused after the timeout, and refuseAll clears the queue")
    func timeoutAndQuit() async throws {
        let quick = AdapterApprovals(timeout: .milliseconds(50))
        #expect(await quick.ask(consent("send")) == false)
        #expect(quick.pending.isEmpty)

        let approvals = AdapterApprovals()
        let waiting = Task { await approvals.ask(consent("send")) }
        while approvals.pending.isEmpty { await Task.yield() }
        approvals.refuseAll()
        #expect(await waiting.value == false)
    }

    @Test("a click or a key in the first second of a request answers nothing; then it does, and the next waits again")
    func answerDelay() async throws {
        let clock = TestClock()
        let approvals = AdapterApprovals(now: { clock.now })
        let first = Task { await approvals.ask(consent("send")) }
        let second = Task { await approvals.ask(consent("move_to_trash")) }
        while approvals.pending.count < 2 { await Task.yield() }
        let shown = try #require(approvals.pending.first)
        #expect(approvals.answerableAt(shown.id) == clock.now.advanced(by: AdapterApprovals.answerDelay))
        #expect(approvals.answerableAt(approvals.pending[1].id) == nil)

        approvals.respond(shown.id, allowed: true)
        approvals.respond(shown.id, allowed: false)
        #expect(approvals.pending.first?.id == shown.id)

        clock.now = clock.now.advanced(by: .milliseconds(1_001))
        approvals.respond(shown.id, allowed: true)
        let next = try #require(approvals.pending.first)
        approvals.respond(next.id, allowed: false)
        #expect(approvals.pending.first?.id == next.id)
        clock.now = clock.now.advanced(by: .seconds(2))
        approvals.respond(next.id, allowed: false)
        let answers = [await first.value, await second.value]
        #expect(Set(answers) == [false, true])
        #expect(approvals.pending.isEmpty)
        #expect(approvals.shownAt == nil)
    }
}

/// TestClock is a clock the test moves by hand.
@MainActor
private final class TestClock {
    var now = ContinuousClock.now
}
