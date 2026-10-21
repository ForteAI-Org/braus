//
//  WebPostCollectorTests.swift
//  Braus
//

import AutomationRuntime
import Foundation
import Testing
import WebDriver
@testable import WebSession

/// The collector over a scripted page: each read answers the next page state the test wrote, as the reader script
/// would; a fake clock moves only when the collector waits or reads. What is tested is what the collector does with
/// the reads (texts kept whole, posts counted once by identity, quotes apart, a virtual window of the same size with
/// new IDs, each stop and its reason, the session's checks before and after every await). The script itself runs
/// only in Chrome: `WebPostReaderLiveTests`, with `Fixtures/posts.html`.
@MainActor
@Suite("Collecting the posts of a page (web)")
struct WebPostCollectorTests {

    /// A page the test scripts: `states` answered in turn, the last one again once they run out.
    @MainActor
    final class Page {
        var states   : [JSONValue]
        var reads     = 0
        var scrolls   = 0
        var checks    = 0
        var clock     = ContinuousClock.now
        /// Called at each check; throws to stop the collection, as a session that changed would.
        var check: (Int) throws -> Void = { _ in }
        /// Called after each read answered, before the collector goes on.
        var afterRead: (Int) -> Void = { _ in }

        init(_ states: [JSONValue]) { self.states = states }

        func collector() -> WebPostCollector {
            WebPostCollector(
                read   : { [self] _ in
                    let state = states[min(reads, states.count - 1)]
                    reads += 1
                    clock += .milliseconds(100)
                    afterRead(reads)
                    return state
                },
                scroll : { [self] _ in scrolls += 1; clock += .milliseconds(200) },
                proceed: { [self] in checks += 1; try check(checks) },
                sleep  : { [self] duration in clock += duration },
                now    : { [self] in clock }
            )
        }
    }

    static func post(_ id: String, _ text: String = "", author: String = "Carla", quote: JSONValue? = nil,
                     truncated: Bool = false, length: Int? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "identity": .string("x:\(id)"), "source": "x", "author": .string(author), "handle": "@carla",
            "text": .string(text.isEmpty ? "post \(id)" : text), "url": .string("https://x.com/carla/status/\(id)"),
            "time": "2026-10-17T10:00:00.000Z", "truncated": .bool(truncated),
        ]
        if let length { object["textLength"] = .number(Double(length)) }
        if let quote { object["quote"] = quote }
        return .object(object)
    }

    static func state(_ posts: [JSONValue], site: String = "x", url: String = "https://x.com/home",
                      document: Double = 1, atEnd: Bool = false, limit: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["site": .string(site), "url": .string(url), "document": .number(document),
                                           "posts": .array(posts), "atEnd": .bool(atEnd), "viewport": 900]
        if let limit { object["limit"] = .string(limit) }
        return .object(object)
    }

    static func ids(_ range: ClosedRange<Int>) -> [JSONValue] { range.map { post(String($0)) } }

    @Test("a text longer than 80 characters is kept whole; one Braus cut says its full length")
    func longTexts() async throws {
        let long = String(repeating: "Una frase lunga che continua. ", count: 12)
        let page = Page([Self.state([Self.post("1", long), Self.post("2", String(long.prefix(40)), truncated: true,
                                                                          length: 20_000)])])
        let collected = try await page.collector().collect(PostCollectionRequest(target: 2))
        #expect(collected.posts.first?.text == long && long.count > 80)
        #expect(collected.posts.last?.truncated == true && collected.posts.last?.textLength == 20_000)
        #expect(collected.stop == .targetReached && page.scrolls == 0)
    }

    @Test("posts read again count once; a quote stays with its post, apart from its author and text")
    func dedupAndQuotes() async throws {
        let quote: JSONValue = ["author": "Dario", "handle": "@dario", "text": "quoted words", "textLength": 12,
                                "url": "https://x.com/dario/status/9"]
        let page = Page([Self.state([Self.post("1"), Self.post("2", "my comment", quote: quote)]),
                         Self.state([Self.post("2", "my comment", quote: quote), Self.post("3")])])
        let collected = try await page.collector().collect(PostCollectionRequest(target: 3))
        #expect(collected.posts.map(\.identity) == ["x:1", "x:2", "x:3"])
        let quoting = try #require(collected.posts.first { $0.identity == "x:2" })
        #expect(quoting.author == "Carla" && quoting.text == "my comment")
        #expect(quoting.quote?.author == "Dario" && quoting.quote?.text == "quoted words")
        #expect(collected.posts.map(\.round) == [0, 0, 1])
    }

    @Test("a virtual window of the same size with new IDs counts the new ones, up to the target")
    func virtualWindow() async throws {
        let page = Page([Self.state(Self.ids(1...10)), Self.state(Self.ids(7...16)), Self.state(Self.ids(13...22))])
        let collected = try await page.collector().collect(PostCollectionRequest(target: 20))
        #expect(collected.stop == .targetReached && collected.posts.count == 20)
        #expect(Set(collected.posts.map(\.identity)).count == 20)
        #expect(page.scrolls == 2)
    }

    @Test("scrolls that bring nothing new stop it as no progress, partial, after three of them")
    func noProgress() async throws {
        let page = Page([Self.state(Self.ids(1...5))])
        let collected = try await page.collector().collect(PostCollectionRequest(target: 50, maxScrolls: 30))
        #expect(collected.stop == .noProgress && collected.posts.count == 5 && collected.isPartial)
        #expect(page.scrolls == WebPostCollector.idleLimit)
        #expect(collected.reason.contains("5 of 50"))
    }

    @Test("the page's end, a read at its budget, the deadline and the scroll limit each stop it, with their reason")
    func otherStops() async throws {
        let end = Page([Self.state(Self.ids(1...5)), Self.state(Self.ids(1...5), atEnd: true)])
        #expect(try await end.collector().collect(PostCollectionRequest(target: 50)).stop == .endOfPage)
        #expect(end.scrolls == 1)
        let budget = Page([Self.state(Self.ids(1...5), limit: "posts")])
        #expect(try await budget.collector().collect(PostCollectionRequest(target: 50)).stop == .readLimit)
        let slow = Page([Self.state(Self.ids(1...2))] + (3...200).map { Self.state(Self.ids(1...$0)) })
        let late = try await slow.collector().collect(PostCollectionRequest(target: 200, maxScrolls: 100, seconds: 1))
        #expect(late.stop == .deadline && late.isPartial)
        let few = Page((1...20).map { Self.state(Self.ids(1...($0 * 2))) })
        let limited = try await few.collector().collect(PostCollectionRequest(target: 200, maxScrolls: 3))
        #expect(limited.stop == .maxScrolls && few.scrolls == 3 && limited.posts.count == 8)
    }

    @Test("a page with nothing it reads is unsupported at once: nothing scrolled, nothing invented")
    func unsupported() async throws {
        let page = Page([Self.state([], site: "none", url: "https://example.com/")])
        let collected = try await page.collector().collect(PostCollectionRequest(target: 50))
        #expect(collected.stop == .unsupported && collected.posts.isEmpty && page.scrolls == 0)
    }

    @Test("a revocation during the collection stops it before the next scroll; what was read before is kept")
    func revokedMidway() async throws {
        let page = Page([Self.state(Self.ids(1...5)), Self.state(Self.ids(1...10)), Self.state(Self.ids(1...15))])
        // The first check after the first scroll's read refuses, as a profile revoked meanwhile.
        var refused = false
        page.check = { count in if count >= 4 { refused = true; throw AutomationFailure("the profile was revoked") } }
        let collected = try await page.collector().collect(PostCollectionRequest(target: 50))
        #expect(refused && collected.stop == .interrupted)
        #expect(collected.posts.count == 5, "the read answered after the revocation is not kept")
        #expect(page.scrolls == 1, "no scroll after the revocation")
    }

    @Test("a first read that answers after the session changed is not kept: nothing of the new session is returned")
    func firstReadAfterChange() async throws {
        let page = Page([Self.state(Self.ids(1...5))])
        page.check = { _ in throw AutomationFailure("the web session changed or closed") }
        await #expect(throws: AutomationFailure.self) {
            _ = try await page.collector().collect(PostCollectionRequest(target: 50))
        }
        #expect(page.scrolls == 0)
    }

    @Test("a navigation to another page or document during the collection is not mixed in")
    func navigation() async throws {
        let page = Page([Self.state(Self.ids(1...5)),
                         Self.state(Self.ids(100...110), url: "https://x.com/dario"),
                         Self.state(Self.ids(200...210), document: 2)])
        let collected = try await page.collector().collect(PostCollectionRequest(target: 50))
        #expect(collected.stop == .interrupted && collected.reason.contains("https://x.com/dario"))
        #expect(collected.posts.map(\.identity) == (1...5).map { "x:\($0)" })
        let renewed = Page([Self.state(Self.ids(1...5)), Self.state(Self.ids(200...210), document: 2)])
        let again = try await renewed.collector().collect(PostCollectionRequest(target: 50))
        #expect(again.stop == .interrupted && again.posts.count == 5)
    }
}
