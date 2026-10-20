//
//  PersonalChromeSessionTests.swift
//  Braus
//

import AutomationRuntime
import Foundation
import Synchronization
import Testing
@testable import WebDriver
import WebSession

/// A web session the person pointed at their own Chrome (Use My Chrome): what the agent reads when that Chrome cannot
/// be reached, and when a page fails in it, and that the session then leaves the person's Chrome as it found it,
/// closing only its own tab. A scripted Chrome stands in for theirs; no Chrome runs, Braus's included.
@MainActor
@Suite("A web session on the person's own Chrome")
struct PersonalChromeSessionTests {

    /// ScriptedChrome is the person's Chrome inside the process: it answers what a session's first open sends, fails
    /// the navigation with `net::ERR_NAME_NOT_RESOLVED`, and records every method it receives.
    final class ScriptedChrome: CDPTransporting {
        let incoming: AsyncStream<Data>
        private let feed : AsyncStream<Data>.Continuation
        private let state = Mutex<(methods: [String], isClosed: Bool)>(([], false))

        init() { (incoming, feed) = AsyncStream<Data>.makeStream() }

        var methods: [String] { state.withLock { $0.methods } }

        func send(_ message: Data) throws {
            let command = try JSONDecoder().decode(JSONValue.self, from: message)
            let method  = command["method"]?.stringValue ?? ""
            let isClosed = state.withLock { state in
                if !state.isClosed { state.methods.append(method) }
                return state.isClosed
            }
            if isClosed { throw CDPError.connectionClosed(method: method) }
            let result: JSONValue
            switch method {
                case "Browser.getVersion"   : result = ["product": "ScriptedChrome/1"]
                case "Target.createTarget"  : result = ["targetId": "braus-tab"]
                case "Target.attachToTarget": result = ["sessionId": "braus-session"]
                case "Page.enable"          : result = [:]
                case "Page.navigate"        : result = ["frameId": "main", "errorText": "net::ERR_NAME_NOT_RESOLVED"]
                case "Target.closeTarget"   : result = ["success": true]
                default                     : result = [:]
            }
            var framed = try JSONEncoder().encode(JSONValue.object(["id": command["id"] ?? .null, "result": result]))
            framed.append(0)
            feed.yield(framed)
        }

        func close() {
            state.withLock { $0.isClosed = true }
            feed.finish()
        }
    }

    /// Counts the connections a session asked for.
    final class Connections: Sendable {
        private let made = Mutex(0)
        var count: Int { made.withLock { $0 } }
        func attempt(_ connect: () throws -> WebBrowser) rethrows -> WebBrowser {
            made.withLock { $0 += 1 }
            return try connect()
        }
    }

    /// A session whose Braus's Chrome cannot start (its executable does not exist), so a launch shows as its own
    /// failure, and whose person's Chrome is `connect`.
    static func session(connect: @escaping @Sendable () async throws -> WebBrowser) throws -> WebAutomationSession {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "braus-personal-session-\(UUID().uuidString)", directoryHint: .isDirectory)
        let knowledge = temporary.appending(path: "Knowledge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        let options = ChromeLaunchOptions(executableURL: temporary.appending(path: "no-chrome"),
                                          userDataDirectory: temporary.appending(path: "chrome-web"))
        return WebAutomationSession(knowledgeDirectory: knowledge, launchOptions: options,
                                    connectPersonalChrome: connect)
    }

    @Test("off by default: the session never reaches for the person's Chrome")
    func offByDefault() async throws {
        let connections = Connections()
        let session = try Self.session { try connections.attempt { throw PersonalChromeError.refused } }
        #expect(!session.usesPersonalChrome)
        await #expect(throws: (any Error).self) { try await session.open(application: "web:x.com", window: nil) }
        #expect(connections.count == 0)
        #expect(session.id == nil && session.browserNotice == nil)
    }

    @Test("a person's Chrome that cannot be reached: the reason, what the person does, nothing opened, nowhere else",
          arguments: [
            (PersonalChromeError.remoteDebuggingOff, "chrome://inspect/#remote-debugging and turn remote debugging on"),
            (.unreachable, "it quit or turned remote debugging off"),
            (.refused, "the person did not allow it"),
            (.notAllowedInTime(seconds: 60), "did not answer within 60 s"),
          ])
    func unreachedChrome(error: PersonalChromeError, reason: String) async throws {
        let connections = Connections()
        let session = try Self.session { try connections.attempt { throw error } }
        session.usesPersonalChrome = true
        do {
            _ = try await session.open(application: "web:x.com", window: nil)
            Issue.record("opened with \(error)")
        } catch let failure as AutomationFailure {
            let text = failure.description
            for part in [reason, "Braus could not use the person's own Chrome", "No page was opened",
                         "turn off Use My Chrome", "Do not move to another browser or the desktop without asking"] {
                #expect(text.contains(part), "\(part): \(text)")
            }
            #expect(!text.contains("no-chrome"), "Braus's own Chrome was not launched: \(text)")
        }
        #expect(connections.count == 1)
        #expect(session.id == nil && session.browserNotice == nil)
    }

    @Test("a page that fails in the person's Chrome: named as theirs, and only the tab Braus opened is closed")
    func failedPageClosesOnlyItsTab() async throws {
        let chrome  = ScriptedChrome()
        let session = try Self.session { try await WebBrowser.attached(over: chrome, readySeconds: 5) }
        session.usesPersonalChrome = true
        do {
            _ = try await session.open(application: "https://x.com/home?token=Sentinel-Q", window: nil)
            Issue.record("the page opened")
        } catch let failure as AutomationFailure {
            let text = failure.description
            for part in ["https://x.com answered net::ERR_NAME_NOT_RESOLVED",
                         "the person's own Chrome, in a window Braus opened, signed in as them",
                         "the person signs in themselves in that window",
                         "Braus closed the tab it opened in the person's Chrome: no page is open in this session.",
                         "do not move to another browser or the desktop without asking them"] {
                #expect(text.contains(part), "\(part): \(text)")
            }
            for absent in ["Braus's own profile", "Show Chrome Window", "Braus closed its Chrome", "Sentinel"] {
                #expect(!text.contains(absent), "\(absent): \(text)")
            }
        }
        #expect(chrome.methods.first == "Browser.getVersion")
        #expect(chrome.methods.last == "Target.closeTarget")
        #expect(!chrome.methods.contains("Browser.close"), "the person's Chrome is never asked to quit")
        #expect(session.id == nil && session.browserNotice == nil)
    }

    @Test("the notice an agent reads in the person's Chrome names their sign-ins and what to ask first")
    func notice() {
        let notice = WebAutomationSession.personalChromeNotice
        for part in ["the person's own Chrome", "signed in as them", "act only in this tab",
                     "ask the person before anything that posts, sends, buys, deletes or changes their accounts"] {
            #expect(notice.contains(part), "\(part)")
        }
    }
}
