//
//  LaunchIsolation.swift
//  Braus
//

import Foundation

/// LaunchIsolation is whether the app runs apart from the person's data, for the smoke launch of a build (B2).
/// It is decided once, from the environment, before anything of the person's is read.
///
/// `BRAUS_ISOLATED_RUN=1` asks for it. It holds only with `BRAUS_APP_SUPPORT_DIR` naming an absolute folder that is
/// not the person's own support folder. Then the app queries and writes no keychain item, checks no connection at
/// launch, composes no channel beyond the Seat and restores no window. Asked for and not valid, the run must not
/// start at all (`invalid`): it never falls back to the person's folder. Not asked for, nothing changes.
///
/// It is the app's switch for a smoke launch, not a product mode: the command line ignores it.
nonisolated public enum LaunchIsolation: Sendable, Equatable {

    /// Not asked for.
    case off

    /// Asked for, with the support folder it keeps everything in.
    case isolated(support: URL)

    /// Asked for and not valid: the app refuses to start, with the reason.
    case invalid(reason: String)

    /// The environment variable that asks for an isolated run.
    public static let variable = "BRAUS_ISOLATED_RUN"

    /// The run's isolation, from `environment`. `personal` is the person's own support folder, which an isolated run
    /// may not use.
    public init(environment: [String: String], personal: URL = KnowledgeLocation.support(environment: [:])) {
        guard let asked = environment[Self.variable], !asked.isEmpty else {
            self = .off
            return
        }
        guard asked == "1" else {
            self = .invalid(reason: "\(Self.variable) must be 1 or unset, not \"\(asked)\"")
            return
        }
        let override = KnowledgeLocation.supportOverride
        guard let named = environment[override], !named.isEmpty else {
            self = .invalid(reason: "an isolated run needs \(override) naming an absolute folder")
            return
        }
        // `~` is not expanded here: the app's workspace takes the folder as written, so only an absolute path is the
        // same folder for every reader.
        guard named.hasPrefix("/") else {
            self = .invalid(reason: "\(override) must be an absolute path in an isolated run, not \"\(named)\"")
            return
        }
        let support = URL(fileURLWithPath: named, isDirectory: true).standardizedFileURL
        func resolved(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        guard resolved(support) != "/", resolved(support) != resolved(personal) else {
            self = .invalid(reason: "\(override) must name a folder of its own in an isolated run, not \"\(named)\"")
            return
        }
        self = .isolated(support: support)
    }

    /// This process's isolation, read once.
    public static let current = LaunchIsolation(environment: ProcessInfo.processInfo.environment)

    /// Whether isolation was asked for, valid or not: what keeps the keychain, the launch checks, the channels and
    /// the restored windows away.
    public var isIsolated: Bool { self != .off }

    /// Why the app must not start, nil when it may.
    public var refusal: String? {
        guard case .invalid(let reason) = self else { return nil }
        return reason
    }

    /// The bundle identifier of the smoke build (B2), which may only run isolated.
    public static let smokeBundleID = "dev.forte.Braus.smoke"

    /// Why an app with `bundleID` must not start under this isolation, nil when it may: an isolation that is not
    /// valid, or the smoke build without a valid one, as a launch from Finder, by the system or by a tool that passes
    /// no environment would be. Any other bundle runs as before when isolation is not asked for.
    public func refusal(bundleID: String?) -> String? {
        if let refusal { return refusal }
        guard bundleID == Self.smokeBundleID, case .off = self else { return nil }
        return "the smoke build \(Self.smokeBundleID) runs only isolated, with \(Self.variable)=1 and "
            + "\(KnowledgeLocation.supportOverride) naming an absolute folder of its own"
    }
}
