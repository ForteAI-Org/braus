//
//  BrausEntry.swift
//  Braus
//

import AutomationRuntime
import AutomationMCP
import Foundation
import SwiftUI
import os

/// BrausEntry starts the app. An isolated run that was asked for and is not valid (`LaunchIsolation`, B2), and the
/// smoke build started without one, are refused here, before `BrausApp` builds its state: that state reads the support
/// folder and the keychain as it is made, so a later refusal would come after the person's data was reached.
@main
@MainActor
enum BrausEntry {

    static func main() {
        ScriptedWorkerRun.noteLaunch()
        if let refusal = LaunchIsolation.current.refusal(bundleID: Bundle.main.bundleIdentifier) {
            // A launch from Finder or by the system has no terminal: the log keeps the reason too.
            Logger(subsystem: "dev.forte.Braus", category: "Launch").error("Did not start: \(refusal, privacy: .public)")
            FileHandle.standardError.write(Data("Braus did not start: \(refusal)\n".utf8))
            exit(78) // EX_CONFIG
        }
        do {
            try IsolatedLaunchEnvironment.prepare()
        } catch {
            FileHandle.standardError.write(Data("Braus isolation failed: \(error)\n".utf8))
            exit(78)
        }
        BrausApp.main()
    }
}
