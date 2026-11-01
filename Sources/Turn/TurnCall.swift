import AutomationRuntime
import Foundation
import LocalMCP
import os

/// TurnCall retains an admitted task until its cancellation or completion has drained.
@MainActor
struct TurnCall {
    let tool: String
    let task: Task<JSONValue, any Error>
    let interruption: AutomationCallInterruption
    private static let log = Logger(subsystem: "dev.forte.Braus", category: "HumanControl")

    static func logInterruption(_ name: String) {
        log.info("take control: interrupting \(name, privacy: .public), person requested control")
    }
}
