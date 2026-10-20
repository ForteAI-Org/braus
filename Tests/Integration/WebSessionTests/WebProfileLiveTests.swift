//
//  WebProfileLiveTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Router
import Testing
import WebDriver
import WebSession

/// Braus's own Chrome profile on a real headless Chrome and the local shop server (`ShopFixtureServer`, 127.0.0.1),
/// with a new temporary profile folder, never Braus's or the person's:
/// - what a site stores in one launch, a persistent cookie and a `localStorage` value, is there in the next launch on
///   the same profile folder: the server reads the cookie the browser sends and the value the page reports, not
///   Braus's perception;
/// - a page answering 403 with an empty body gives the agent the diagnostic failure, closes Chrome, and leaves the
///   profile free for the next open.
///
/// Opt in with `BRAUS_WEB_LIVE_TESTS=1`. Chrome is `/Applications/Google Chrome.app` unless `BRAUS_WEB_LIVE_CHROME`
/// names an executable (Chrome for Testing, run with `--use-mock-keychain`). On every path, a thrown error or a
/// cancellation included, each session made is closed (its Chrome ends by its own process group, W14) and the server
/// is stopped, both before the folder is removed; the error that ended the test is the one it throws. Every wait has
/// a deadline.
@MainActor
@Suite(
    "Braus's Chrome profile, live (persistence and a refused page)",
    .serialized,
    .timeLimit(.minutes(3)),
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct WebProfileLiveTests {

    typealias Value = LocalMCP.JSONValue

    nonisolated static let patience: Duration = .seconds(15)

    static func eventually(_ condition: () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + patience
        while !(await condition()) {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Headless Chrome on the folder's `profile`: `BRAUS_WEB_LIVE_CHROME`'s executable with `--use-mock-keychain` when
    /// it names one (as `WebPostReaderLiveTests` does), else the Chrome in `/Applications`.
    static func options(_ folder: URL) -> ChromeLaunchOptions {
        var options = ChromeLaunchOptions(userDataDirectory: folder.appending(path: "profile"))
        if let chrome = ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_CHROME"], chrome.hasPrefix("/") {
            options.executableURL = URL(filePath: chrome)
            options.additionalArguments = ["--use-mock-keychain"]
        }
        return options
    }

    static func session(_ folder: URL) -> WebAutomationSession {
        WebAutomationSession(knowledgeDirectory: folder.appending(path: "Knowledge", directoryHint: .isDirectory),
                             launchOptions: options(folder))
    }

    /// A new temporary folder with its `Knowledge` directory; what a failed creation made is removed before it throws.
    static func folder(_ name: String) throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "braus-web-profile-\(name)-\(UUID().uuidString)",
                                                      directoryHint: .isDirectory)
        do {
            let knowledge = folder.appending(path: "Knowledge", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// Opens `address` in `web`, closing it when the open throws.
    static func open(_ address: String, in web: WebAutomationSession) async throws {
        do { _ = try await web.open(application: address, window: nil) } catch {
            await web.close()
            throw error
        }
    }

    @Test("a persistent cookie and a localStorage value stored in one launch are sent and read in the next launch on the same profile folder")
    func storageSurvivesARelaunch() async throws {
        // The folder first: its removal, at the end, comes after every session is closed and the server stopped.
        let folder = try Self.folder("persist")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try await ShopFixtureServer.start()
        // Both sessions made before anything can throw, so the catch closes whichever opened (a close is idempotent).
        let first  = Self.session(folder)
        let second = Self.session(folder)
        do {
            // Launch 1: the site stores both; the session ends as a person closes the browser.
            try await Self.open(server.url.absoluteString + "remember", in: first)
            await first.close()
            #expect(first.id == nil)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "profile").path),
                    "the profile folder is kept after the close")
            let firstCookie = await server.cookies["/remember"]
            #expect(firstCookie == "", "the first launch had no cookie of the site yet: \(firstCookie ?? "none")")

            // Launch 2: a new session on the same folder; the page reports what it finds.
            try await Self.open(server.url.absoluteString + "check", in: second)
            let reported = try await Self.eventually { await server.targets.contains { $0.hasPrefix("/report") } }
            await second.close()
            let targets = await server.targets
            try #require(reported, "the check page reported nothing: \(targets)")
            let cookie = await server.cookies["/check"] ?? ""
            #expect(cookie.contains("braus_fixture=kept"), "the cookie sent after the relaunch: '\(cookie)'")
            #expect(targets.contains("/report?local=kept"), "\(targets)")
        } catch {
            await second.close()
            await first.close()
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test("a page answering 403 with an empty body: the agent reads the diagnostic, Chrome is closed, the profile is free for the next open")
    func refusedPageIsDiagnosed() async throws {
        // The folder first: its removal, at the end, comes after the session is closed and the server stopped.
        let folder = try Self.folder("refused")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = try await ShopFixtureServer.start()
        let web = Self.session(folder)
        let tools = AutomationTools(session: RoutingAutomationSession(desktop: DesktopProbe(), web: web),
                                    channels: [.web])
        let arguments: (String) -> Value = { path in
            .object(["app": .string(server.url.absoluteString + path)])
        }
        do {
            var message = ""
            do {
                let result = try await tools.call("open_session", arguments("refused?token=Sentinel-Query-R4"))
                let text = result["content"].array?.first?["text"].string ?? ""
                message = (try? JSONDecoder().decode(Value.self, from: Data(text.utf8)))?["message"].string ?? text
                #expect(result["isError"].bool == true, "a refused page was answered: \(result)")
            } catch {
                message = String(describing: error)
            }
            print("refused:", "\(message)")
            let origin = "http://127.0.0.1:\(server.port)"
            #expect(message.contains("\(origin) answered net::ERR_HTTP_RESPONSE_CODE_FAILURE"), "\(message)")
            #expect(message.contains("with no window (headless)") && message.contains("Show Chrome Window"),
                    "\(message)")
            #expect(message.contains("Braus closed its Chrome: no page is open in this session."), "\(message)")
            #expect(message.contains("without asking them"), "\(message)")
            #expect(!message.contains("Sentinel") && !message.contains("/refused"), "\(message)")
            #expect(web.id == nil, "Chrome stayed open after the refused first open")

            // The profile is free: the next open launches Chrome again on it.
            let opened = try await tools.call("open_session", arguments(""))
            #expect(opened["isError"].bool != true, "\(opened)")
            #expect(web.id != nil)
        } catch {
            await web.close()
            await server.stop()
            throw error
        }
        await web.close()
        await server.stop()
    }
}
