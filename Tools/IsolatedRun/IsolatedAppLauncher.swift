//
//  IsolatedAppLauncher.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AppKit
import Foundation

/// IsolatedAppLauncher starts a new instance through Launch Services, independent of the runner's
/// process group. It prints only that instance's PID, so cleanup never targets an existing instance.
@main
@MainActor
enum IsolatedAppLauncher {

    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: launcher <Braus.app>\n".utf8))
            exit(64)
        }
        let app = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let names: Set<String> = [
            "BRAUS_ISOLATED_RUN", "BRAUS_APP_SUPPORT_DIR", "BRAUS_SCRIPTED_WORKER",
            "BRAUS_SCRIPTED_CHECK", "BRAUS_SCRIPTED_CHECK_QUIT", "CFFIXED_USER_HOME", "TMPDIR",
        ]
        configuration.environment = ProcessInfo.processInfo.environment.filter { names.contains($0.key) }
        do {
            let running = try await NSWorkspace.shared.openApplication(
                at           : app,
                configuration: configuration
            )
            guard running.bundleURL?.resolvingSymlinksInPath() == app else {
                throw CocoaError(.executableLoad)
            }
            print(running.processIdentifier)
        } catch {
            FileHandle.standardError.write(Data("Isolated launch failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
