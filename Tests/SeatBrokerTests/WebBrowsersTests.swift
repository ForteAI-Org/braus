//
//  WebBrowsersTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import Testing
@testable import AutomationRuntime

/// kitty and Codex register for https and were taken for browsers; the decision is tested apart from Launch Services.
@MainActor
@Suite("Which applications are browsers")
struct WebBrowsersTests {

    @Test("kitty and Codex are not browsers while another application is the default")
    func registeredButNotBrowsers() {
        let browsers = WebBrowsers.bundleIDs(defaultID: "com.apple.Safari")
        #expect(!browsers.contains("net.kovidgoyal.kitty"))
        #expect(!browsers.contains("com.openai.codex"))
    }

    @Test("Safari and Chrome are browsers without being the default")
    func knownBrowsers() {
        let browsers = WebBrowsers.bundleIDs(defaultID: nil)
        #expect(browsers.contains("com.apple.Safari"))
        #expect(browsers.contains("com.google.Chrome"))
    }

    @Test("The default is a browser even when it is not a known one")
    func defaultCounts() {
        #expect(WebBrowsers.bundleIDs(defaultID: "org.example.Unknown").contains("org.example.Unknown"))
    }

    @Test("The live set leaves kitty out unless the person made it the default")
    func liveSetWithoutKitty() {
        #expect(!WebBrowsers.bundleIDs().contains("net.kovidgoyal.kitty")
            || WebBrowsers.defaultBundleID() == "net.kovidgoyal.kitty")
    }
}
