//
//  WebBrowserLiveTests.swift
//  Braus
//

import Foundation
import Testing
import WebDriver

/// A real headless Chrome on a throwaway profile, driven through the pipe on the local fixture. Each browser is
/// closed on success and on a throw, and is not running afterwards (W14); a profile is a throwaway one, removed at the
/// end, never the person's (W13). Opt in with `BRAUS_WEB_LIVE_TESTS=1`; needs Google Chrome in `/Applications`. No
/// network.
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

    /// Runs `body` on a new Chrome on a throwaway profile, removed afterwards: the browser is closed on success and on
    /// a throw, and is not running afterwards.
    static func withBrowser(_ body: (WebBrowser, URL) async throws -> Void) async throws {
        let profile = Self.throwawayProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let browser = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile))
        do {
            try await body(browser, profile)
        } catch {
            await browser.close()
            throw error
        }
        await browser.close()
        #expect(await browser.isRunning() == false)
    }

    @Test("Launch, load the fixture, act through script, close, and leave no Chrome behind")
    func roundTrip() async throws {
        try await Self.withBrowser { browser, _ in
            #expect(browser.product.contains("Chrome"))
            let page = try await browser.openPage()
            try await page.navigate(to: try Self.fixtureURL().absoluteString)
            #expect(try await page.evaluate("document.title").stringValue == "Braus web fixture")

            _ = try await page.evaluate("document.getElementById('name').value = 'Ada'; document.getElementById('send').click()")
            #expect(try await page.evaluate("document.getElementById('status').textContent").stringValue == "Sent Ada")

            await #expect(throws: CDPError.self) { try await page.evaluate("throw new Error('boom')") }
            let pages = try await browser.pageTargets()
            #expect(pages.contains { $0.targetID == page.targetID && $0.title == "Braus web fixture" })
        }
    }

    @Test("A navigation to an unreachable address throws Chrome's error text")
    func failedNavigation() async throws {
        try await Self.withBrowser { browser, _ in
            let page = try await browser.openPage()
            await #expect(throws: CDPError.self) { try await page.navigate(to: "http://127.0.0.1:9/") }
        }
    }

    @Test("W14: a call still waiting when the browser closes fails at once, and no Chrome is left")
    func pendingCallDuringClose() async throws {
        try await Self.withBrowser { browser, _ in
            let page = try await browser.openPage()
            let waiting = Task { try await page.evaluate("new Promise(() => {})") }
            try await Task.sleep(for: .milliseconds(200))
            let started = ContinuousClock.now
            await browser.close()
            await #expect(throws: CDPError.self) { _ = try await waiting.value }
            #expect(ContinuousClock.now - started < .seconds(6), "the close and the failed call took the grace at most")
            #expect(await browser.isRunning() == false)
        }
    }

    @Test("W14: a profile closed is reopened by a new browser")
    func reopensAfterClose() async throws {
        let profile = Self.throwawayProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        for round in 1...2 {
            let browser = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile))
            do {
                let page = try await browser.openPage()
                #expect(try await page.evaluate("1 + \(round)").intValue == 1 + round)
            } catch {
                await browser.close()
                throw error
            }
            await browser.close()
            #expect(await browser.isRunning() == false)
        }
    }

    @Test("W13: a stale lock, left by a process of this host that is gone, does not stop a launch, and nothing of the profile is deleted")
    func staleLock() async throws {
        let profile = Self.throwawayProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let kept = profile.appending(path: "kept.txt")
        try Data("kept".utf8).write(to: kept)
        // The lock a crash leaves: a link to this host and a process id that no process holds any more.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        var host = [CChar](repeating: 0, count: 256)
        gethostname(&host, host.count)
        let hostName = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        try FileManager.default.createSymbolicLink(atPath: profile.appending(path: "SingletonLock").path,
                                                   withDestinationPath: "\(hostName)-\(gone.processIdentifier)")
        let browser = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile))
        do {
            let page = try await browser.openPage()
            #expect(try await page.evaluate("2 + 2").intValue == 4)
        } catch {
            await browser.close()
            throw error
        }
        await browser.close()
        #expect(FileManager.default.fileExists(atPath: kept.path), "the profile's own files are kept")
    }

    @Test("W13: a profile another test browser holds refuses a second launch, cleanly, and the first one keeps answering")
    func liveLock() async throws {
        try await Self.withBrowser { first, profile in
            let page = try await first.openPage()
            await #expect(throws: CDPError.self) {
                let second = try await WebBrowser.launch(ChromeLaunchOptions(userDataDirectory: profile), readySeconds: 5)
                await second.close()
            }
            #expect(try await page.evaluate("3 + 3").intValue == 6)
        }
    }
}
