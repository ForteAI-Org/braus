//
//  AppPreferences.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation

/// AppPreferences names the app's own settings, which Settings edits through
/// `@AppStorage` and the team window reads through `AppPreferenceValues`, each
/// key with its default beside it so every reader starts from the same value.
/// The provider settings are not here: they belong to `ModelSettingsStore`.
enum AppPreferences {

    // MARK: General

    /// Whether every connection is checked in the background as the app starts.
    static let checksConnectionsAtLaunch        = "general.checksConnectionsAtLaunch"
    static let checksConnectionsAtLaunchDefault = true

    /// The font family of the conversation's text; empty is the system font.
    static let chatFontFamily        = "chat.fontFamily"
    static let chatFontFamilyDefault = ""

    // MARK: Computer

    /// The virtual display a worker's seat is made with, as `SeatDisplay`'s width by height in pixels.
    static let seatDisplaySize        = "computer.displaySize"
    static let seatDisplaySizeDefault = "2560x1440"

    /// The virtual display's refresh rate in hertz, 60 or 120.
    static let seatRefreshRate        = "computer.refreshRate"
    static let seatRefreshRateDefault = 60

    /// The conversations whose worker shows Braus's Chrome as a window; every other one keeps it headless.
    static let showsBrowserWindow = "computer.showsBrowserWindow"

    /// The conversations whose worker opens its pages in the person's own Chrome, signed in as them, instead of
    /// Braus's; every other one keeps Braus's Chrome. None by default.
    static let usesPersonalChrome = "computer.usesPersonalChrome"

    /// The paired Chrome profile each conversation's worker opens its pages in (`ChromeProfileHub`): by conversation,
    /// the Braus extension instance's ID and the name the person confirmed for it. None by default; a choice takes
    /// precedence over `usesPersonalChrome`.
    static let chromeProfiles = "computer.chromeProfiles"

    /// The routes beyond the Seat this run composes (`AutomationChannels`), comma separated, read once as
    /// app on the Seat. A launch argument (`-computer.channels native,web`) sets it for one run.
    static let channels        = "computer.channels"
    static let channelsDefault = ""

    /// Legacy web-only composition switch, honored alongside the channel selection.
    static let web = "computer.web"
    // MARK: Sidebar

    /// Whether a worker's row shows its model under the name when nothing else is said there.
    static let sidebarShowsModel        = "sidebar.showsModel"
    static let sidebarShowsModelDefault = true

    /// Whether a worker's row counts its unread messages. A failed turn is marked either way.
    static let sidebarShowsUnreadCount        = "sidebar.showsUnreadCount"
    static let sidebarShowsUnreadCountDefault = true

    /// Whether the sidebar has a field to find a worker by name.
    static let sidebarShowsSearch        = "sidebar.showsSearch"
    static let sidebarShowsSearchDefault = true

    // MARK: Chat

    /// Whether the time is written under the messages.
    static let chatShowsTimes        = "chat.showsTimes"
    static let chatShowsTimesDefault = true

    /// Whether Return starts a new line and Command-Return sends, instead of Return sending.
    static let chatSendsWithCommandReturn        = "chat.sendsWithCommandReturn"
    static let chatSendsWithCommandReturnDefault = false

    /// Whether a turn's tool steps are shown open rather than as one summary line.
    static let chatOpensToolSteps        = "chat.opensToolSteps"
    static let chatOpensToolStepsDefault = false

    /// Whether a Claude Code or Codex worker may search the web and read pages with its own tools.
    /// A turn reads it as it starts.
    static let workersSearchWeb        = "chat.workersSearchWeb"
    static let workersSearchWebDefault = true

    /// The stored value of a Bool preference in `defaults`, its default when none is stored.
    static func bool(
        _ key           : String,
        default fallback: Bool,
        in defaults     : UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
}
