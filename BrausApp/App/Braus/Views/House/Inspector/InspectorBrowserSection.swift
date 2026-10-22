//
//  InspectorBrowserSection.swift
//  Braus
//
//  Created by Simone Lovera on 14/10/2026.
//

import ChromeProfiles
import SwiftUI
import WebSession

/// The conversation's choice of browser: Braus's own Chrome, headless by default or as a window the person can
/// watch; the person's own Chrome, signed in as them, which they turn on themselves; or one of their Chrome profiles
/// paired with Braus through its extension, under the name they confirmed there. A paired profile takes precedence
/// over the others, and one that cannot be used is refused rather than replaced. Either way the pages are driven from
/// inside Chrome, so its window never takes the person's focus. Shown only for the open conversation of the selected
/// worker.
struct InspectorBrowserSection: View {

    let team  : TeamModel
    let worker: WorkerSnapshot

    /// Vertical padding added to each row, and the gap held after the section; the app's inspector
    /// keeps the system's own, the house passes its own.
    var rowPadding: CGFloat = 0
    var footerGap : CGFloat = 0

    var body: some View {
        if team.composesWeb, let conversation = team.conversation, conversation.participantIDs.contains(worker.id) {
            let profile  = team.chromeProfile(in: conversation.id)
            let personal = profile == nil && team.usesPersonalChrome(in: conversation.id)
            let paired   = team.pairedChromeProfiles
            Section {
                Picker(
                    "Chrome Profile",
                    selection: Binding(
                        get: { team.chromeProfile(in: conversation.id)?.instanceID ?? "" },
                        set: { instanceID in
                            let choice = team.pairedChromeProfiles.first { $0.instanceID == instanceID }
                                .map { ChromeProfileChoice(instanceID: $0.instanceID, label: $0.label) }
                            Task { await team.setChromeProfile(choice, in: conversation.id) }
                        }
                    )
                ) {
                    Text("None").tag("")
                    ForEach(paired, id: \.instanceID) { candidate in
                        Text(candidate.isConnected ? candidate.label : "\(candidate.label) (Not Connected)")
                            .tag(candidate.instanceID)
                    }
                    // A choice whose pairing was revoked stays shown, so the person sees why pages are refused.
                    if let profile, !paired.contains(where: { $0.instanceID == profile.instanceID }) {
                        Text("\(profile.label) (No Longer Paired)").tag(profile.instanceID)
                    }
                }
                .disabled(paired.isEmpty && profile == nil)
                .padding(.vertical, rowPadding)
                Toggle(
                    "Use My Chrome",
                    isOn: Binding(
                        get: { team.usesPersonalChrome(in: conversation.id) },
                        set: { uses in Task { await team.setUsesPersonalChrome(uses, in: conversation.id) } }
                    )
                )
                .disabled(profile != nil)
                .padding(.vertical, rowPadding)
                Toggle(
                    "Show Chrome Window",
                    isOn: Binding(
                        get: { team.showsBrowserWindow(in: conversation.id) },
                        set: { shows in Task { await team.setShowsBrowserWindow(shows, in: conversation.id) } }
                    )
                )
                .disabled(personal || profile != nil)
                .padding(.vertical, rowPadding)
            } header: {
                Text("Web")
            } footer: {
                if let profile {
                    Text("Braus opens its pages in a tab of your Chrome profile “\(profile.label)”, paired through the Braus extension, signed in as that profile, and closes only the tabs it opened. If that Chrome is closed, the extension is off or you revoke the pairing, Braus stops and asks rather than using another profile or browser. Workers are told to ask you before they post, send, buy or delete anything as you. A change applies the next time Braus opens a page.")
                        .padding(.bottom, footerGap)
                } else if personal {
                    Text("Braus opens its pages in a new window of your own Chrome, signed in as you, and closes only the tabs it opened. Keep Chrome open with remote debugging on (chrome://inspect/#remote-debugging); Chrome asks you to allow each connection. Workers are told to ask you before they post, send, buy or delete anything as you. A change applies the next time Braus opens a page.")
                        .padding(.bottom, footerGap)
                } else {
                    Text("Braus drives pages in its own Chrome, never yours, with a profile of its own that Braus keeps between sessions and never shares with your Chrome. Show its window to sign in to a site yourself, turn on Use My Chrome, or choose a Chrome profile you paired through the Braus extension to use your own sign-ins. Shown or hidden, it does not take your focus. A change applies the next time Braus opens a page.")
                        .padding(.bottom, footerGap)
                }
            }
        }
    }
}
