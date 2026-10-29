//
//  BrausApp.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import AutomationRuntime
import SeatBroker
import SwiftUI
import Telemetry

/// Started by `BrausEntry`, which refuses an isolated run that is not valid first.
struct BrausApp: App {

    @State private var model = AppModel()

    /// The workspace database, which the team window reads. It is opened here
    /// so a store that cannot open says so at launch rather than at the first
    /// click.
    @State private var workspace = WorkspaceLaunch()

    @NSApplicationDelegateAdaptor(SeatReleasingDelegate.self)
    private var delegate

    /// Whether the person was told that Braus sends anonymous usage metrics, which the first launch does once.
    @AppStorage(AppPreferences.toldOfTelemetry)
    private var toldOfTelemetry = false

    @State private var showsTelemetryNotice = false

    /// A snapshot or window check run, which draws its own windows and quits,
    /// or the host of the unit tests, which must not open the person's workspace either.
    static var isCheckRun: Bool {
        WindowSnapshots.isRequested
            || WindowResizeCheck.isRequested
            || TranscriptCopyCheck.isRequested
            || WindowClickCheck.isRequested
            || RoomCostCheck.isRequested
            || isTestHost
    }

    /// The app launched by `xcodebuild test` to host `BrausTests`.
    static var isTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment

        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains {
            environment[$0] != nil
        }
    }

    init() {
        // A restored team window would open the person's workspace; a snapshot run must not, nor an isolated one.
        if Self.isCheckRun || LaunchIsolation.current.isIsolated {
            UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
        }
        AppTelemetry.apply()
    }

    var body: some Scene {

        // The team is the front door. It asks for no grant until a worker first opens an app.
        WindowGroup("Braus") {
            TeamWindowView(
                launch     : workspace,
                connections: model.settings,
                broker     : model.broker,
                didOpenTeam: { delegate.teams.add($0) },
                channels      : model.channels,
                chromeProfiles: model.chromeProfiles,
                approvals  : model.approvals
            )
            // The delegate is made by AppKit and the model by SwiftUI, so
            // this window, the one that always exists, is where they meet.
            .task {
                delegate.model = model
                // Settings' Restart Braus waits for every team's answering worker and every busy client.
                model.chromeProfilesSettings.isBusy = { [delegate, model] in
                    delegate.teams.allObjects.contains { !$0.answering.isEmpty } || model.mcp.isBusy
                }
                if !Self.isCheckRun { await model.mcp.prepare() }
                showsTelemetryNotice = !toldOfTelemetry && Telemetry.isRunning
            }
            // Said once, on the first launch that sends: what is sent, and where to turn it off.
            .alert("Braus Shares Anonymous Usage Metrics", isPresented: $showsTelemetryNotice) {
                Button("OK") { toldOfTelemetry = true }
                Button("Turn Off") {
                    toldOfTelemetry = true
                    UserDefaults.standard.set(false, forKey: AppPreferences.sharesTelemetry)
                    AppTelemetry.apply()
                }
            } message: {
                Text("To improve Braus, it sends Forte which tools ran, how they ended and how long they took, "
                     + "with a random installation ID. Never your messages, files, pages, apps or account. "
                     + "You can turn this off any time in Settings > General.")
            }
        }
        // A snapshot run draws offscreen and quits; it opens no window and no workspace.
        .defaultLaunchBehavior(Self.isCheckRun ? .suppressed : .automatic)
        .commands {
            // The team's sidebar turns compact and is never hidden, so the View menu has no place for it.
            CommandGroup(replacing: .sidebar) {}
            TextSizeCommands()
            TeamMenuCommands()
            HouseFindCommands()
            SettingsCommands()
            MCPConnectionsCommands()
        }

        Window("MCP Connections", id: MCPConnectionsView.windowID) {
            MCPConnectionsView(model: model.mcp)
                .task {
                    delegate.model = model
                    if !Self.isCheckRun { await model.mcp.prepare() }
                }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // A window of its own rather than the Settings scene, for the full title bar and toolbar.
        Window(
            "Settings",
            id: SettingsView.windowID
        ) {
            SettingsView(
                store            : model.settings,
                broker           : model.broker,
                chromeProfiles   : model.chromeProfilesSettings
            )
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
