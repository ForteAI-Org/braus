//
//  WebBrowserLiveTests.swift
//  Braus
//

import Foundation
import Testing
import WebDriver

/// A real headless Chrome on a throwaway profile, driven through the pipe on the local fixture.
/// Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in `/Applications`. No network.
@Suite(
    "Web browser, live",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct WebBrowserLiveTests {

    static func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "web-fixture", withExtension: "html"))
    }

    static func throwawayProfile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "braus-web-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("Launch, load the fixture, act through script, close, and leave no Chrome behind")
    func roundTrip() async throws {
        let profile = Self.throwawayProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let browser = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile))
        #expect(browser.product.contains("Chrome"))

        let page = try await browser.openPage()
        try await page.navigate(to: try Self.fixtureURL().absoluteString)
        #expect(try await page.evaluate("document.title").stringValue == "Braus web fixture")

        _ = try await page.evaluate("document.getElementById('name').value = 'Ada'; document.getElementById('send').click()")
        #expect(try await page.evaluate("document.getElementById('status').textContent").stringValue == "Sent Ada")

        await #expect(throws: CDPError.self) { try await page.evaluate("throw new Error('boom')") }
        let pages = try await browser.pageTargets()
        #expect(pages.contains { $0.targetID == page.targetID && $0.title == "Braus web fixture" })

        await browser.close()
        #expect(await browser.isRunning() == false)
    }

    @Test("A navigation to an unreachable address throws Chrome's error text")
    func failedNavigation() async throws {
        let profile = Self.throwawayProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let browser = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile))
        let page = try await browser.openPage()
        await #expect(throws: CDPError.self) { try await page.navigate(to: "http://127.0.0.1:9/") }
        await browser.close()
    }
}
