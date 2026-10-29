//
//  TelemetryConfiguration.swift
//  Braus
//
//  Created by Ronaldo Zefi on 26/10/2026.
//

import Foundation

/// TelemetryConfiguration is where Braus's anonymous usage metrics go and who they come from: the
/// collector's address, the installation's random identifier and the facts of this copy of the app.
/// It holds no credential: the collector Braus sends to keeps the token of the store behind it, so the
/// address in this open source code lets anyone send metrics and nothing more.
public struct TelemetryConfiguration: Sendable, Equatable {

    /// The collector Forte runs for Braus's metrics. `BRAUS_TELEMETRY_ENDPOINT` replaces it.
    public static let defaultEndpoint = URL(string: "https://telemetry.forteutilities.com")!

    /// The base address; metrics are posted to `<endpoint>/v1/metrics`, as OTLP/HTTP asks.
    public let endpoint: URL
    /// A random identifier made once per installation, never tied to an account or a person.
    public let installationID: String
    /// The app's version, as the person reads it.
    public let appVersion: String
    /// The macOS version, `26.0.1`.
    public let osVersion: String
    /// The processor architecture, `arm64` or `x86_64`.
    public let architecture: String
    /// How often the metrics are sent.
    public let interval: Duration

    public init(
        endpoint      : URL      = TelemetryConfiguration.defaultEndpoint,
        installationID: String,
        appVersion    : String,
        osVersion     : String   = TelemetryConfiguration.currentOSVersion,
        architecture  : String   = TelemetryConfiguration.currentArchitecture,
        interval      : Duration = .seconds(60)
    ) {
        self.endpoint       = endpoint
        self.installationID = installationID
        self.appVersion     = appVersion
        self.osVersion      = osVersion
        self.architecture   = architecture
        self.interval       = interval
    }

    // MARK: Whether to send

    /// The variable that turns telemetry off for one process: `0`, `false`, `off` or `no`.
    public static let switchVariable = "BRAUS_TELEMETRY"
    /// The variable that points telemetry at another collector.
    public static let endpointVariable = "BRAUS_TELEMETRY_ENDPOINT"

    /// Whether this process sends metrics. Off when `DO_NOT_TRACK` is set to anything but `0` or `false`, when
    /// `BRAUS_TELEMETRY` says off, or when the person turned it off (`stored` false); on otherwise, which is the
    /// default of a new installation.
    public static func isEnabled(environment: [String: String], stored: Bool?) -> Bool {
        if let value = environment["DO_NOT_TRACK"]?.lowercased(), !["", "0", "false"].contains(value) { return false }
        if let value = environment[switchVariable]?.lowercased(), ["0", "false", "off", "no"].contains(value) {
            return false
        }
        return stored ?? true
    }

    /// Whether the environment alone turns telemetry off, which the person's setting cannot undo.
    public static func isDisabledByEnvironment(_ environment: [String: String]) -> Bool {
        !isEnabled(environment: environment, stored: true)
    }

    /// The collector the environment names, or the default one. A value that is not an http or https URL is ignored.
    public static func endpoint(in environment: [String: String]) -> URL {
        guard let text = environment[endpointVariable], let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return defaultEndpoint }
        return url
    }

    // MARK: Installation

    /// The defaults key of the installation's identifier.
    public static let installationIDKey = "telemetry.installationID"

    /// The installation's identifier in `defaults`, made and stored on first use.
    public static func installationID(in defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: installationIDKey), UUID(uuidString: stored) != nil { return stored }
        let made = UUID().uuidString.lowercased()
        defaults.set(made, forKey: installationIDKey)
        return made
    }

    // MARK: This Mac

    public static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
