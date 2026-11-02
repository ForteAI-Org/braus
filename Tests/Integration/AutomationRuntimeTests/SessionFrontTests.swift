//
//  SessionFrontTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AutomationRuntime
import TestScratch
import Testing

/// Sessions without a Seat cannot execute front-dependent commands, even when they name an application.
@MainActor
@Suite("The default session front lease")
struct SessionFrontTests {

    @Test(arguments: [false, true])
    func aSessionWithoutASeatDoesNotRunTheBody(open: Bool) async throws {
        let session = LearningSession(directory: Scratch.directory("front-default"))
        if open {
            session.windows["test.process"] = LearningSession.Window(elements: [])
            _ = try await session.open(application: "test.process", window: nil)
        }
        let operating: any AutomationSessionOperating = session
        var runs = 0
        let answer = await operating.withFront(
            of                 : "test.process",
            admittingOpenDialog: true,
            atMost             : .seconds(1)
        ) {
            runs += 1
            return 42
        }
        #expect(answer.outcome == .notHeld)
        #expect(!answer.outcome.isSuccess)
        #expect(!answer.outcome.reason.isEmpty)
        #expect(answer.result == nil)
        #expect(runs == 0)
        await session.close()
    }
}
