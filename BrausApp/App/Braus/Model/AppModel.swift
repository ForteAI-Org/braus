//
//  AppModel.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import AutomationRuntime
import Foundation
import LocalMCP
import ModelTransports
import SeatBroker
import WebDriver
import WebSession

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

    /// The irreversible adapter calls waiting for the person, shared by the workers and the external clients.
    let approvals = AdapterApprovals()

    /// External clients share the app's Seat broker and the user's one living memory with the workers
    /// (`KnowledgeLocation`, G76): what a client learns the workers may reuse and the other way round, each
    /// call recorded with the `mcp` source and the profile as its stream, each task its own. A client's
    /// earlier private archive is unified into it once (`MemoryService.unify`), and kept where it was.
    lazy var mcp = MCPConnectionsModel(
        directory: WorkspaceLaunch.directory.appendingPathComponent("MCP", isDirectory: true),
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/braus-bridge")
    ) { [broker, approvals] profile, activity in
        let desktop = BrokeredAutomationSession(
            broker: broker,
            workerID: UUID(),
            knowledgeDirectory: KnowledgeLocation.knowledge(under: WorkspaceLaunch.directory)
        )
        let offersWeb = UserDefaults.standard.bool(forKey: AppPreferences.web)
        // The web side takes no seat, and a turn with no desktop session open holds none.
        let routed: any AutomationSessionOperating = offersWeb
            ? RoutingAutomationSession(
                desktop: desktop,
                web    : AppModel.webSession()
            )
            : desktop
        let session = ExternalMCPSession(
            profile: profile,
            session: routed,
            perform: { body in
                var result = LocalMCP.JSONValue.null
                try await desktop.turn { result = try await body() }
                return result
            },
            activity: activity,
            adapterApprover: AdapterApprover(approvals: approvals),
            offersWeb: offersWeb
        )
        return MCPHostSession(router: session.router) { await session.close() }
    }

    /// A web session on Braus's own Chrome profile, `chrome-web` in the app's directory, recording into the
    /// shared memory. One session at a time runs on the profile; another is refused until it closes.
    static func webSession(showsWindow: Bool = false) -> WebAutomationSession {
        WebAutomationSession(
            knowledgeDirectory: KnowledgeLocation.knowledge(under: WorkspaceLaunch.directory),
            launchOptions     : chromeOptions(showsWindow: showsWindow)
        )
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
        if checks, !BrausApp.isCheckRun { settings.refresh() }
    }

    /// The virtual display Settings chose, the standard one until it chooses another.
    static var storedDisplay: SeatDisplay {
        let defaults = UserDefaults.standard
        let size     = defaults.string(forKey: AppPreferences.seatDisplaySize) ?? AppPreferences.seatDisplaySizeDefault
        let rate     = defaults.object(forKey: AppPreferences.seatRefreshRate) as? Int ?? AppPreferences.seatRefreshRateDefault
        return SeatDisplay(size: size, refreshRate: rate) ?? .standard
    }
}
