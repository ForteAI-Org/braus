//
//  SettingsView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import SwiftUI

/// SettingsView is the Settings window: a sidebar of pages at the leading
/// edge, the app's own and then one per provider, and the chosen page beside
/// it as a grouped form, in the inspector's language, with its title in the
/// window's bar. Opening it checks every connection again, since the provider
/// pages show their state.
///
/// The sidebar's symbols are not in the accent: primary on the chosen page and
/// secondary on the rest, so the accent is left to the selection itself.
struct SettingsView: View {

    /// The Settings window's scene, which the app menu's Settings… opens.
    static let windowID = "settings"

    let store : ModelSettingsStore
    let broker: SeatBroker

    /// The pairing of the person's Chrome profiles, which the Chrome Profiles page shows and sets up.
    let chromeProfiles: ChromeProfilesSettings?

    @State private var pane: SettingsPane?

    /// - Parameter pane: the page shown first, General unless a snapshot asks for another.
    init(
        store     : ModelSettingsStore,
        broker    : SeatBroker,
        chromeProfiles   : ChromeProfilesSettings? = nil,
        pane             : SettingsPane = .general
    ) {
        self.store             = store
        self.broker            = broker
        self.chromeProfiles = chromeProfiles
        _pane               = State(initialValue: pane)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    ForEach(SettingsPane.appPanes.filter(isListed)) { row($0) }
                }

                Section("Computer") {
                    ForEach(SettingsPane.computerPanes.filter(isListed)) { row($0) }
                }

                Section("Providers") {
                    ForEach(ModelProvider.allCases) { row(.provider($0)) }
                }
            }
            .navigationSplitViewColumnWidth(
                min  : 180,
                ideal: 200,
                max  : 240
            )
            .scrollContentBackground(.hidden)
            .background { Color.houseSidebar.ignoresSafeArea() }
            
        } detail: {
            page
                .navigationTitle(pane?.title ?? "Settings")
                .scrollContentBackground(.hidden)
                .background { Color.houseGround.ignoresSafeArea() }
        }
        // It can grow, which the Brain's graph uses.
        .frame(
            minWidth   : 720,
            idealWidth : 860,
            minHeight  : 540,
            idealHeight: 620
        )
        .task { store.refresh() }
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            Image(systemName: pane.symbol)
                .foregroundStyle(pane == self.pane ? Color.primary : Color.secondary)
        }
        .tag(pane)
    }

    @ViewBuilder
    private var page: some View {
        switch pane ?? .general {
        case .general:
            GeneralSettings()
        case .computer:
            ComputerSettings(broker: broker)
        case .chromeProfiles:
            if let chromeProfiles { ChromeProfilesSettingsPage(settings: chromeProfiles) }
        case .virtualDisplay:
            VirtualDisplaySettings(broker: broker)
        case .brain:
            BrainSettings(directory: WorkspaceLaunch.directory.appending(
                path         : "Knowledge",
                directoryHint: .isDirectory
            ))
        case .sidebar:
            SidebarSettings()
        case .chat:
            ChatSettings()
        case .provider(let provider):
            ProviderSettingsPage(
                store   : store,
                provider: provider
            )
            .id(provider)
        }
    }

    /// Chrome Profiles is listed wherever the app provides pairing, including while web pages are off.
    private func isListed(_ pane: SettingsPane) -> Bool {
        if case .chromeProfiles = pane { return chromeProfiles != nil }
        return true
    }
}
