//
//  WebBrowsers.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/09/2026.
//

import AppKit

/// WebBrowsers answers which applications are web browsers and which one is the person's: a
/// browser is one of the well-known ones below or the application Launch Services opens https with
/// by default. Registering for https is not enough, because kitty and Codex do it too. The default
/// is read from Launch Services on every call, so one the person changes is seen at once; nothing
/// is opened.
public enum WebBrowsers {

    /// Only the scheme is looked up: no page is loaded.
    private static let web = URL(string: "https://example.com")

    /// The well-known browsers, one family per line: Safari, Chrome channels, Chromium, Edge
    /// channels, Brave channels, Arc, Firefox channels, Opera, Vivaldi, Orion, DuckDuckGo, Zen,
    /// Island.
    private static let known: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "company.thebrowser.Browser",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
        "com.duckduckgo.macos.browser",
        "app.zen-browser.zen",
        "io.island.Island"
    ]

    /// The bundle identifiers of the well-known browsers and of the default one.
    public static func bundleIDs() -> Set<String> {
        bundleIDs(defaultID: defaultBundleID())
    }

    /// The decision apart from Launch Services, so it can be tested.
    static func bundleIDs(defaultID: String?) -> Set<String> {
        defaultID.map { known.union([$0]) } ?? known
    }

    /// The bundle identifier of the application that opens https by default, or nil when none does.
    public static func defaultBundleID() -> String? {
        web.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
}
