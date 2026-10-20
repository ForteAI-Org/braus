//
//  PersonalChromeTests.swift
//  Braus
//

import Foundation
import Testing
@testable import WebDriver

/// The person's own Chrome reached over its DevTools WebSocket, with a fake Chrome on 127.0.0.1 in its place: the
/// endpoint read from `DevToolsActivePort`, a connection that answers, waits or is refused, messages larger than
/// `URLSessionWebSocketTask`'s default, and a close that leaves Chrome and the person's tabs alone. No Chrome runs.
@Suite("The person's own Chrome")
struct PersonalChromeTests {

    /// A user data directory holding only a `DevToolsActivePort` with `contents`, or none when nil.
    static func userDataDirectory(_ contents: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "braus-personal-chrome-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let contents {
            try contents.write(to: directory.appending(path: "DevToolsActivePort"), atomically: true, encoding: .utf8)
        }
        return directory
    }

    // MARK: The endpoint

    @Test("a DevToolsActivePort names a loopback WebSocket by its port and path")
    func endpointParsing() {
        #expect(PersonalChrome.endpoint(parsing: "9222\n/devtools/browser/a1-b2\n")?.absoluteString
                == "ws://127.0.0.1:9222/devtools/browser/a1-b2")
        #expect(PersonalChrome.endpoint(parsing: "50123\r\n/devtools/browser/x")?.absoluteString
                == "ws://127.0.0.1:50123/devtools/browser/x")
        for malformed in ["", "9222", "9222\n", "port\n/devtools/browser/x", "0\n/devtools/browser/x",
                          "65536\n/devtools/browser/x", "9222\ndevtools/browser/x", "9222\n/devtools/browser x",
                          "-1\n/devtools/browser/x"] {
            #expect(PersonalChrome.endpoint(parsing: malformed) == nil, "\(malformed.debugDescription)")
        }
    }

    @Test("with no DevToolsActivePort, or one that names nothing, remote debugging is off")
    func endpointFile() throws {
        #expect(throws: PersonalChromeError.remoteDebuggingOff) {
            try PersonalChrome.endpoint(in: Self.userDataDirectory(nil))
        }
        #expect(throws: PersonalChromeError.remoteDebuggingOff) {
            try PersonalChrome.endpoint(in: Self.userDataDirectory("not a port"))
        }
        let named = try PersonalChrome.endpoint(in: Self.userDataDirectory("41000\n/devtools/browser/k\n"))
        #expect(named.absoluteString == "ws://127.0.0.1:41000/devtools/browser/k")
    }

    // MARK: Connecting

    @Test("a Chrome that answers is attached: its tab opens in a new background window and is the only one closed")
    func attachedClosesOnlyItsTab() async throws {
        let chrome  = try await FakeChromeServer(.answers)
        defer { chrome.stop() }
        let browser = try await PersonalChrome.connect(userDataDirectory: Self.userDataDirectory(chrome.activePort),
                                                       readySeconds: 10)
        #expect(browser.product == "FakeChrome/1")
        #expect(!browser.ownsChrome)
        #expect(await browser.isRunning())

        let page = try await browser.openPage()
        #expect(page.targetID == FakeChromeServer.openedTarget)
        await browser.close()

        #expect(chrome.methods == ["Browser.getVersion", "Target.createTarget", "Target.attachToTarget",
                                   "Target.closeTarget"])
        let created = try #require(chrome.received.first { $0["method"]?.stringValue == "Target.createTarget" })
        #expect(created["params"]?["newWindow"] == true && created["params"]?["background"] == true)
        let closed = try #require(chrome.received.last)
        #expect(closed["params"]?["targetId"]?.stringValue == FakeChromeServer.openedTarget)
        #expect(!chrome.methods.contains("Browser.close"), "the person's Chrome is never asked to quit")
        #expect(!(await browser.isRunning()))

        await browser.close()
        #expect(chrome.methods.filter { $0 == "Target.closeTarget" }.count == 1, "a second close closes nothing")
    }

    @Test("an answer larger than the WebSocket default arrives whole")
    func largeAnswer() async throws {
        let chrome  = try await FakeChromeServer(.answers)
        defer { chrome.stop() }
        let browser = try await PersonalChrome.connect(userDataDirectory: Self.userDataDirectory(chrome.activePort),
                                                       readySeconds: 10)
        let answer = try await browser.connection.send("Fake.big", timeoutSeconds: 10)
        #expect(answer["blob"]?.stringValue?.utf8.count == FakeChromeServer.bigByteCount)
        await browser.close()
    }

    @Test("nothing listening where the port says is unreachable")
    func unreachable() async throws {
        let port = try await FakeChromeServer.closedPort()
        let directory = try Self.userDataDirectory("\(port)\n/devtools/browser/gone\n")
        await #expect(throws: PersonalChromeError.unreachable) {
            try await PersonalChrome.connect(userDataDirectory: directory, readySeconds: 10)
        }
    }

    @Test("a Chrome that does not answer in time has not been allowed yet")
    func notAllowedInTime() async throws {
        let chrome = try await FakeChromeServer(.silent)
        defer { chrome.stop() }
        let directory = try Self.userDataDirectory(chrome.activePort)
        await #expect(throws: PersonalChromeError.notAllowedInTime(seconds: 0.5)) {
            try await PersonalChrome.connect(userDataDirectory: directory, readySeconds: 0.5)
        }
    }

    @Test("a Chrome that closes the connection before answering refused it")
    func refused() async throws {
        let chrome = try await FakeChromeServer(.closesOnFirstCommand)
        defer { chrome.stop() }
        let directory = try Self.userDataDirectory(chrome.activePort)
        await #expect(throws: PersonalChromeError.refused) {
            try await PersonalChrome.connect(userDataDirectory: directory, readySeconds: 10)
        }
    }
}
