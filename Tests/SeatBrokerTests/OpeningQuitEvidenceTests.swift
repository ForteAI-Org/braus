import Foundation
@testable import SeatBroker
import Testing

@MainActor
struct OpeningQuitEvidenceTests {
    @Test func acceptedQuitRequestDoesNotAttestProcessExit() {
        var terminationRequests = 0
        var exitReads = 0
        let ledger = LaunchLedger(terminate: { _ in terminationRequests += 1 },
            isTerminated: { _ in exitReads += 1; return false })
        ledger.record(.openedByAgent, for: 601)
        let requested = ledger.quitUnseated(601) { _ in terminationRequests += 1; return true }
        #expect(requested && terminationRequests == 1 && exitReads == 0)
        let sentence = ApplicationOpening.unseated("B", wasLaunched: true, wasQuit: requested)
        #expect(sentence.contains("was asked to quit"))
        #expect(sentence.contains("exit was not verified"))
        #expect(!sentence.contains("was closed"))
    }

    @Test func noWindowDescriptionDoesNotInventALaunch() {
        let error = SeatBrokerError.noWindowShown(application: "B", seconds: 1, wasLaunched: false, wasQuit: false)
        #expect(error.localizedDescription.hasPrefix("B is running but showed no window within 1 s."))
        #expect(!error.localizedDescription.contains("B launched"))
    }
}
