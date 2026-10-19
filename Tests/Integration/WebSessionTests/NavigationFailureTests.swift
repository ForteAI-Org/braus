//
//  NavigationFailureTests.swift
//  Braus
//

import AutomationRuntime
import Foundation
import Testing
import WebDriver
import WebSession

/// What an agent reads when a page does not load in Braus's own Chrome: the address's origin and nothing else of it,
/// Chrome's error and its meaning, the browser that ran, the way out (with no window: the person shows it and signs
/// in themselves), what is left (Chrome closed, or a tab to observe), and never a move elsewhere without asking.
/// No Chrome runs here.
@Suite("A page that does not load in Braus's Chrome")
struct NavigationFailureTests {

    /// An address whose credentials, path, query and fragment each carry a sentinel no failure may repeat.
    static let address = "https://reader:Sentinel-Pass-K2@x.com/home/Sentinel-Path-K2?token=Sentinel-Query-K2"
        + "#Sentinel-Frag-K2"

    static func failure(_ error: any Error, showsWindow: Bool, closed: Bool, address: String = address) -> String? {
        WebAutomationSession.navigationFailure(address: address, error: error, showsWindow: showsWindow,
                                               closed: closed)?.description
    }

    @Test("headless, first open: the origin only, Chrome's error and its meaning, the window to show, Chrome closed, nowhere else without asking")
    func headlessFirstOpen() throws {
        let error = CDPError.protocolError(method: "Page.navigate", code: 0,
                                           message: "net::ERR_HTTP_RESPONSE_CODE_FAILURE")
        let text = try #require(Self.failure(error, showsWindow: false, closed: true))
        for part in ["https://x.com answered net::ERR_HTTP_RESPONSE_CODE_FAILURE",
                     "the site answered with an HTTP error and an empty page",
                     "Braus's own Chrome, with no window (headless), on Braus's own profile",
                     "turn on Show Chrome Window", "signs in themselves",
                     "Braus closed its Chrome: no page is open in this session.",
                     "do not move to their own browser or the desktop without asking them"] {
            #expect(text.contains(part), "\(part): \(text)")
        }
        for secret in ["Sentinel", "K2", "reader", "/home", "token"] {
            #expect(!text.contains(secret), "\(secret) leaked: \(text)")
        }
    }

    @Test("with its window, a page already open: the way out is the person's sign-in there, and the tab must be observed")
    func windowAlreadyOpen() throws {
        let error = CDPError.protocolError(method: "Page.navigate", code: 0, message: "net::ERR_SOMETHING_NEW")
        let text = try #require(Self.failure(error, showsWindow: true, closed: false))
        #expect(text.contains("https://x.com answered net::ERR_SOMETHING_NEW in Braus's own Chrome, in its window"),
                "an unknown error is given as Chrome wrote it, with no meaning made up: \(text)")
        #expect(text.contains("the person signs in themselves in that window"), "\(text)")
        let observe = "The tab may show Chrome's error page or another document: observe before deciding."
        #expect(text.contains(observe), "\(text)")
        #expect(!text.contains("Show Chrome Window") && !text.contains("no page is open"), "\(text)")
        #expect(text.contains("do not move to their own browser or the desktop without asking them"), "\(text)")
        #expect(!text.contains("Sentinel"), "\(text)")
    }

    @Test("a load that does not finish in time is a navigation's failure; other errors are left as they are")
    func timeoutsAndOthers() throws {
        let late = try #require(Self.failure(CDPError.timedOut(method: "Page.navigate", seconds: 30),
                                             showsWindow: false, closed: true))
        #expect(late.contains("answered no load within 30 s"), "\(late)")
        for other: any Error in [CDPError.launchFailed("no Chrome"), CDPError.connectionClosed(method: "Page.navigate"),
                                 CDPError.protocolError(method: "Runtime.evaluate", code: 0, message: "x"),
                                 AutomationFailure("other")] {
            #expect(Self.failure(other, showsWindow: false, closed: true) == nil, "\(other)")
        }
    }

    @Test("the origin keeps the scheme, host and port; a local file is named as one; a word with no host is the address")
    func origins() throws {
        let error = CDPError.protocolError(method: "Page.navigate", code: 0, message: "net::ERR_CONNECTION_REFUSED")
        let local = try #require(Self.failure(error, showsWindow: false, closed: true,
                                              address: "http://127.0.0.1:8080/check?k=Sentinel-Query-K2"))
        #expect(local.contains("http://127.0.0.1:8080 answered net::ERR_CONNECTION_REFUSED (the site refused the "
                               + "connection)"), "\(local)")
        #expect(!local.contains("Sentinel") && !local.contains("/check"), "\(local)")
        let file = try #require(Self.failure(error, showsWindow: false, closed: true,
                                             address: "file:///Users/Sentinel-Home-K2/page.html"))
        #expect(file.contains("a local file answered") && !file.contains("Sentinel"), "\(file)")
        let none = try #require(Self.failure(error, showsWindow: false, closed: true, address: "Sentinel-Word-K2"))
        #expect(none.contains("the address answered") && !none.contains("Sentinel"), "\(none)")
    }
}
