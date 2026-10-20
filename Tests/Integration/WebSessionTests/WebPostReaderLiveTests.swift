//
//  WebPostReaderLiveTests.swift
//  Braus
//

import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory
import Router
import Testing
import WebDriver
@testable import WebSession

/// The post reader's script on a real headless Chrome, each test with a new temporary profile, over synthetic pages:
/// - `posts.html`, 30 articles, one with a text longer than 80 characters, each with a form value and a nested comment
///   that must not be read, and three articles the page hides (display, visibility, aria-hidden);
/// - `posts-x.html` and `posts-reddit.html`, read by the same script inside a wrapper that only declares a test
///   `location` (https://x.com/home, https://www.reddit.com/r/swift/): it checks the X and Reddit readers' selectors,
///   a quote by another author, long and hidden texts, a link and a date. It does not show that a live x.com or
///   reddit.com page routes to them, nor that their markup is still this one;
/// - `posts-virtual.html`, 50 articles of which 10 are in the document at a time, end to end: `open_session` and
///   `collect_posts` through `AutomationTools` and the router to a `WebAutomationSession`, whose scrolls are its own.
///
/// Opt in with `BRAUS_WEB_LIVE_TESTS=1`. Chrome is `/Applications/Google Chrome.app` unless `BRAUS_WEB_LIVE_CHROME`
/// names another executable, such as Chrome for Testing, which then also runs with `--use-mock-keychain`. With
/// `BRAUS_WEB_LIVE_CAPTURE` naming a folder, the end-to-end answer and transcript are written there. No network, no
/// personal profile. The browser is closed on every path and the profile removed.
@MainActor
@Suite(
    "The post reader on synthetic pages, live (web)",
    .serialized,
    .timeLimit(.minutes(3)),
    .enabled(if: ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_TESTS"] == "1")
)
struct WebPostReaderLiveTests {

    /// Headless Chrome on `profile`: `BRAUS_WEB_LIVE_CHROME`'s executable with `--use-mock-keychain` when it names one.
    static func options(profile: URL) -> ChromeLaunchOptions {
        var options = ChromeLaunchOptions(userDataDirectory: profile, isHeadless: true)
        if let chrome = ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_CHROME"], chrome.hasPrefix("/") {
            options.executableURL = URL(filePath: chrome)
            options.additionalArguments = ["--use-mock-keychain"]
        }
        return options
    }

    /// Runs `body` on `fixture` in a new headless Chrome with a temporary profile, closed and removed on every path.
    static func withPage(_ fixture: String, _ body: (WebPage) async throws -> Void) async throws {
        let profile = FileManager.default.temporaryDirectory
            .appending(path: "braus-web-posts-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: profile) }
        let browser = try await WebBrowser.launch(Self.options(profile: profile))
        do {
            let page = try await browser.openPage()
            let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "html"))
            try await page.navigate(to: url.absoluteString)
            try await body(page)
        } catch {
            await browser.close()
            throw error
        }
        await browser.close()
    }

    /// The production script, unchanged, run where `location` is `address`: only the test's location is declared.
    static func read(_ page: WebPage, as address: String) async throws -> WebPostCollector.Read {
        let wrapped = "(() => { const location = new URL(\"\(address)\"); return \(WebPostCollector.script); })()"
        return try WebPostCollector.parse(try await page.evaluate(wrapped, timeoutSeconds: 10), round: 0)
    }

    static func everything(_ read: WebPostCollector.Read) -> String {
        read.posts.map { post in
            [post.text, post.author ?? "", post.handle ?? "", post.context ?? "", post.quote?.text ?? ""]
                .joined(separator: " ")
        }.joined(separator: " ")
    }

    @Test("articles: every rendered one once, the long text whole, nothing hidden, nested or from a form")
    func articles() async throws {
        try await Self.withPage("posts") { page in
            let read = try WebPostCollector.parse(try await page.evaluate(WebPostCollector.script, timeoutSeconds: 10),
                                                  round: 0)
            #expect(read.site == "article" && read.limit == nil)
            #expect(read.posts.count == 30 && Set(read.posts.map(\.identity)).count == 30)
            let first = try #require(read.posts.first)
            #expect(first.text.contains("END-OF-LONG") && first.textLength > 80 && !first.truncated)
            #expect(first.author == "Author 1" && first.time == "2026-10-17T10:01:00Z")
            #expect(first.url?.hasSuffix("/posts/1") == true)
            #expect(!Self.everything(read).contains("SENTINEL"), "\(Self.everything(read).prefix(400))")
        }
    }

    @Test("X: the author, handle, link and date of the post, its quote apart, the long text whole, nothing hidden")
    func xPosts() async throws {
        try await Self.withPage("posts-x") { page in
            let read = try await Self.read(page, as: "https://x.com/home")
            #expect(read.site == "x" && read.posts.count == 2, "\(read.posts.map(\.identity))")
            let first = try #require(read.posts.first)
            #expect(first.identity == "x:1001" && first.url == "https://x.com/carla/status/1001")
            #expect(first.author == "Carla Rossi" && first.handle == "@carla" && first.context == "Dario reposted")
            #expect(first.time == "2026-10-17T09:00:00.000Z")
            #expect(first.text.contains("END-X-LONG") && first.text.contains("🙂") && first.textLength > 80)
            #expect(!first.text.contains("QUOTED"), "the quote's text is not the post's")
            #expect(first.quote?.author == "Dario Bianchi" && first.quote?.handle == "@dario")
            #expect(first.quote?.text == "QUOTED-TEXT by Dario" && first.quote?.url == "https://x.com/dario/status/900")
            let second = try #require(read.posts.last)
            #expect(second.url == "https://x.com/elena/status/1002" && second.shortenedBySite && second.quote == nil)
            #expect(!Self.everything(read).contains("SENTINEL"), "\(Self.everything(read).prefix(400))")
        }
    }

    @Test("Reddit: the post's link, author, date and subreddit, its title and body whole, no form value")
    func redditPost() async throws {
        try await Self.withPage("posts-reddit") { page in
            let read = try await Self.read(page, as: "https://www.reddit.com/r/swift/")
            #expect(read.site == "reddit" && read.posts.count == 1)
            let post = try #require(read.posts.first)
            #expect(post.identity == "reddit:t3_abc123" && post.author == "carla_dev" && post.handle == "u/carla_dev")
            #expect(post.url == "https://www.reddit.com/r/swift/comments/abc123/a_reddit_title/")
            #expect(post.time == "2026-10-17T08:00:00.000+0000" && post.context == "r/swift")
            #expect(post.text.hasPrefix("A Reddit title") && post.text.contains("END-REDDIT"))
            #expect(!Self.everything(read).contains("SENTINEL"))
        }
    }

    /// The lines a call's transcript wrote.
    final class Lines { var all: [String] = [] }

    @Test("a virtual feed of 50 keeping 10 in the document, end to end: open_session, then collect_posts, via the tools")
    func virtualFeedThroughTheTools() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "braus-web-posts-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        let knowledge = temporary.appending(path: "Knowledge", directoryHint: .isDirectory)
        let web = WebAutomationSession(knowledgeDirectory: knowledge,
                                       launchOptions: Self.options(profile: temporary.appending(path: "profile")),
                                       allowsLocalFiles: true)
        do {
            try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
            let tools = AutomationTools(session: RoutingAutomationSession(desktop: DesktopProbe(), web: web),
                                        channels: [.web])
            tools.producer = CallProducer(source: .app, streamID: "web-posts", traceID: "message-1",
                                          messageRef: "message-1")
            let lines = Lines()
            tools.record = { lines.all.append($0) }
            let fixture = try #require(Bundle.module.url(forResource: "posts-virtual", withExtension: "html"))
            _ = try await tools.call("open_session", .object(["app": .string(fixture.absoluteString)]))
            let session = try #require(web.id?.uuidString)
            let result = try await tools.call("collect_posts", .object([
                "session": .string(session), "target": .number(50), "max_scrolls": .number(60), "seconds": .number(120),
            ]))
            let answer = WebEntryModesLiveTests.payload(result)
            if let folder = ProcessInfo.processInfo.environment["BRAUS_WEB_LIVE_CAPTURE"], folder.hasPrefix("/") {
                let capture = URL(filePath: folder, directoryHint: .isDirectory)
                try Data(WebEntryModesLiveTests.text(answer).utf8)
                    .write(to: capture.appending(path: "collect_posts-virtual.json"))
                try Data(lines.all.joined(separator: "\n").utf8)
                    .write(to: capture.appending(path: "collect_posts-virtual-transcript.txt"))
            }
            let posts = answer["posts"].array ?? []
            let urls = posts.compactMap { $0["url"].string }
            #expect(answer["stop"].string == "target_reached", "\(answer["reason"].string ?? "\(answer)")")
            #expect(answer["count"] == .number(50) && answer["partial"] == .bool(false))
            #expect(posts.count == 50 && Set(posts.compactMap { $0["id"].string }).count == 50)
            #expect(urls.first?.hasSuffix("/posts/1") == true && urls.last?.hasSuffix("/posts/50") == true)
            if case .number(let scrolls) = answer["scrolls"] { #expect(scrolls > 0, "the feed was scrolled") }
            #expect(lines.all.contains { $0.contains("collect_posts") }, "the call is in the transcript")
        } catch {
            await web.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        await web.close()
        try? FileManager.default.removeItem(at: temporary)
    }
}
