//
//  AppModel.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import AutomationRuntime
import ChromeProfiles
import Foundation
import LocalMCP
import MacSession
import ModelTransports
import Router
import SeatBroker
import WebDriver
import WebSession
import os

/// AppModel is what every window of the app shares: the seat broker the
/// workers' desktops go through, and the model settings.
///
/// Every connection is checked once as the app starts, in the background, so
/// the sidebar's badge and the workers' models are known before anyone opens
/// Connections, unless Settings > General turns it off. A check or test run
/// checks nothing: it would run the `codex` and `claude` command lines for real.
@MainActor
final class AppModel {

    let broker = SeatBroker(configuration: .init(allowUnvalidatedBuild: true))

    let settings = ModelSettingsStore()

    /// The routes beyond the Seat this run composes, read once from `AppPreferences.channels`.
    let channels = AppModel.launchChannels

    /// The person's Chrome profiles paired with the Braus extension, which a conversation may choose for its pages:
    /// listening under the app's directory (`ChromeProfiles`) when the run composes `.web`, nil otherwise. A check
    /// run listens for none.
    let chromeProfiles: ChromeProfileHub? = AppModel.launchChannels.contains(.web) && !BrausApp.isCheckRun
        ? ChromeProfileHub(directory: WorkspaceLaunch.directory.appending(path: "ChromeProfiles",
                                                                          directoryHint: .isDirectory))
        : nil

    /// What Settings, Chrome Profiles shows and does: web pages on or off, each Chrome's registration of the host,
    /// the extension folder, the paired profiles. Made when Settings first shows it; it writes nothing until asked.
    lazy var chromeProfilesSettings = ChromeProfilesSettings(hub: chromeProfiles)

    /// `storedChannels` as this process read it first: one value for the whole run. An isolated run
    /// (`LaunchIsolation`) composes none.
    static let launchChannels: AutomationChannels = LaunchIsolation.current.isIsolated ? [] : AppModel.storedChannels

    /// The irreversible adapter calls waiting for the person, shared by the workers and the external clients.
    let approvals = AdapterApprovals()

    /// External clients share the app's Seat broker and the user's one living memory with the workers
    /// (`KnowledgeLocation`, G76): what a client learns the workers may reuse and the other way round, each
    /// call recorded with the `mcp` source and the profile as its stream, each task its own. A client's
    /// earlier private archive is unified into it once (`MemoryService.unify`), and kept where it was.
    lazy var mcp = MCPConnectionsModel(
        directory: WorkspaceLaunch.directory.appendingPathComponent("MCP", isDirectory: true),
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/braus-bridge")
    ) { [broker, channels, mcpBarriers, approvals] profile, activity in
        // One owner per connection: its native leases are its own (I03).
        let owner = UUID()
        let desktop = BrokeredAutomationSession(
            broker: broker,
            workerID: owner,
            knowledgeDirectory: KnowledgeLocation.knowledge(under: WorkspaceLaunch.directory)
        )
        let web: WebAutomationSession? = channels.contains(.web) ? AppModel.webSession() : nil
        let session = ExternalMCPSession(
            profile: profile,
            session: AppModel.session(
                desktop : desktop,
                channels: channels,
                web     : web,
                owner   : owner
            ),
            channels: channels,
            perform: { body in
                var result = LocalMCP.JSONValue.null
                try await desktop.turn { result = try await body() }
                return result
            },
            activity: activity,
            barrier: mcpBarriers.barrier(for: profile.id.uuidString),
            adapterApprover: AdapterApprover(approvals: approvals)
        )
        return MCPHostSession(router: session.router) { await session.close() }
    }

    /// One barrier per external client profile (R05): a client that reconnects gets a new session, never a reset of
    /// what the person refused it, and since P2-06 neither does a restart of the app, the refusals kept in the refusal
    /// file in the support folder.
    let mcpBarriers = ActionBarrier.Store(persistingIn: AppModel.refusalFolder)

    /// The folder holding persistent consent decisions for each execution context.
    static var refusalFolder: URL { WorkspaceLaunch.directory.appendingPathComponent("Refusals", isDirectory: true) }

    /// The session a worker or an external client drives: the desktop alone, or with `.native` or `.web`
    /// the router in front of it. `web:<host>` and URLs go to the Chrome tab `web`, a native app to the
    /// MacDriver, and what it gives back to the desktop. Neither the web side nor the MacDriver takes a seat,
    /// and a turn with no desktop session open holds nothing, so the queue stays as it was. The MacDriver leases
    /// each app for `owner`, the worker or the client connection, so two of them never drive one app (I03).
    static func session(
        desktop : BrokeredAutomationSession,
        channels: AutomationChannels,
        web     : WebAutomationSession?,
        owner   : UUID
    ) -> any AutomationSessionOperating {
        guard !channels.isDisjoint(with: [.native, .web]) else { return desktop }
        let knowledge = KnowledgeLocation.knowledge(under: WorkspaceLaunch.directory)
        return RoutingAutomationSession(
            native : channels.contains(.native) ? MacAutomationSession(knowledgeDirectory: knowledge, leaseOwner: owner)
                                                : nil,
            desktop: desktop,
            web    : channels.contains(.web) ? web : nil
        )
    }

    /// The channels Settings or a launch argument chose (`AppPreferences.channels`): a value that does not
    /// parse composes none, and says so in the log, so a misspelled name never turns a route on.
    static var storedChannels: AutomationChannels {
        let stored = UserDefaults.standard.string(forKey: AppPreferences.channels) ?? AppPreferences.channelsDefault
        do {
            var channels = try AutomationChannels(parsing: stored)
            if UserDefaults.standard.bool(forKey: AppPreferences.web) { channels.insert(.web) }
            return channels
        } catch {
            Logger(subsystem: "dev.forte.Braus", category: "Channels")
                .error("Ignoring \(AppPreferences.channels, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// A web session on Braus's own Chrome profile, `chrome-web` under the app's directory, recording into
    /// the shared memory. One session at a time runs on the profile; another is refused until it closes.
    /// `personal` opens its pages in the person's own Chrome instead (`WebAutomationSession.usesPersonalChrome`), and
    /// `profile` in one of their Chrome profiles paired through `hub`, which takes precedence over both: the chosen
    /// profile or nothing, never a fallback.
    static func webSession(
        showsWindow: Bool = false,
        personal   : Bool = false,
        profile    : ChromeProfileChoice? = nil,
        hub        : ChromeProfileHub? = nil
    ) -> WebAutomationSession {
        let session = WebAutomationSession(
            knowledgeDirectory: KnowledgeLocation.knowledge(under: WorkspaceLaunch.directory),
            launchOptions     : chromeOptions(showsWindow: showsWindow),
            connectProfile    : { instanceID, gate in
                guard let hub else { throw ChromeProfileError.notRunning }
                return try await hub.connect(instanceID, gate: gate)
            }
        )
        session.usesPersonalChrome = personal
        session.chromeProfile      = profile
        return session
    }

    /// Braus's Chrome, headless unless the conversation asked to see its window.
    static func chromeOptions(showsWindow: Bool) -> ChromeLaunchOptions {
        ChromeLaunchOptions(
            userDataDirectory: WorkspaceLaunch.directory.appending(path: "chrome-web", directoryHint: .isDirectory),
            isHeadless       : !showsWindow
        )
    }

    /// The Knowledge directory an external client's profile had before G76, under the app's support
    /// directory: `MCP/Knowledge/<profile>`. Nothing writes there any more; the shared memory unifies it
    /// (`KnowledgeLocation.legacyProfiles`).
    nonisolated static func knowledgeDirectory(of profile: UUID, under support: URL) -> URL {
        support.appendingPathComponent("MCP/Knowledge/" + profile.uuidString, isDirectory: true)
    }

    init() {
        broker.display = Self.storedDisplay
        // The external clients' earlier private archives, and the knowledge the product kept under its earlier name, come
        // into the shared memory when it first opens. A check run reads no folder of the person's.
        MemoryService.unify(KnowledgeLocation.knowledge(under: WorkspaceLaunch.directory),
                            with: KnowledgeLocation.legacyProfiles(under: WorkspaceLaunch.directory)
                                + (BrausApp.isCheckRun ? [] : KnowledgeLocation.previousProductOrigins()))
        let checks = AppPreferences.bool(
            AppPreferences.checksConnectionsAtLaunch,
            default: AppPreferences.checksConnectionsAtLaunchDefault
        )
        // A check run or an isolated run checks nothing at launch: it would run the command lines for real.
        if checks, !BrausApp.isCheckRun, !LaunchIsolation.current.isIsolated { settings.refresh() }
        // The extension's native host reaches the hub at its socket; a hub that cannot listen leaves every paired
        // profile disconnected, so a conversation that chose one is refused rather than sent elsewhere.
        do { try chromeProfiles?.start() } catch {
            Logger(subsystem: "dev.forte.Braus", category: "ChromeProfiles")
                .error("The Chrome profiles' hub is not listening: \(String(describing: error), privacy: .public)")
        }
    }

    /// The virtual display Settings chose, the standard one until it chooses another.
    static var storedDisplay: SeatDisplay {
        let defaults = UserDefaults.standard
        let size     = defaults.string(forKey: AppPreferences.seatDisplaySize) ?? AppPreferences.seatDisplaySizeDefault
        let rate     = defaults.object(forKey: AppPreferences.seatRefreshRate) as? Int ?? AppPreferences.seatRefreshRateDefault
        return SeatDisplay(size: size, refreshRate: rate) ?? .standard
    }
}
