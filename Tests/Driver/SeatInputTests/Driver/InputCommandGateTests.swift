//
//  InputCommandGateTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import SeatInput
import Testing

@Suite("Prepared input boundary")
@MainActor
struct InputCommandGateTests {
    @Test("a pause or cancellation during preparation prevents the following post", arguments: [false, true])
    func suspendedBoundary(_ cancel: Bool) async {
        let gate = InputCommandGate()
        var resume: CheckedContinuation<Void, Never>?
        var posted = false
        gate.setPreparation { correlationID in
            #expect(correlationID == 42)
            await withCheckedContinuation { resume = $0 }
        }
        let task = Task {
            try await gate.prepare(correlationID: 42)
            posted = true
        }
        while resume == nil { await Task.yield() }
        #expect(!posted)
        if cancel { task.cancel() } else { gate.pause(.focusRecovery) }
        resume?.resume()
        let result = await task.result
        if case .success = result { Issue.record("An interrupted boundary must throw") }
        #expect(!posted)
    }

    @Test("every command boundary awaits its own preparation")
    func eachBoundary() async throws {
        let gate = InputCommandGate()
        var prepared: [Int64] = []
        gate.setPreparation { prepared.append($0) }
        for correlationID in 1...3 {
            try await gate.prepare(correlationID: Int64(correlationID))
            #expect(prepared.count == correlationID)
        }
        gate.pause(.focusRecovery)
        await #expect(throws: InputFailure.inputPaused([.focusRecovery])) {
            try await gate.prepare(correlationID: 4)
        }
        #expect(prepared == [1, 2, 3])
    }

    @Test("two overlapping causes keep input closed until both are resolved",
          arguments: [[InputCommandGate.PauseCause.focusRecovery, .windowTransfer],
                      [InputCommandGate.PauseCause.windowTransfer, .focusRecovery]])
    func overlappingCauses(_ order: [InputCommandGate.PauseCause]) throws {
        let gate = InputCommandGate()
        gate.pause(.focusRecovery)
        gate.pause(.windowTransfer)
        #expect(gate.pauseCauses == [.focusRecovery, .windowTransfer])

        gate.resume(order[0])
        #expect(gate.isPaused, "Resolving one cause must not reopen the gate for the other")
        #expect(throws: InputFailure.inputPaused([order[1].reason])) { try gate.check() }

        gate.resume(order[1])
        #expect(!gate.isPaused)
        try gate.check()
    }

    @Test("resolving a cause nobody raised changes nothing")
    func unrelatedResume() throws {
        let gate = InputCommandGate()
        gate.pause(.focusRecoveryStopped)
        gate.resume(.focusRecovery)
        gate.resume(.windowTransfer)
        #expect(gate.isPaused, "The terminal cause is nobody else's to resolve")
        #expect(throws: InputFailure.inputPaused([.focusRecoveryStopped])) { try gate.check() }
    }

    @Test("a human episode blocks agent input and never clears common causes")
    func humanAdmissionKeepsCommonCauses() async throws {
        let gate = InputCommandGate()
        let token = try gate.beginHumanInput()
        #expect(gate.pauseReasons == [.humanIntervention])
        #expect(throws: InputFailure.inputPaused([.humanIntervention])) { try gate.check() }
        gate.pause(.windowTransfer)
        #expect(gate.pauseReasons.contains(.windowTransfer))
        #expect(gate.pauseReasons.contains(.humanIntervention))
        gate.resume(.windowTransfer)
        #expect(throws: InputFailure.inputPaused([.humanIntervention])) { try gate.check() }
        try await gate.endHumanInput(token)
        try gate.check()
    }

    @Test("an agent request waiting across a human episode stays revoked")
    func pendingAgentRequestNeverRevives() async throws {
        let gate = InputCommandGate()
        var waiting: CheckedContinuation<Void, Never>?
        let request = Task {
            try await gate.withAdmission {
                await withCheckedContinuation { waiting = $0 }
                try gate.check()
            }
        }
        while waiting == nil { await Task.yield() }
        let token = try gate.beginHumanInput()
        try await gate.endHumanInput(token)
        waiting?.resume()
        await #expect(throws: InputFailure.inputPaused([.inputAuthorityExpired])) {
            try await request.value
        }
        try await gate.withAdmission { try gate.check() }
    }

    @Test("human tokens cannot be replayed or used on another gate")
    func humanTokensAreBoundToTheirEpisode() async throws {
        let gate = InputCommandGate()
        let other = InputCommandGate()
        let first = try gate.beginHumanInput()
        #expect(try gate.beginHumanInput() == first)
        await #expect(throws: InputFailure.inputPaused([.inputAuthorityExpired])) {
            try await other.endHumanInput(first)
        }
        try await gate.endHumanInput(first)
        let second = try gate.beginHumanInput()
        #expect(first != second)
        await #expect(throws: InputFailure.inputPaused([.inputAuthorityExpired])) {
            try await gate.endHumanInput(first)
        }
        #expect(gate.isCurrentHumanInput(second))
        #expect(throws: InputFailure.inputPaused([.humanIntervention])) { try gate.check() }
    }

    @Test("terminal stop wins over human admission and ending a human episode")
    func stopWinsOverHumanInput() async throws {
        let gate = InputCommandGate()
        let token = try gate.beginHumanInput()
        gate.pause(.deliberateStop)
        #expect(gate.pauseReasons.contains(.deliberateStop))
        #expect(gate.pauseReasons.contains(.humanIntervention))
        try await gate.endHumanInput(token)
        #expect(throws: InputFailure.inputPaused([.deliberateStop])) { try gate.check() }
        #expect(throws: InputFailure.inputPaused([.deliberateStop])) { try gate.beginHumanInput() }
    }

}
