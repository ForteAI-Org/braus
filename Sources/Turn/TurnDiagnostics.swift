import Foundation
import os

/// TurnDiagnostics reports recoverable persistence failures without exposing their details publicly.
@MainActor
enum TurnDiagnostics {
    private static let log = Logger(subsystem: "dev.forte.Braus", category: "Turn")
    static func instructionRecord(_ error: any Error) {
        log.error("Instruction record unavailable; the next turn will receive a reminder: \(String(describing: error), privacy: .private)")
    }
}
