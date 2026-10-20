//
//  ChromeBrowser.swift
//  Braus
//

import Foundation

/// ChromeBrowser is one Chrome a Mac may have, which keeps its own user data folder under Application Support:
/// its profiles, and the native messaging hosts registered for them (`NativeHostRegistration`).
public struct ChromeBrowser: Sendable, Hashable, Identifiable {

    public let name    : String
    public let bundleID: String
    /// Its user data folder, under Application Support.
    public let dataFolder: String

    public var id: String { bundleID }

    public static let googleChrome     = ChromeBrowser(name: "Google Chrome", bundleID: "com.google.Chrome",
                                                       dataFolder: "Google/Chrome")
    public static let chromeBeta       = ChromeBrowser(name: "Google Chrome Beta", bundleID: "com.google.Chrome.beta",
                                                       dataFolder: "Google/Chrome Beta")
    public static let chromeDev        = ChromeBrowser(name: "Google Chrome Dev", bundleID: "com.google.Chrome.dev",
                                                       dataFolder: "Google/Chrome Dev")
    public static let chromeCanary     = ChromeBrowser(name: "Google Chrome Canary",
                                                       bundleID: "com.google.Chrome.canary",
                                                       dataFolder: "Google/Chrome Canary")
    public static let chromium         = ChromeBrowser(name: "Chromium", bundleID: "org.chromium.Chromium",
                                                       dataFolder: "Chromium")
    public static let chromeForTesting = ChromeBrowser(name: "Chrome for Testing",
                                                       bundleID: "com.google.chrome.for.testing",
                                                       dataFolder: "Google/Chrome for Testing")

    /// Google Chrome first, then its other channels, Chromium and Chrome for Testing.
    public static let known: [ChromeBrowser] = [
        googleChrome, chromeBeta, chromeDev, chromeCanary, chromium, chromeForTesting,
    ]

    /// The environment variable that replaces Application Support as the parent of every user data folder, for
    /// one launch: a fixture's temporary folders, never the person's.
    public static let supportVariable = "BRAUS_CHROME_SUPPORT_DIR"

    /// The user data folder under `support`.
    public func userDataDirectory(under support: URL) -> URL {
        support.appending(path: dataFolder, directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support`, or the absolute folder `supportVariable` names.
    public static func supportDirectory(environment: [String: String]) -> URL {
        if let named = environment[supportVariable], named.hasPrefix("/") {
            return URL(filePath: named, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }
}
