import Foundation
import os

/// TurnDiagnostics reports recoverable persistence and cleanup failures.
@MainActor
enum TurnDiagnostics {
    private static let log = Logger(subsystem: "dev.forte.Braus", category: "Turn")
    static func cleanup(_ error: any Error) {
        fputs("braus: turn cleanup failed: \(error)\n", stderr)
    }

    static func instructionRecord(_ error: any Error) {
        log.error("Instruction record unavailable; the next turn will receive a reminder: \(String(describing: error), privacy: .private)")
    }
}
