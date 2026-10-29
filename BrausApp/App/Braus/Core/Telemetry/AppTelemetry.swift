//
//  AppTelemetry.swift
//  Braus
//
//  Created by Ronaldo Zefi on 26/10/2026.
//

import AutomationRuntime
import Foundation
import Telemetry

/// AppTelemetry is where the app decides whether its anonymous usage metrics are sent: on for a new
/// installation, off when the person turns them off in Settings > General or the environment says so
/// (`DO_NOT_TRACK`, `BRAUS_TELEMETRY=0`). A check run, the test host and an isolated launch never send,
/// so a developer's own runs and the tests leave no trace in the metrics.
enum AppTelemetry {

    /// Whether this process may send at all, whatever the person chose.
    static var isAllowedHere: Bool {
        !BrausApp.isCheckRun && !LaunchIsolation.current.isIsolated
    }

    /// Whether the environment turns telemetry off, which Settings shows instead of the switch.
    static var isDisabledByEnvironment: Bool {
        TelemetryConfiguration.isDisabledByEnvironment(ProcessInfo.processInfo.environment)
    }

    /// Starts or stops sending to match the person's choice and the environment.
    static func apply(defaults: UserDefaults = .standard) {
        let environment = ProcessInfo.processInfo.environment
        let stored      = defaults.object(forKey: AppPreferences.sharesTelemetry) as? Bool
        guard isAllowedHere, TelemetryConfiguration.isEnabled(environment: environment, stored: stored) else {
            Telemetry.stop()
            return
        }
        Telemetry.start(TelemetryConfiguration(
            endpoint      : TelemetryConfiguration.endpoint(in: environment),
            installationID: TelemetryConfiguration.installationID(in: defaults),
            appVersion    : Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ))
    }
}
