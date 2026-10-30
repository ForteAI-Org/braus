//
//  HumanControlCompletionTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Foundation
import Testing
@testable import SeatBroker

@MainActor
@Suite
struct HumanControlCompletionTests {
    @Test(arguments: [false, true])
    func yesResumesOnlyAfterTakeBackReviewAndDrain(fails: Bool) async throws {
        var steps: [String] = []
        var resumed: String?
        let completion = HumanControlCompletion(
            takeBack: {
                steps.append("take-back")
                if fails { throw CocoaError(.fileNoSuchFile) }
                return nil
            },
            review: { note in
                steps.append("review")
                return "Final state: current document" + (note.map { "\n" + $0 } ?? "")
            },
            drain: { steps.append("drain") },
            resume: { summary in
                steps.append("resume")
                resumed = summary
            },
            close: { steps.append("close") }
        )
        try await completion.run(.resumingWorker)
        #expect(steps == ["take-back", "review", "drain", "resume"])
        #expect(resumed?.contains("Final state: current document") == true)
        #expect(resumed?.contains("Take-back failed") == fails)
    }

    @Test func anAutomaticEndingIsTheSummarysFirstLine() async throws {
        var resumed: String?
        let completion = HumanControlCompletion(
            takeBack: { "The lent application is no longer running." },
            review: { note in "Mixer: Session\n" + (note ?? "") },
            drain: {},
            resume: { resumed = $0 },
            close: {},
            ending: "Ended automatically: the application quit."
        )
        try await completion.run(.resumingWorker)
        #expect(resumed == "Ended automatically: the application quit.\nMixer: Session\nThe lent application is no longer running.")
    }

    @Test func endControlClosesWithoutTakeBackOrResume() async throws {
        var steps: [String] = []
        let completion = HumanControlCompletion(
            takeBack: { steps.append("take-back"); return nil },
            review: { _ in steps.append("review"); return "state" },
            drain: { steps.append("drain") },
            resume: { _ in steps.append("resume") },
            close: { steps.append("close") }
        )
        try await completion.run(.closingSession)
        #expect(steps == ["close"])
    }
}
