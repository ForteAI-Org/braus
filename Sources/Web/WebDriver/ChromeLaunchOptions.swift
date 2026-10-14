//
//  ChromeLaunchOptions.swift
//  Braus
//

import Foundation

/// ChromeLaunchOptions says which Chrome to start, on which profile and how.
///
/// A profile directory belongs to one running Chrome at a time: Chrome refuses a second process
/// on a directory that is in use, so two hosts that share one must not run together.
public struct ChromeLaunchOptions: Sendable, Hashable {

    /// The Chrome binary, by default the one in `/Applications`.
    public var executableURL: URL

    /// The profile: cookies, logins and history live here and survive the process.
    public var userDataDirectory: URL

    /// Whether Chrome runs with no window (`--headless`). A headed Chrome shows its window on
    /// the user's screen.
    public var isHeadless: Bool

    /// The viewport of a new page, in CSS pixels.
    public var windowWidth : Int
    public var windowHeight: Int

    /// Where Chrome's standard error goes, nil to discard it.
    public var standardErrorURL: URL?

    /// Further switches, appended after the ones these options produce.
    public var additionalArguments: [String]

    public init(
        executableURL      : URL     = ChromeLaunchOptions.applicationsChrome,
        userDataDirectory  : URL,
        isHeadless         : Bool    = true,
        windowWidth        : Int     = 1280,
        windowHeight       : Int     = 800,
        standardErrorURL   : URL?    = nil,
        additionalArguments: [String] = []
    ) {
        self.executableURL       = executableURL
        self.userDataDirectory   = userDataDirectory
        self.isHeadless          = isHeadless
        self.windowWidth         = windowWidth
        self.windowHeight        = windowHeight
        self.standardErrorURL    = standardErrorURL
        self.additionalArguments = additionalArguments
    }

    /// `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.
    public static let applicationsChrome = URL(
        fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    )

    /// Braus's own profile, `chrome-web` inside the given Application Support directory, so a
    /// web session never borrows the profile of the user's everyday Chrome.
    public static func brausProfile(applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "Braus/chrome-web", directoryHint: .isDirectory)
    }

    /// The switches Chrome is started with, without the executable.
    public var arguments: [String] {
        var arguments = [
            "--remote-debugging-pipe",
            "--user-data-dir=\(userDataDirectory.path(percentEncoded: false))",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-renderer-backgrounding",
            "--disable-background-timer-throttling",
            "--disable-backgrounding-occluded-windows",
            "--window-size=\(windowWidth),\(windowHeight)",
        ]
        if isHeadless { arguments.append("--headless") }
        arguments.append(contentsOf: additionalArguments)
        arguments.append("about:blank")
        return arguments
    }
}
