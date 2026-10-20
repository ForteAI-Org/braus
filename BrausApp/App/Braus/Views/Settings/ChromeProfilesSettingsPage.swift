//
//  ChromeProfilesSettingsPage.swift
//  Braus
//

import AppKit
import ChromeProfiles
import SwiftUI

/// ChromeProfilesSettingsPage connects the person's Chrome to Braus with one button, Connect Chrome, which sets
/// everything up on this Mac, opens Chrome's Extensions page and shows the extension folder selected in Finder; the
/// page then shows each profile once it is paired and connected. What only the person can do is said as theirs, in
/// few words: Developer mode, adding the folder, allowing it, naming the profile. A conversation chooses its profile
/// in the Inspector, under Web.
struct ChromeProfilesSettingsPage: View {

    let settings: ChromeProfilesSettings

    @State private var showsAdvanced = false

    var body: some View {
        Form {
            connectSection
            profilesSection
            if let problem = settings.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    advanced
                }
            }
        }
        .formStyle(.grouped)
        .task { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }

    // MARK: Connect Chrome

    private var connectSection: some View {
        Section {
            switch settings.stage {
                case .isolated:
                    Text("This run of Braus is isolated: it connects no Chrome.")
                        .foregroundStyle(.secondary)
                case .notConnected:
                    step(title: "Connect Chrome",
                         detail: "Braus sets itself up for Chrome on this Mac, then opens Chrome for the one step only you can take there.") {
                        Button("Connect Chrome", action: settings.connectChrome)
                            .buttonStyle(.borderedProminent)
                    }
                case .restartNeeded:
                    step(title: "Restart Braus to Finish",
                         detail: "Braus turned on web pages, which it uses once it opens again. It restarts only when no worker is answering.") {
                        Button("Restart Braus", action: settings.restartBraus)
                            .buttonStyle(.borderedProminent)
                    }
                case .addExtension:
                    step(title: "Add Braus to Chrome",
                         detail: "In Chrome's Extensions page, turn on Developer mode, then drag the Braus for Chrome folder onto the page, or choose Load unpacked and pick it. Allow it, then type a name for this profile and choose Confirm.") {
                        VStack(alignment: .trailing, spacing: 8) {
                            Button("Open Chrome", action: settings.openExtensionsPage)
                                .buttonStyle(.borderedProminent)
                            extensionFolderCard
                        }
                    }
                case .profilesNotConnected:
                    step(title: "Profiles Not Connected",
                         detail: "Your paired profiles connect to Braus while their Chrome is open with the Braus extension on.") {
                        Button("Open Chrome", action: settings.openConnectedChrome)
                    }
                case .ready:
                    step(title: "Chrome Is Connected",
                         detail: "Choose a profile for a conversation in the Inspector, under Web. To add another profile, switch to it in Chrome first.") {
                        Button("Add Another Profile", action: settings.openExtensionsPage)
                    }
            }
        } header: {
            Text("Chrome")
        }
    }

    /// The prepared extension folder, which the person can drag onto Chrome's Extensions page from here as from
    /// Finder.
    private var extensionFolderCard: some View {
        Label("Braus for Chrome", systemImage: "folder.fill")
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .onDrag { NSItemProvider(object: settings.extensionFolderURL as NSURL) }
            .help("Drag onto Chrome's Extensions page")
    }

    private func step<Action: View>(title: String, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.vertical, 4)
    }

    // MARK: Paired profiles

    private var profilesSection: some View {
        Section {
            if settings.profiles.isEmpty {
                Text("None Yet")
                    .foregroundStyle(.secondary)
            }
            ForEach(settings.profiles, id: \.instanceID) { profile in
                LabeledContent(profile.label) {
                    if profile.isConnected {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Not Connected")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("A profile is ready while it is connected to Braus. Revoke one on its Braus page in Chrome.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advanced: some View {
        LabeledContent("Web Pages") {
            switch settings.webPages {
                case .on            : Text("On")
                case .onAfterRestart: Button("Restart Braus", action: settings.restartBraus).controlSize(.small)
                case .off           : Button("Turn On", action: settings.turnOnWebPages).controlSize(.small)
                case .isolated      : Text("Off in This Run").foregroundStyle(.secondary)
                case .unreadable    : Text("Unreadable Setting").foregroundStyle(.orange)
            }
        }
        ForEach(settings.browsers) { row in
            LabeledContent(row.browser.name) {
                HStack {
                    registrationStatus(row.state)
                    registrationButton(row)
                }
            }
        }
        LabeledContent("Extension Folder") {
            switch settings.extensionFolder {
                case .current:
                    Button("Show in Finder", action: settings.revealExtensionFolder)
                        .controlSize(.small)
                case .notPrepared:
                    Button("Prepare", action: settings.prepareExtensionFolder)
                        .controlSize(.small)
                case .outdated:
                    Button("Update", action: settings.prepareExtensionFolder)
                        .controlSize(.small)
                case .notBundled:
                    Text("Missing From This Copy")
                        .foregroundStyle(.orange)
                case .foreign(let reason):
                    Text("Left As Is")
                        .foregroundStyle(.orange)
                        .help(reason)
            }
        }
        Text("Connecting a Chrome writes one file in that Chrome's own folder, so Chrome can start Braus's helper for the Braus extension; Braus never changes a file it did not write.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func registrationStatus(_ state: NativeHostRegistration.State) -> some View {
        switch state {
            case .registered:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help("Connected to Braus")
            case .registeredElsewhere:
                Text("Set for Another Copy of Braus")
                    .foregroundStyle(.orange)
            case .notRegistered:
                Text("Not Connected")
                    .foregroundStyle(.secondary)
            case .browserNotFound:
                Text("Open Chrome Once First")
                    .foregroundStyle(.secondary)
            case .foreign(let reason):
                Text("Left As Is")
                    .foregroundStyle(.orange)
                    .help(reason)
        }
    }

    @ViewBuilder
    private func registrationButton(_ row: ChromeProfilesSettings.Browser) -> some View {
        switch row.state {
            case .notRegistered:
                Button("Connect") { settings.register(row.browser) }
                    .controlSize(.small)
            case .registeredElsewhere:
                Button("Use This Copy") { settings.register(row.browser) }
                    .controlSize(.small)
            case .registered:
                Button("Disconnect") { settings.unregister(row.browser) }
                    .controlSize(.small)
            case .browserNotFound:
                Button("Open") { settings.open(row.browser) }
                    .controlSize(.small)
            case .foreign:
                EmptyView()
        }
    }
}
