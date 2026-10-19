//
//  WebWorldTests.swift
//  Braus
//

import CoreGraphics
import Foundation
import Testing
import WebDriver
@testable import WebDriving

/// The engine's page scripts on a synthetic page: they run in an isolated world made once per
/// document, never in the page's own world, and a world whose document went is made again.
@Suite("Web isolated world")
struct WebWorldTests {

    static func tab(_ page: SyntheticPage) async -> (WebTabs, pid_t) {
        let tabs = WebTabs()
        return (tabs, tabs.register(await page.page()))
    }

    @Test("Every engine read runs on the tab's world, made once for the document, never in the page's world")
    func readsRunInTheWorld() async throws {
        let synthetic = SyntheticPage { _ in ["result": ["type": "string", "value": "Ada"]] }
        let (tabs, id) = await Self.tab(synthetic)
        let controls   = WebControls(tabs: tabs)

        #expect(await controls.focusedFieldValue(in: id) == "Ada")
        #expect(await controls.toggleState(at: CGPoint(x: 10, y: 20), in: id) == nil)
        await WebSettler(tabs: tabs, interval: .milliseconds(1), quiet: .milliseconds(1))
            .settle(in: id, cap: .milliseconds(20))

        #expect(synthetic.methods("Page.createIsolatedWorld").count == 1)
        #expect(synthetic.methods("Page.createIsolatedWorld").first?["params"]?["worldName"] == "braus")
        // The only evaluation outside a call on the world fetches the world's own global object.
        #expect(synthetic.methods("Runtime.evaluate").map { $0["params"]?["expression"]?.stringValue } == ["globalThis"])
        #expect(synthetic.methods("Runtime.evaluate").allSatisfy { $0["params"]?["contextId"]?.intValue == 1 })
        let calls = synthetic.methods("Runtime.callFunctionOn")
        #expect(calls.count >= 3 && calls.allSatisfy { $0["params"]?["objectId"] == "world-1" })
        #expect(synthetic.ran.first?.contains("document.activeElement") == true)
        #expect(synthetic.ran.dropFirst().first?.contains("elementFromPoint(10.0, 20.0)") == true)
    }

    @Test("After a navigation the refused call is sent again once, in a world made for the new document")
    func navigationMakesANewWorld() async throws {
        let synthetic  = SyntheticPage()
        let (tabs, id) = await Self.tab(synthetic)

        #expect(try await tabs.evaluate("1", in: id) == "ok")
        synthetic.navigate()
        #expect(try await tabs.evaluate("2", in: id) == "ok")
        #expect(try await tabs.evaluate("3", in: id) == "ok")

        #expect(synthetic.methods("Page.createIsolatedWorld").count == 2)
        #expect(synthetic.methods("Runtime.callFunctionOn").map { $0["params"]?["objectId"]?.stringValue }
            == ["world-1", "world-1", "world-2", "world-2"])
        // The refused call never ran: each script ran exactly once.
        #expect(synthetic.ran.count == 3)
        #expect(synthetic.ran.map { $0.contains("\n2\n") } == [false, true, false])
    }

    @Test("A world whose document changed while it was made is released and made again")
    func documentChangingDuringCreation() async throws {
        // The second read of the frame tree, right after the first world's global was fetched, sees a new document.
        let synthetic  = SyntheticPage(navigatesAt: [2])
        let (tabs, id) = await Self.tab(synthetic)

        #expect(try await tabs.evaluate("1", in: id) == "ok")
        #expect(synthetic.methods("Page.createIsolatedWorld").count == 2)
        #expect(synthetic.methods("Runtime.releaseObject").map { $0["params"]?["objectId"] } == ["world-1"])
        #expect(synthetic.methods("Runtime.callFunctionOn").map { $0["params"]?["objectId"] } == ["world-2"])
    }

    @Test("A script that throws in the world is reported and never sent again")
    func throwingScript() async throws {
        let synthetic = SyntheticPage { _ in
            ["result": ["type": "object"], "exceptionDetails": ["text": "Uncaught", "exception": ["description": "boom"]]]
        }
        let (tabs, id) = await Self.tab(synthetic)

        await #expect(throws: CDPError.scriptFailed("boom")) { try await tabs.evaluate("x()", in: id) }
        #expect(synthetic.methods("Runtime.callFunctionOn").count == 1)
    }

    @Test("A script is wrapped as the body of a function the world calls on its global object")
    func wrapping() async throws {
        let synthetic  = SyntheticPage()
        let (tabs, id) = await Self.tab(synthetic)

        _ = try await tabs.evaluate("delete window.__brausSelect", in: id)
        let call = try #require(synthetic.methods("Runtime.callFunctionOn").first?["params"])
        #expect(call["functionDeclaration"] == "function () {\nreturn (\ndelete window.__brausSelect\n);\n}")
        #expect(call["returnByValue"] == true && call["awaitPromise"] == true)
    }
}
