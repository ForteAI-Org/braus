import AutomationMCP
import AutomationRuntime
import ChatCore
import Foundation
import LocalMCP
import Memory
import Router
import SeatBroker
import Testing
import WebDriver
import WebSession
@testable import braus

/// P10: `braus chat` composes the routes `--channels` names beyond the Seat, as the app's workers do, and no other.
/// `web` is the chat's own headless Chrome on a profile under its history folder: the person's own Chrome and a paired
/// consent asks about is refused, since the chat has no one to ask, and that closes the chat's other actions.
///
/// Offline: the real `ChatSession` on temporary folders, never started; no Chrome is launched (the refusals come before
/// (`ChatWebSmokeTests`).
@MainActor
@Suite("P10: the chat composes the web routes it is asked for, and refuses the rest")
struct ChatChannelsTests {

    /// A chat on temporary folders with `arguments`, removed by `end`.
    final class Chat {
        let root = URL.temporaryDirectory.appending(path: "braus-chat-channels-\(UUID().uuidString)",
                                                    directoryHint: .isDirectory)
        let history: URL
        let session: ChatSession

        init(_ arguments: [String]) throws {
            let knowledge = root.appending(path: "Knowledge", directoryHint: .isDirectory)
            history = root.appending(path: "History", directoryHint: .isDirectory)
            for directory in [knowledge, history] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let options = try ChatOptions(arguments: ["--knowledge", knowledge.path(percentEncoded: false),
                                                      "--history-dir", history.path(percentEncoded: false)]
                                                     + arguments)
            session = try ChatSession(options: options, history: history, executable: URL(filePath: "/usr/bin/false"))
        }

        var support: URL { root.appending(path: "Support", directoryHint: .isDirectory) }

        func end() async {
            await session.finish()
            session.stop()
            await MemoryService.closeAll()
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func text(_ result: LocalMCP.JSONValue) -> String { result["content"].array?.first?["text"].string ?? "" }

    @Test("--chrome goes with --channels web, by absolute path")
    func chromeNeedsTheWebChannel() {
        #expect(throws: (any Error).self) { try ChatOptions(arguments: ["--chrome", "/tmp/chrome"]) }
        #expect(throws: (any Error).self) { try ChatOptions(arguments: ["--channels", "web", "--chrome", "chrome"]) }
        #expect((try? ChatOptions(arguments: ["--channels", "web", "--chrome", "/tmp/chrome"]))?.chromeExecutable
                == "/tmp/chrome")
    }

    @Test("without --channels, the Seat alone")
    func nothingByDefault() async throws {
        let chat = try Chat([])
        #expect(chat.session.web == nil)
        #expect(!(chat.session.tools.session is RoutingAutomationSession))
        await chat.end()
    }

    @Test("web: the chat's own headless Chrome on a profile under its history folder, the route for addresses")
    func webIsTheChatsOwnChrome() async throws {
        let chat = try Chat(["--channels", "web", "--chrome", "/tmp/braus-test-chrome"])
        let web = try #require(chat.session.web)
        let routing = try #require(chat.session.tools.session as? RoutingAutomationSession)
        #expect(routing.web === web && routing.native == nil)
        #expect(web.launchOptions.userDataDirectory.standardizedFileURL
                == chat.history.appending(path: "Chrome", directoryHint: .isDirectory).standardizedFileURL)
        #expect(web.launchOptions.isHeadless)
        #expect(web.launchOptions.executableURL.path == "/tmp/braus-test-chrome")
        #expect(web.launchOptions.additionalArguments.isEmpty, "no flag weakens the profile's keychain")
        #expect(!web.usesPersonalChrome && web.chromeProfile == nil)
        await chat.end()
    }

    @Test("web: the person's own Chrome and a paired profile are refused, with nothing opened", arguments: ["personal", "profile"])
    func personalChromeAndProfilesAreRefused(_ mode: String) async throws {
        let chat = try Chat(["--channels", "web", "--chrome", "/tmp/braus-test-chrome-absent"])
        let web = try #require(chat.session.web)
        if mode == "personal" { web.usesPersonalChrome = true }
        else { web.chromeProfile = ChromeProfileChoice(instanceID: "p1", label: "Work") }
        await #expect(throws: (any Error).self) {
            _ = try await chat.session.tools.call("open_session", .object(["app": .string("http://127.0.0.1:9/")]))
        }
        #expect(web.id == nil, "nothing opened")
        await chat.end()
    }

}
